#!/usr/bin/env bash
set -euo pipefail

# Pull newer images for this host's compose stack, show what changed, and
# restart the stack through systemd if anything did. Every update snapshots the
# digests it replaces first, so it can be undone with --rollback.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack.sh
source "$SCRIPT_DIR/lib/stack.sh"

usage() {
    cat <<EOF
Usage: $0 [options] [service]

Checking and updating
  --check            Report what would change, but don't restart
  --json             Machine-readable status (implies --check, no restart)
  --offline          Skip registry lookups; report local state only
  -y, --yes          Don't ask before restarting
  --force            Restart even if no images changed
  --prune            Remove dangling images after a successful update

Rolling back
  --rollback         Pin the services the last update changed back to their
                     previous digests and restart
  --rollback --clear Remove the pin and restart onto the tracked tags
  --history          List the snapshots available to roll back to

  service            arr-stack, plex, or monitoring (auto-detected from hostname)
EOF
}

CHECK=0; JSON=0; OFFLINE=0; YES=0; FORCE=0; PRUNE=0
ROLLBACK=0; CLEAR=0; HISTORY=0; SERVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    CHECK=1 ;;
        --json)     JSON=1; CHECK=1 ;;
        --offline)  OFFLINE=1 ;;
        -y|--yes)   YES=1 ;;
        --force)    FORCE=1 ;;
        --prune)    PRUNE=1 ;;
        --rollback) ROLLBACK=1 ;;
        --clear)    CLEAR=1 ;;
        --history)  HISTORY=1 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)          SERVICE="$1" ;;
    esac
    shift
done

if [[ -z "$SERVICE" ]]; then
    if ! SERVICE="$(stack_detect_service)"; then
        echo "Error: cannot auto-detect service from hostname '$(hostname -s)'." >&2
        usage >&2
        exit 1
    fi
fi

if ! stack_is_known_service "$SERVICE"; then
    echo "Error: unknown service '$SERVICE' (expected one of: ${HOMELAB_SERVICES[*]})" >&2
    exit 1
fi

BASE_COMPOSE="$(stack_base_compose "$SERVICE")"
if [[ ! -f "$BASE_COMPOSE" ]]; then
    echo "Error: $BASE_COMPOSE not found (has $SERVICE been deployed?)" >&2
    exit 1
fi

STATE_DIR="$(stack_state_dir "$SERVICE")"
HISTORY_DIR="$(stack_history_dir "$SERVICE")"
ENV_FILE="$(stack_env_file "$SERVICE")"
ROLLBACK_COMPOSE="$(stack_rollback_compose "$SERVICE")"

stack_use "$SERVICE"

# All state writes go through here so a missing state dir is one clear error
# rather than a dozen scattered ones. deploy.sh creates it group-writable.
require_state_dir() {
    if [[ ! -d "$HISTORY_DIR" ]]; then
        if ! mkdir -p "$HISTORY_DIR" 2>/dev/null; then
            echo "Error: cannot write $HISTORY_DIR" >&2
            echo "       Run ./deploy.sh $SERVICE to create it." >&2
            exit 1
        fi
    fi
    if [[ ! -w "$STATE_DIR" ]]; then
        echo "Error: $STATE_DIR is not writable by $(id -un)." >&2
        echo "       Run ./deploy.sh $SERVICE to fix its ownership." >&2
        exit 1
    fi
}

# --- Gather status -----------------------------------------------------------
#
# Per compose service, in index-aligned arrays:
#   base_ref   the tag the base compose file tracks (never a digest pin)
#   running    the manifest digest the running container was pulled at
#   remote     the manifest digest that tag resolves to now
#   local_id   the local image id that base_ref resolves to
# See update_available_at() for how those combine. A service pinned by
# --rollback still compares against base_ref, so a pin can't silently park a
# service on "up to date" forever.

SERVICES=(); CTN_NAMES=(); BASE_REFS=(); RUNNING_D=(); REMOTE_D=()
STATES=(); HEALTHS=(); VERSIONS=(); CREATEDS=(); DISPLAYS=(); IMAGE_IDS=(); PINNED=()
LOCAL_IDS=()

