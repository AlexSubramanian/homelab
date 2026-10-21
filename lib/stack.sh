#!/usr/bin/env bash
# Shared helpers for update.sh and (later) the homelab agent.
#
# Source this, don't run it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/stack.sh"
#
# The one rule that matters here: everything that talks to a stack resolves its
# compose file list through stack_use(), which reads the same stack.env systemd
# reads. If a caller hardcoded `-f docker-compose.yml` it would inspect the
# unpinned base file while systemd ran a digest-pinned stack, and report
# confidently on a stack that isn't the one running.

# Runtime state lives outside the repo: /opt/docker/<service> is a symlink back
# into this git checkout, so generated files written there would show up as
# untracked changes in the working tree.
HOMELAB_STATE_BASE="${HOMELAB_STATE_BASE:-/var/lib/homelab}"
HOMELAB_DOCKER_BASE="${HOMELAB_DOCKER_BASE:-/opt/docker}"

# Snapshots kept per service. Each one pins a full set of images out of the
# prune path, so this is a disk-space knob, not just a bookkeeping one.
HOMELAB_HISTORY_KEEP="${HOMELAB_HISTORY_KEEP:-2}"

HOMELAB_SERVICES=(arr-stack plex monitoring)

# --- Paths -------------------------------------------------------------------

stack_state_dir()        { printf '%s\n' "$HOMELAB_STATE_BASE/$1"; }
stack_history_dir()      { printf '%s\n' "$HOMELAB_STATE_BASE/$1/history"; }
stack_env_file()         { printf '%s\n' "$HOMELAB_STATE_BASE/$1/stack.env"; }
stack_rollback_compose() { printf '%s\n' "$HOMELAB_STATE_BASE/$1/docker-compose.rollback.yml"; }
stack_base_compose()     { printf '%s\n' "$HOMELAB_DOCKER_BASE/$1/docker-compose.yml"; }

# --- Service detection -------------------------------------------------------

stack_detect_service() {
    local host
    host="$(hostname -s)"
    case "$host" in
        arr-stack*)         echo arr-stack ;;
        plex*)              echo plex ;;
        monitoring*|rpi4b*) echo monitoring ;;
        *) return 1 ;;
    esac
}

