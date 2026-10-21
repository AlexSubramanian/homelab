# homelab-agent

A small HTTP front end for `update.sh` on one Docker host. It exists so the
admin page on alexsubramanian.com can read what a stack is running and apply an
update without anyone opening a terminal.

It runs as a **native systemd service, not a container in the stack**. That is
not a style preference: `update.sh` runs `systemctl restart <service>`, which
recreates every container in the compose file. An agent living inside the stack
would kill itself halfway through the update it was reporting on.

## API

Everything but `/healthz` requires `Authorization: Bearer <token>`.

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/healthz` | Liveness, service name, agent version, script hashes. No auth, so the admin API can tell "host down" from "token wrong". |
| GET  | `/status` | Cached inventory, answers instantly. Includes `age_seconds` and `stale`. |
| POST | `/check` | Force a refresh. Takes ~10s on arr-stack, longer on plex. |
| GET  | `/history` | Rollback points written by `update.sh`. |
| POST | `/update` | `{"prune": false}` → `202 {"job_id": ...}` |
| POST | `/rollback` | `{"clear": false}` → `202 {"job_id": ...}` |
| GET  | `/jobs` | Recent jobs. |
| GET  | `/jobs/<id>?offset=N` | Job state plus log from `offset`; use `next_offset` to tail. |

## Design notes

**No request field ever becomes part of a command.** The body carries booleans;
the argv is assembled from constants in `agent.py`. A request body of
`{"prune": "; rm -rf / #"}` produces exactly the same argv as `{}` — there is no
string interpolation anywhere in the path from HTTP to `execve`.

**One update at a time, enforced by `flock(1)` in the child.** Holding the lock
in the child rather than the daemon means it is released exactly when the update
ends — including if the agent is restarted mid-update — and it also excludes
someone running `update.sh` from a shell at the same moment. A blocked job ends
in state `busy` with exit code 75 rather than looking like a failure.

**Status is cached.** A refresh shells out to docker once per container, so it
takes ~10s; `/status` serves the cache and says how old it is, and only
`/check` pays that cost. The background refresh runs every 6h, matching Diun.

**Stdlib only.** Debian 13 and Raspberry Pi OS both ship `EXTERNALLY-MANAGED`
Python, so anything with dependencies needs a venv kept in sync across three
hosts (one ARM) — for seven endpoints that delegate all real work to
`update.sh`. There is nothing here to keep patched.

## Security model

The agent runs as `hlagent`, which has no password, no login shell, and exactly
two privileges: membership of the `docker` group, and three `NOPASSWD` sudo
entries for `systemctl restart <plex|arr-stack|monitoring>`.

Be clear-eyed about the first one: **docker group membership is root-equivalent
on the host.** Nothing about running as a separate user changes that, and it is
unavoidable for anything that manages containers. The protections that actually
matter are therefore the ones limiting who can reach the agent at all:

- it binds to the host's LAN address, never `0.0.0.0`
- every call needs a bearer token, compared with `hmac.compare_digest`
- the action set is fixed and tiny

Port 9180 is restricted to the web VM by `homelab-agent-firewall.nft`, loaded
at boot by `homelab-agent-firewall.service`. It is an isolated nftables table
whose policy is `accept` and whose only rules match tcp/9180, so a mistake in it
cannot affect SSH or Docker's published ports.

Note what it must *not* be: putting those rules in `/etc/nftables.conf` and
enabling `nftables.service` would run that file's opening `flush ruleset` and
delete the NAT rules Docker manages, breaking every published container port on
the host.

Traffic is still plain HTTP, so the token crosses the LAN in clear. With the
port restricted to one host that is a bounded trade-off; TLS is the next
hardening step if the agent ever needs to be reachable more widely.

## Deploy

```bash
./deploy.sh homelab-agent
```

On first run this creates the `hlagent` user, adds it to `docker`, installs the
sudoers rule, installs the nftables restriction, generates a token into
`/etc/homelab-agent/env` (0600, root-owned) and prints it once for VM 104's
`.env`. It also relaxes `$HOME` from 0700 to
0711 so `hlagent` can traverse to the repo — the repo directory is already
world-readable, and 0711 still prevents anyone listing your home directory.

Re-running it keeps the existing token.

```bash
# verify
curl -s http://<host>:9180/healthz
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:9180/status
```