gather() {
    local svc ctn imgid
    for svc in $(stack_dc config --services); do
        local base_ref running_digest remote_digest state health version created display image_id pinned ctn_name local_id
        base_ref="$(stack_base_image_ref "$svc")"
        ctn="$(stack_dc ps -q "$svc" 2>/dev/null || true)"

        pinned=false
        if stack_is_pinned "$SERVICE" && stack_pinned_services "$SERVICE" | grep -qx "$svc"; then
            pinned=true
        fi

        if [[ -n "$ctn" ]]; then
            imgid="$(docker inspect -f '{{.Image}}' "$ctn")"
            ctn_name="$(docker inspect -f '{{.Name}}' "$ctn")"; ctn_name="${ctn_name#/}"
            state="$(docker inspect -f '{{.State.Status}}' "$ctn")"
            health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$ctn")"
            running_digest="$(stack_repo_digest "$imgid")"
            version="$(stack_version_of "$svc" "$imgid")"
            created="$(stack_image_created "$imgid")"
            display="$(stack_display_version "$version" "$created" "$imgid")"
            image_id="$imgid"
        else
            ctn_name=""; state="absent"; health=""; running_digest=""
            version=""; created=""; display=""; image_id=""
        fi

        remote_digest=""
        if [[ $OFFLINE -eq 0 && -n "$base_ref" ]]; then
            remote_digest="$(stack_remote_digest "$base_ref")"
        fi

        # What the tracked tag resolves to locally right now. Works offline and
        # stays correct after a pull, when the outgoing image has lost its
        # RepoDigests and the registry comparison can no longer see anything.
        local_id=""
        [[ -n "$base_ref" ]] && local_id="$(stack_local_image_id "$base_ref")"

        SERVICES+=("$svc");        CTN_NAMES+=("$ctn_name")
        BASE_REFS+=("$base_ref");  RUNNING_D+=("$running_digest")
        REMOTE_D+=("$remote_digest"); STATES+=("$state")
        HEALTHS+=("$health");      VERSIONS+=("$version")
        CREATEDS+=("$created");    DISPLAYS+=("$display")
        IMAGE_IDS+=("$image_id");  PINNED+=("$pinned")
        LOCAL_IDS+=("$local_id")
    done
}

# The image is on disk but the container is still on the old one -- i.e. a pull
# happened and the restart didn't (or hasn't yet).
local_pending_at() {
    local i="$1"
    [[ -n "${LOCAL_IDS[$i]}" && -n "${IMAGE_IDS[$i]}" && "${LOCAL_IDS[$i]}" != "${IMAGE_IDS[$i]}" ]]
}

# Two independent signals, because neither covers both regimes: the registry
# comparison sees updates before anything is pulled, and the local comparison
# still sees them afterwards. Checking only the registry made a half-finished
# update (pulled, not restarted) look up to date.
update_available_at() {
    local i="$1"
    local_pending_at "$i" && return 0
    [[ -n "${RUNNING_D[$i]}" && -n "${REMOTE_D[$i]}" && "${RUNNING_D[$i]}" != "${REMOTE_D[$i]}" ]]
}

# --- JSON output -------------------------------------------------------------

emit_json() {
    local i first=1 pin_state=false
    stack_is_pinned "$SERVICE" && pin_state=true

    printf '{\n'
    printf '  %s,\n' "$(stack_json_kv service "$SERVICE")"
    printf '  %s,\n' "$(stack_json_kv host "$(hostname -s)")"
    printf '  %s,\n' "$(stack_json_kv checked_at "$(stack_now_iso)")"
    printf '  %s,\n' "$(stack_json_kb offline "$([[ $OFFLINE -eq 1 ]] && echo true || echo false)")"
    printf '  %s,\n' "$(stack_json_kb pinned "$pin_state")"
    printf '  %s,\n' "$(stack_json_kv compose_file "$(stack_compose_file_value "$SERVICE")")"
    printf '  "containers": [\n'
    for i in "${!SERVICES[@]}"; do
        [[ $first -eq 1 ]] || printf ',\n'
        first=0
        printf '    {'
        printf '%s, ' "$(stack_json_kv compose_service "${SERVICES[$i]}")"
        printf '%s, ' "$(stack_json_kv container "${CTN_NAMES[$i]}")"
        printf '%s, ' "$(stack_json_kv image "${BASE_REFS[$i]}")"
        printf '%s, ' "$(stack_json_kv version "${VERSIONS[$i]}")"
        printf '%s, ' "$(stack_json_kv created "${CREATEDS[$i]}")"
        printf '%s, ' "$(stack_json_kv display_version "${DISPLAYS[$i]}")"
        printf '%s, ' "$(stack_json_kv running_digest "${RUNNING_D[$i]}")"
        printf '%s, ' "$(stack_json_kv remote_digest "${REMOTE_D[$i]}")"
        printf '%s, ' "$(stack_json_kv state "${STATES[$i]}")"
        printf '%s, ' "$(stack_json_kv health "${HEALTHS[$i]}")"
        printf '%s, ' "$(stack_json_kb pinned "${PINNED[$i]}")"
        printf '%s, ' "$(stack_json_kb local_pending \
            "$(local_pending_at "$i" && echo true || echo false)")"
        printf '%s' "$(stack_json_kb update_available \
            "$(update_available_at "$i" && echo true || echo false)")"
        printf '}'
    done
    printf '\n  ]\n}\n'
}