stack_is_known_service() {
    local s
    for s in "${HOMELAB_SERVICES[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# --- Compose file resolution -------------------------------------------------

# The COMPOSE_FILE value systemd will use for this service: the base file, plus
# the rollback overlay when a pin is active. Colon-separated, matching Compose's
# own COMPOSE_FILE syntax.
stack_compose_file_value() {
    local svc="$1" env_file value
    env_file="$(stack_env_file "$svc")"
    if [[ -r "$env_file" ]]; then
        # Last assignment wins, same as systemd's EnvironmentFile parsing.
        value="$(sed -n 's/^[[:space:]]*COMPOSE_FILE=//p' "$env_file" | tail -1)"
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    # No stack.env yet (or it predates this change): the base file alone, which
    # is also what systemd falls back to via WorkingDirectory discovery.
    stack_base_compose "$svc"
}

# Sets STACK_SERVICE, STACK_BASE_COMPOSE and STACK_DC_ARGS for the given service.
# Call once up front; use stack_dc() afterwards.
stack_use() {
    STACK_SERVICE="$1"
    STACK_BASE_COMPOSE="$(stack_base_compose "$STACK_SERVICE")"

    local value
    value="$(stack_compose_file_value "$STACK_SERVICE")"

    local -a files=()
    local IFS=':'
    read -ra files <<<"$value"
    unset IFS

    STACK_DC_ARGS=()
    local f
    for f in "${files[@]}"; do
        [[ -n "$f" ]] || continue
        if [[ ! -f "$f" ]]; then
            echo "Error: compose file in COMPOSE_FILE does not exist: $f" >&2
            echo "       Fix or remove $(stack_env_file "$STACK_SERVICE")" >&2
            return 1
        fi
        STACK_DC_ARGS+=(-f "$f")
    done

    if [[ ${#STACK_DC_ARGS[@]} -eq 0 ]]; then
        echo "Error: no compose file resolved for $STACK_SERVICE" >&2
        return 1
    fi
}

# docker compose against the resolved file list.
stack_dc() { docker compose "${STACK_DC_ARGS[@]}" "$@"; }

# docker compose against the base file only. Used wherever we need to know what
# a service is *supposed* to track rather than what it's currently pinned to.
stack_dc_base() { docker compose -f "$STACK_BASE_COMPOSE" "$@"; }

# --- Pin state ---------------------------------------------------------------

stack_is_pinned() {
    local svc="$1" rb
    rb="$(stack_rollback_compose "$svc")"
    [[ -f "$rb" ]] && [[ "$(stack_compose_file_value "$svc")" == *"$rb"* ]]
}

# Compose service names carrying an image pin in the rollback overlay.
stack_pinned_services() {
    local rb
    rb="$(stack_rollback_compose "$1")"
    [[ -f "$rb" ]] || return 0
    awk '
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
        /^    image:/ && svc != ""         { print svc; svc = "" }
    ' "$rb"
}

# --- Image identity ----------------------------------------------------------
#
# Two different sha256 values get confused constantly here, so:
#   - an image ID is the digest of the local image *config* blob
#   - a repo digest is the digest of the *manifest* in the registry
# Only repo digests are comparable with anything the registry tells us.

# The tag a compose service is declared with in the base file. Always a tag,
# even while the running stack is pinned to a digest.
stack_base_image_ref() {
    local svc="$1" ref
    ref="$(stack_dc_base config --images "$svc" 2>/dev/null | head -1 || true)"
    if [[ -n "$ref" ]]; then
        printf '%s\n' "$ref"
        return 0
    fi
    # Older Compose versions don't take a service argument for --images. The
    # normalized output of `config` is stable enough to read directly.
    stack_dc_base config 2>/dev/null | awk -v want="$svc" '
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur = $1; sub(/:$/, "", cur); next }
        /^    image:/ && cur == want       { print $2; exit }
    '
}

# Registry manifest digest an image was pulled at.
#
# Empty is a normal answer, not a failure: locally built images never have one,
# and an image loses its RepoDigests once the tag it was pulled under moves on
# to a newer image. Always returns 0 -- an earlier version ended in
# `[[ ... ]] && printf`, which returned 1 for those images and killed callers
# running under set -e.
stack_repo_digest() {
    local image="$1" rd
    rd="$(docker image inspect "$image" \
            -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null || true)"
    if [[ "$rd" == *@* ]]; then
        printf '%s\n' "${rd##*@}"
    fi
    return 0
}

# Local image ID a reference currently resolves to. Comparing this against the
# running container's image ID catches the case the registry comparison can't:
# the image is already pulled and sitting on disk, but the container hasn't been
# recreated onto it yet.
stack_local_image_id() {
    docker image inspect "$1" -f '{{.Id}}' 2>/dev/null || true
}

# Current manifest digest for a tag in the registry. No layers are downloaded,
# which is the whole reason a web button can afford to call this.
#
# Note: --format '{{.Manifest.Digest}}' looks like it should work and doesn't —
# .Manifest is raw JSON to the template engine, so that expression silently
# yields the default human output instead of a digest. Parse the Digest: line,
# and fall back to hashing the raw manifest, which is what the digest *is*.
stack_remote_digest() {
    local ref="$1" d
    d="$(docker buildx imagetools inspect "$ref" 2>/dev/null \
            | sed -n 's/^Digest:[[:space:]]*//p' | head -1)"
    if [[ -z "$d" ]]; then
        d="$(docker buildx imagetools inspect "$ref" --raw 2>/dev/null | sha256sum 2>/dev/null \
                | awk '{print "sha256:" $1}')"
        [[ "$d" == "sha256:" ]] && d=""
    fi
    printf '%s\n' "$d"
}

stack_have_buildx() { docker buildx version >/dev/null 2>&1; }

# Real version string, or empty when the image doesn't carry one. The PMS
# package version for Plex, the OCI version label for everything else.
#
# Empty is common and not an error: prom/*, grafana/* and plenty of others ship
# no version label at all, which is why stack_display_version() exists.
stack_version_of() {
    local svc="$1" image="$2" v=""
    if [[ "$svc" == "plex" ]]; then
        # This starts a throwaway container, so callers should cache the result
        # rather than asking on every poll.
        v="$(docker run --rm --entrypoint dpkg-query "$image" \
                -W -f='${Version}' plexmediaserver 2>/dev/null || true)"
    else
        v="$(docker image inspect \
                -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
                "$image" 2>/dev/null || true)"
    fi
    [[ "$v" == "<no value>" ]] && v=""
    printf '%s\n' "$v"
}

# Image build date (YYYY-MM-DD). Available for every image regardless of
# labelling, which makes it the one fallback that still tells a human something
# useful -- "built 2026-10-14" answers "how stale am I?" and a hex digest doesn't.
stack_image_created() {
    local created
    created="$(docker image inspect -f '{{.Created}}' "$1" 2>/dev/null || true)"
    printf '%s\n' "${created:0:10}"
}

# What to show a human: the version if there is one, else the build date, else a
# short digest as the last resort.
stack_display_version() {
    local version="$1" created="$2" image="$3"
    if [[ -n "$version" ]]; then
        printf '%s\n' "$version"
    elif [[ -n "$created" ]]; then
        printf 'built %s\n' "$created"
    else
        local short="${image#sha256:}"
        printf '%s\n' "${short:0:12}"
    fi
}

# --- JSON --------------------------------------------------------------------

stack_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# key value -> "key": "value"   (empty value becomes null, not "")
stack_json_kv() {
    if [[ -z "$2" ]]; then
        printf '"%s": null' "$(stack_json_escape "$1")"
    else
        printf '"%s": "%s"' "$(stack_json_escape "$1")" "$(stack_json_escape "$2")"
    fi
}

stack_json_kb() { printf '"%s": %s' "$(stack_json_escape "$1")" "$2"; }

stack_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
stack_now_stamp() { date -u +%Y%m%d-%H%M%S; }