# --- History -----------------------------------------------------------------

list_history() {
    if [[ ! -d "$HISTORY_DIR" ]] || ! compgen -G "$HISTORY_DIR/*.json" >/dev/null; then
        echo "No snapshots recorded for $SERVICE yet."
        return 0
    fi
    echo "==> Snapshots for $SERVICE (newest first)"
    local f stamp when
    while IFS= read -r f; do
        stamp="$(basename "$f" .json)"
        when="$(sed -n 's/.*"started_at": "\([^"]*\)".*/\1/p' "$f" | head -1)"
        printf '    %-18s %s\n' "$stamp" "${when:-unknown}"
        sed -n 's/.*"compose_service": "\([^"]*\)".*"display_version": "\([^"]*\)".*/      \1 @ \2/p' "$f"
    done < <(find "$HISTORY_DIR" -maxdepth 1 -name '*.json' | sort -r)
}

latest_snapshot() {
    find "$HISTORY_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort -r | head -1
}

# Read one field for one compose service out of a snapshot file. The snapshot is
# written one container per line precisely so this stays a grep away.
snapshot_field() {
    local file="$1" svc="$2" field="$3"
    grep "\"compose_service\": \"$svc\"" "$file" 2>/dev/null \
        | sed -n "s/.*\"$field\": \"\([^\"]*\)\".*/\1/p" | head -1
}

snapshot_services() {
    sed -n 's/.*"compose_service": "\([^"]*\)".*/\1/p' "$1"
}

# --- Snapshot ----------------------------------------------------------------
#
# Written immediately before the restart, while the outgoing images are still
# what's running. Each image is also retagged: the moment :latest moves, the
# image we'd want back becomes dangling, and `docker image prune -f` would
# delete the thing --rollback depends on.

write_snapshot() {
    local stamp="$1" reason="$2"
    # Separate statement on purpose: bash expands a `local` command's whole
    # argument list before the builtin runs, so referencing $stamp in the same
    # declaration reads the unset global and trips set -u.
    local file="$HISTORY_DIR/$stamp.json"
    local i tag first=1

    {
        printf '{\n'
        printf '  %s,\n' "$(stack_json_kv service "$SERVICE")"
        printf '  %s,\n' "$(stack_json_kv timestamp "$stamp")"
        printf '  %s,\n' "$(stack_json_kv started_at "$(stack_now_iso)")"
        printf '  %s,\n' "$(stack_json_kv reason "$reason")"
        printf '  "containers": [\n'
        for i in "${!SERVICES[@]}"; do
            # image_id is the only thing a rollback actually needs -- it's what
            # gets retagged and pinned. The repo digest is nice-to-have context
            # and is legitimately absent for an image whose tag has moved on, so
            # requiring it here silently dropped exactly the services that had
            # just been updated: the ones a rollback is for.
            [[ -n "${IMAGE_IDS[$i]}" ]] || continue
            [[ $first -eq 1 ]] || printf ',\n'
            first=0
            tag="homelab-prev/${SERVICES[$i]}:$stamp"
            printf '    {'
            printf '%s, ' "$(stack_json_kv compose_service "${SERVICES[$i]}")"
            printf '%s, ' "$(stack_json_kv image "${BASE_REFS[$i]}")"
            printf '%s, ' "$(stack_json_kv version "${VERSIONS[$i]}")"
            printf '%s, ' "$(stack_json_kv display_version "${DISPLAYS[$i]}")"
            printf '%s, ' "$(stack_json_kv digest "${RUNNING_D[$i]}")"
            printf '%s, ' "$(stack_json_kv image_id "${IMAGE_IDS[$i]}")"
            printf '%s' "$(stack_json_kv rollback_tag "$tag")"
            printf '}'
        done
        printf '\n  ]\n}\n'
    } >"$file"

    for i in "${!SERVICES[@]}"; do
        [[ -n "${IMAGE_IDS[$i]}" ]] || continue
        tag="homelab-prev/${SERVICES[$i]}:$stamp"
        docker tag "${IMAGE_IDS[$i]}" "$tag" 2>/dev/null || true
    done

    echo "    snapshot: $file"
}

# Keep the newest N snapshots. Dropping a snapshot means dropping the tags that
# held its images out of the prune path -- except any tag the live pin is using.
prune_history() {
    local keep="$HOMELAB_HISTORY_KEEP" f stamp tag svc
    local -a pinned_tags=()

    if stack_is_pinned "$SERVICE"; then
        while IFS= read -r tag; do pinned_tags+=("$tag"); done \
            < <(sed -n 's/.*image:[[:space:]]*\(homelab-prev\/[^[:space:]]*\).*/\1/p' \
                    "$ROLLBACK_COMPOSE" 2>/dev/null || true)
    fi

    while IFS= read -r f; do
        stamp="$(basename "$f" .json)"
        while IFS= read -r svc; do
            tag="homelab-prev/$svc:$stamp"
            local skip=0 p
            for p in "${pinned_tags[@]+"${pinned_tags[@]}"}"; do
                [[ "$p" == "$tag" ]] && skip=1
            done
            [[ $skip -eq 1 ]] && continue
            docker rmi "$tag" >/dev/null 2>&1 || true
        done < <(snapshot_services "$f")
        rm -f "$f"
        echo "    pruned old snapshot: $stamp"
    done < <(find "$HISTORY_DIR" -maxdepth 1 -name '*.json' | sort -r | tail -n "+$((keep + 1))")
}

# --- Pin management ----------------------------------------------------------

write_env_file() {
    local value="$1"
    printf '# Written by update.sh -- systemd reads this via EnvironmentFile.\n' >"$ENV_FILE"
    printf '# COMPOSE_PROJECT_NAME is pinned so adding the rollback overlay can\n' >>"$ENV_FILE"
    printf '# never change the project name and orphan the running containers.\n' >>"$ENV_FILE"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$SERVICE" >>"$ENV_FILE"
    printf 'COMPOSE_FILE=%s\n' "$value" >>"$ENV_FILE"
}

clear_pin() {
    rm -f "$ROLLBACK_COMPOSE"
    write_env_file "$BASE_COMPOSE"
}

# --- Restart -----------------------------------------------------------------

restart_stack() {
    echo "==> Restarting systemd service: $SERVICE"
    sudo systemctl restart "$SERVICE"

    echo "==> Waiting for containers to come up"
    local ready=0 states _
    for _ in $(seq 40); do
        # Only services in the compose file, so leftover orphan containers don't count
        # shellcheck disable=SC2046 # word splitting of container IDs is intended
        states="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
            $(stack_dc ps -aq $(stack_dc config --services)) 2>/dev/null || true)"
        if [[ -n "$states" ]] && ! grep -qvE '^running ?(healthy)?$' <<<"$states"; then
            ready=1
            break
        fi
        sleep 3
    done

    echo
    stack_dc ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
    echo
    [[ $ready -eq 1 ]] || echo "WARNING: not every container is running/healthy after 2 minutes — check 'docker compose logs'."

    # Diun scans on startup, which races the rest of the stack coming up; rescan
    # now that everything is running so it watches every container.
    if stack_dc config --services | grep -qx diun; then
        echo "==> Restarting diun so it rescans the stack"
        stack_dc restart diun >/dev/null
    fi
}

confirm() {
    local prompt="$1"
    [[ $YES -eq 1 ]] && return 0
    if [[ ! -t 0 ]]; then
        echo "Not running in a terminal; re-run with -y." >&2
        exit 1
    fi
    local ans
    read -rp "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

warn_plex_streams() {
    [[ "$SERVICE" == "plex" ]] || return 0
    local token streams
    token="$(docker exec plex sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' \
        "/config/Library/Application Support/Plex Media Server/Preferences.xml" 2>/dev/null || true)"
    streams="$(curl -s "http://localhost:32400/status/sessions?X-Plex-Token=$token" \
        | sed -n 's/.*<MediaContainer size="\([0-9]*\)".*/\1/p' | head -1 || true)"
    if [[ -z "$streams" ]]; then
        echo "    Note: could not check for active Plex streams"
    elif [[ "$streams" -gt 0 ]]; then
        echo "    WARNING: $streams active Plex stream(s) will be interrupted"
    fi
}

report_plex_version() {
    [[ "$SERVICE" == "plex" ]] || return 0
    local v
    v="$(curl -s --retry 10 --retry-connrefused --retry-delay 3 http://localhost:32400/identity \
        | grep -o 'MediaContainer[^>]*' | sed -n 's/.* version="\([^"]*\)".*/\1/p' || true)"
    echo "==> Plex Media Server version: ${v:-unknown}"
}

# =============================================================================
# --history
# =============================================================================

if [[ $HISTORY -eq 1 ]]; then
    list_history
    exit 0
fi

# =============================================================================
# --rollback --clear
# =============================================================================

if [[ $ROLLBACK -eq 1 && $CLEAR -eq 1 ]]; then
    if ! stack_is_pinned "$SERVICE"; then
        echo "==> $SERVICE is not pinned; nothing to clear."
        exit 0
    fi
    require_state_dir
    echo "==> Clearing rollback pin on $SERVICE"
    stack_pinned_services "$SERVICE" | sed 's/^/    unpinning /'
    confirm "Unpin and restart $SERVICE onto its tracked tags?"
    clear_pin
    stack_use "$SERVICE"
    restart_stack
    report_plex_version
    echo "==> Done. Run '$0 --check' to see what updates are now available."
    exit 0
fi

# =============================================================================
# --rollback
# =============================================================================

if [[ $ROLLBACK -eq 1 ]]; then
    require_state_dir
    SNAPSHOT="$(latest_snapshot)"
    if [[ -z "$SNAPSHOT" ]]; then
        echo "Error: no snapshots recorded for $SERVICE — nothing to roll back to." >&2
        echo "       Snapshots are written by this script on each update." >&2
        exit 1
    fi

    echo "==> Rolling back $SERVICE using $(basename "$SNAPSHOT" .json)"
    OFFLINE=1   # a rollback is a local operation; don't wait on the registry
    gather

    # Pin only what actually moved since the snapshot. Rolling back the whole
    # stack would pin services the update never touched, and Compose merges
    # per-service, so everything else keeps the base file's definition.
    PIN_SVCS=(); PIN_TAGS=(); PIN_FROM=(); PIN_TO=()
    for i in "${!SERVICES[@]}"; do
        svc="${SERVICES[$i]}"
        snap_image_id="$(snapshot_field "$SNAPSHOT" "$svc" image_id)"
        snap_tag="$(snapshot_field "$SNAPSHOT" "$svc" rollback_tag)"
        snap_version="$(snapshot_field "$SNAPSHOT" "$svc" display_version)"
        [[ -n "$snap_image_id" && -n "$snap_tag" ]] || continue
        # Image ids, not repo digests: an id is always present, whereas a digest
        # vanishes once the tag it was pulled under moves to a newer image.
        [[ "${IMAGE_IDS[$i]}" == "$snap_image_id" ]] && continue

        if ! docker image inspect "$snap_tag" >/dev/null 2>&1; then
            echo "    WARNING: $svc — rollback image $snap_tag is gone, skipping"
            continue
        fi
        PIN_SVCS+=("$svc"); PIN_TAGS+=("$snap_tag")
        PIN_FROM+=("${DISPLAYS[$i]}"); PIN_TO+=("$snap_version")
    done

    if [[ ${#PIN_SVCS[@]} -eq 0 ]]; then
        echo "==> Nothing to roll back: every service already matches the snapshot."
        exit 0
    fi

    for i in "${!PIN_SVCS[@]}"; do
        printf '    %-14s %s -> %s\n' "${PIN_SVCS[$i]}" "${PIN_FROM[$i]}" "${PIN_TO[$i]}"
    done
    echo
    echo "    These services will be pinned by digest until '$0 --rollback --clear'."
    warn_plex_streams
    confirm "Roll back $SERVICE now? All containers in the stack will be recreated."

    {
        printf '# Generated by update.sh on %s\n' "$(stack_now_iso)"
        printf '# Rollback of %s to snapshot %s\n' "$SERVICE" "$(basename "$SNAPSHOT" .json)"
        printf '#\n'
        printf '# These services are pinned and will NOT receive updates while this\n'
        printf '# file is part of COMPOSE_FILE in %s\n' "$ENV_FILE"
        printf '# Remove it with: %s --rollback --clear\n' "$0"
        printf 'services:\n'
        for i in "${!PIN_SVCS[@]}"; do
            printf '  %s:\n' "${PIN_SVCS[$i]}"
            printf '    image: %s\n' "${PIN_TAGS[$i]}"
        done
    } >"$ROLLBACK_COMPOSE"

    write_env_file "$BASE_COMPOSE:$ROLLBACK_COMPOSE"
    stack_use "$SERVICE"
    restart_stack
    report_plex_version
    echo "==> Rolled back. $SERVICE is pinned — '$0 --check' will show it as pinned."
    exit 0
fi

# =============================================================================
# check / update
# =============================================================================

if [[ $JSON -eq 0 ]]; then
    if [[ $OFFLINE -eq 1 ]]; then
        echo "==> Reading local state for: $SERVICE (offline)"
    else
        echo "==> Checking registries for: $SERVICE"
    fi
    if [[ $OFFLINE -eq 0 ]] && ! stack_have_buildx; then
        echo "Error: docker buildx is required for registry checks." >&2
        echo "       Install it (apt install docker-buildx-plugin) or pass --offline." >&2
        exit 1
    fi
fi

gather

if [[ $JSON -eq 1 ]]; then
    emit_json
    exit 0
fi

if stack_is_pinned "$SERVICE"; then
    echo "    NOTE: $SERVICE has a rollback pin active on:" \
         "$(stack_pinned_services "$SERVICE" | tr '\n' ' ')"
    echo "          Pinned services stay on their pinned digest until '--rollback --clear'."
fi

CHANGED=(); PINNED_SVCS=(); PINNED_STALE=()
for i in "${!SERVICES[@]}"; do
    svc="${SERVICES[$i]}"
    if [[ "${STATES[$i]}" == "absent" ]]; then
        printf '    %-14s not running\n' "$svc"
        continue
    fi
    if [[ "${PINNED[$i]}" == true ]]; then
        PINNED_SVCS+=("$svc")
        if update_available_at "$i"; then
            printf '    %-14s PINNED at %s (newer image available)\n' "$svc" "${DISPLAYS[$i]}"
            PINNED_STALE+=("$svc")
        else
            printf '    %-14s PINNED at %s\n' "$svc" "${DISPLAYS[$i]}"
        fi
        continue
    fi
    if update_available_at "$i"; then
        if local_pending_at "$i"; then
            printf '    %-14s %-18s -> pulled, awaiting restart\n' "$svc" "${DISPLAYS[$i]}"
        else
            printf '    %-14s %-18s -> update available\n' "$svc" "${DISPLAYS[$i]}"
        fi
        CHANGED+=("$svc")
    fi
done

if [[ ${#CHANGED[@]} -eq 0 && $FORCE -eq 0 ]]; then
    # "Everything is up to date" is a lie in two cases, and both are easy to hit:
    # --offline never consulted a registry, and a pinned service is being held
    # back on purpose. Saying it anyway is how a forgotten rollback turns into a
    # service that quietly stops getting updates.
    if [[ $OFFLINE -eq 1 ]]; then
        echo "==> Local state only (--offline); no registry comparison was made."
    elif [[ ${#PINNED_STALE[@]} -gt 0 ]]; then
        echo "==> No updates for unpinned services, but" \
             "${#PINNED_STALE[@]} pinned service(s) have newer images:" \
             "${PINNED_STALE[*]}"
        echo "    Release them with: $0 --rollback --clear"
    elif [[ ${#PINNED_SVCS[@]} -gt 0 ]]; then
        echo "==> No updates for unpinned services." \
             "${#PINNED_SVCS[@]} service(s) pinned: ${PINNED_SVCS[*]}"
    else
        echo "==> Everything is up to date."
    fi
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    echo "==> --check given, not restarting."
    exit 0
fi

require_state_dir

# Pull now that we know something moved. The digest check told us what changed;
# this is what actually brings the bits down.
#
# --ignore-pull-failures matters more than it looks while a pin is active: the
# overlay points pinned services at local homelab-prev/* tags that exist in no
# registry, so their pull is expected to fail and must not abort the update of
# everything else.
echo "==> Pulling images for: $SERVICE"
stack_dc pull --quiet --ignore-pull-failures || true

warn_plex_streams
confirm "Restart $SERVICE now? All containers in the stack will be recreated."

STAMP="$(stack_now_stamp)"
echo "==> Recording rollback point"
write_snapshot "$STAMP" update

restart_stack
report_plex_version

prune_history

if [[ $PRUNE -eq 1 ]]; then
    # Safe now: write_snapshot retagged the outgoing images as homelab-prev/*,
    # so they aren't dangling and prune won't take the rollback target with it.
    echo "==> Removing dangling images"
    docker image prune -f
fi

echo "==> Done. Undo with: $0 --rollback"
