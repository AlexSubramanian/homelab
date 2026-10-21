#!/usr/bin/env python3
"""homelab-agent -- a small HTTP front end for update.sh on one Docker host.

Deliberately stdlib-only. Debian 13 and Raspberry Pi OS both ship
EXTERNALLY-MANAGED Python, so anything with dependencies needs a venv kept in
sync across three hosts (one of them ARM) for seven endpoints that do no real
work of their own. There is nothing here to keep patched.

The security model is narrow on purpose:

  * no request field ever becomes part of a command -- the body carries a few
    booleans, and the argv is assembled here from constants
  * every state-changing call goes through update.sh, which is the only thing
    that knows how to touch a stack
  * one update at a time, enforced by flock(1) held by the child process, so
    the lock survives this daemon restarting and covers a human running
    update.sh by hand at the same moment
"""

import fcntl
import hashlib
import hmac
import json
import os
import socket
import subprocess
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

AGENT_VERSION = "1.0.0"

STATE_DIR = Path(os.environ.get("HOMELAB_AGENT_STATE", "/var/lib/homelab-agent"))
RUN_DIR = Path(os.environ.get("HOMELAB_AGENT_RUNTIME", "/run/homelab-agent"))
JOBS_DIR = STATE_DIR / "jobs"
STATUS_CACHE = STATE_DIR / "status.json"
LOCK_FILE = RUN_DIR / "update.lock"

REPO = Path(os.environ.get("HOMELAB_REPO", "/home/alex/homelab"))
UPDATE_SH = REPO / "update.sh"
HOMELAB_STATE = Path(os.environ.get("HOMELAB_STATE_BASE", "/var/lib/homelab"))

TOKEN = os.environ.get("HOMELAB_AGENT_TOKEN", "")
BIND = os.environ.get("HOMELAB_AGENT_BIND", "127.0.0.1")
PORT = int(os.environ.get("HOMELAB_AGENT_PORT", "9180"))
# Six hours, matching Diun's scan schedule -- there is no point refreshing more
# often than the thing that tells us something changed.
REFRESH_SECONDS = int(os.environ.get("HOMELAB_AGENT_REFRESH_SECONDS", "21600"))
# A status refresh shells out to docker once per container; plex also starts a
# throwaway container to read its package version.
CHECK_TIMEOUT = int(os.environ.get("HOMELAB_AGENT_CHECK_TIMEOUT", "180"))

# flock(1) exit code meaning "someone else holds the lock", distinct from any
# exit code update.sh itself produces.
LOCK_BUSY_EXIT = 75

HOSTNAME_SERVICE = (
    ("arr-stack", "arr-stack"),
    ("plex", "plex"),
    ("monitoring", "monitoring"),
    ("rpi4b", "monitoring"),
)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def detect_service() -> str:
    explicit = os.environ.get("HOMELAB_AGENT_SERVICE", "").strip()
    if explicit:
        return explicit
    host = socket.gethostname().split(".")[0]
    for prefix, service in HOSTNAME_SERVICE:
        if host.startswith(prefix):
            return service
    raise SystemExit(
        f"cannot determine service from hostname {host!r}; "
        "set HOMELAB_AGENT_SERVICE in /etc/homelab-agent/env"
    )


SERVICE = detect_service()


def file_digest(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()[:12]
    except OSError:
        return ""


# --- Jobs --------------------------------------------------------------------


class JobRunner:
    """Runs one update.sh invocation at a time and tails its output to disk.

    Logs live on disk rather than in memory so a job's output survives this
    process restarting, and so a long update can be followed from the admin
    page without holding it all in RAM.
    """

    def __init__(self) -> None:
        self._guard = threading.Lock()
        self._current: str | None = None

    @property
    def current(self) -> str | None:
        with self._guard:
            return self._current

    def start(self, kind: str, args: list[str]) -> tuple[str | None, str | None]:
        with self._guard:
            if self._current is not None:
                return None, self._current
            job_id = f"{datetime.now(timezone.utc):%Y%m%d-%H%M%S}-{uuid.uuid4().hex[:6]}"
            self._current = job_id

        # flock(1) rather than locking in this process: the lock is then held by
        # the child, so it is released exactly when the update ends -- including
        # when this daemon is restarted mid-update -- and it also excludes
        # someone running update.sh from a shell at the same time.
        argv = [
            "/usr/bin/flock", "--nonblock", f"--conflict-exit-code={LOCK_BUSY_EXIT}",
            str(LOCK_FILE), str(UPDATE_SH), *args, SERVICE,
        ]
        meta = {
            "job_id": job_id,
            "kind": kind,
            "service": SERVICE,
            "argv": argv,
            "state": "running",
            "exit_code": None,
            "started_at": now_iso(),
            "finished_at": None,
        }
        self._write_meta(job_id, meta)
        threading.Thread(
            target=self._run, args=(job_id, meta, argv), daemon=True
        ).start()
        return job_id, None

    def _run(self, job_id: str, meta: dict, argv: list[str]) -> None:
        log_path = JOBS_DIR / f"{job_id}.log"
        try:
            with open(log_path, "wb", buffering=0) as log:
                log.write(f"$ {' '.join(argv)}\n\n".encode())
                proc = subprocess.Popen(
                    argv,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    cwd=str(REPO),
                    env={**os.environ, "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
                )
                rc = proc.wait()
            if rc == LOCK_BUSY_EXIT:
                meta["state"] = "busy"
                with open(log_path, "ab") as log:
                    log.write(
                        b"\nAnother update is already running on this host "
                        b"(lock held by update.sh). Nothing was changed.\n"
                    )
            else:
                meta["state"] = "succeeded" if rc == 0 else "failed"
            meta["exit_code"] = rc
        except Exception as exc:  # noqa: BLE001 -- surfaced to the caller as job state
            meta["state"] = "failed"
            meta["error"] = str(exc)
        finally:
            meta["finished_at"] = now_iso()
            self._write_meta(job_id, meta)
            with self._guard:
                self._current = None
            # An update changes what is installed, so the cached status is stale
            # the moment it finishes.
            if meta.get("state") in ("succeeded", "failed"):
                threading.Thread(target=refresh_status, daemon=True).start()

    @staticmethod
    def _write_meta(job_id: str, meta: dict) -> None:
        path = JOBS_DIR / f"{job_id}.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(meta, indent=2))
        tmp.replace(path)

    @staticmethod
    def read(job_id: str, offset: int = 0) -> dict | None:
        meta_path = JOBS_DIR / f"{job_id}.json"
        if not meta_path.is_file():
            return None
        meta = json.loads(meta_path.read_text())
        log_path = JOBS_DIR / f"{job_id}.log"
        chunk, size = "", 0
        if log_path.is_file():
            size = log_path.stat().st_size
            if offset < size:
                with open(log_path, "rb") as fh:
                    fh.seek(offset)
                    chunk = fh.read().decode("utf-8", "replace")
        meta["log"] = chunk
        meta["next_offset"] = size
        return meta

    @staticmethod
    def recent(limit: int = 20) -> list[dict]:
        out = []
        for path in sorted(JOBS_DIR.glob("*.json"), reverse=True)[:limit]:
            try:
                meta = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            meta.pop("argv", None)
            out.append(meta)
        return out


RUNNER = JobRunner()


# --- Status cache ------------------------------------------------------------
#
# GET /status must answer instantly, so it serves this cache and reports how old
# it is. Only POST /check pays the registry round trip.

_status_lock = threading.Lock()


def refresh_status() -> dict:
    started = time.monotonic()
    result: dict = {"fetched_at": now_iso(), "ok": False, "error": None, "status": None}
    try:
        proc = subprocess.run(
            [str(UPDATE_SH), "--json", SERVICE],
            capture_output=True, text=True, timeout=CHECK_TIMEOUT, cwd=str(REPO),
        )
        if proc.returncode != 0:
            result["error"] = (proc.stderr or proc.stdout or "").strip()[:2000]
        else:
            result["status"] = json.loads(proc.stdout)
            result["ok"] = True
    except subprocess.TimeoutExpired:
        result["error"] = f"update.sh --json timed out after {CHECK_TIMEOUT}s"
    except (OSError, ValueError) as exc:
        result["error"] = str(exc)
    result["duration_ms"] = int((time.monotonic() - started) * 1000)

    with _status_lock:
        tmp = STATUS_CACHE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(result, indent=2))
        tmp.replace(STATUS_CACHE)
    return result


def read_status() -> dict:
    with _status_lock:
        if STATUS_CACHE.is_file():
            try:
                cached = json.loads(STATUS_CACHE.read_text())
            except ValueError:
                cached = None
            if cached:
                age = time.time() - STATUS_CACHE.stat().st_mtime
                cached["age_seconds"] = int(age)
                cached["stale"] = age > REFRESH_SECONDS * 1.5
                return cached
    return {"fetched_at": None, "ok": False, "error": "no status cached yet",
            "status": None, "age_seconds": None, "stale": True}


def refresh_loop() -> None:
    while True:
        try:
            refresh_status()
        except Exception:  # noqa: BLE001 -- a refresh failure must not kill the loop
            pass
        time.sleep(REFRESH_SECONDS)


# --- History -----------------------------------------------------------------


def read_history() -> list[dict]:
    hist_dir = HOMELAB_STATE / SERVICE / "history"
    out = []
    if hist_dir.is_dir():
        for path in sorted(hist_dir.glob("*.json"), reverse=True):
            try:
                out.append(json.loads(path.read_text()))
            except (OSError, ValueError):
                continue
    return out


# --- HTTP --------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = f"homelab-agent/{AGENT_VERSION}"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        # Journald already timestamps; keep one line per request.
        print(f"{self.address_string()} {fmt % args}", flush=True)

    # -- helpers

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _authed(self) -> bool:
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        return hmac.compare_digest(header[len(prefix):], TOKEN)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            data = json.loads(self.rfile.read(length).decode())
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    # -- routing

    def do_GET(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler API
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        # Unauthenticated: lets the admin API distinguish "host down" from
        # "token wrong" without leaking anything about the stack.
        if method == "GET" and path == "/healthz":
            self._send(200, {
                "ok": True,
                "service": SERVICE,
                "host": socket.gethostname().split(".")[0],
                "agent_version": AGENT_VERSION,
                "update_sh": file_digest(UPDATE_SH),
                "stack_lib": file_digest(REPO / "lib" / "stack.sh"),
                "job_running": RUNNER.current,
            })
            return

        if not self._authed():
            self._send(401, {"error": "unauthorized"})
            return

        if method == "GET" and path == "/status":
            self._send(200, read_status())
        elif method == "POST" and path == "/check":
            self._send(200, refresh_status())
        elif method == "GET" and path == "/history":
            self._send(200, {"service": SERVICE, "snapshots": read_history()})
        elif method == "GET" and path == "/jobs":
            self._send(200, {"jobs": RUNNER.recent()})
        elif method == "GET" and path.startswith("/jobs/"):
            offset = int((parse_qs(parsed.query).get("offset") or ["0"])[0] or 0)
            job = RUNNER.read(path[len("/jobs/"):], offset)
            self._send(200, job) if job else self._send(404, {"error": "no such job"})
        elif method == "POST" and path == "/update":
            self._start("update", self._update_args(self._body()))
        elif method == "POST" and path == "/rollback":
            self._start("rollback", self._rollback_args(self._body()))
        else:
            self._send(404, {"error": "not found"})

    # -- argv construction
    #
    # Nothing from the request reaches a command line. The body carries flags;
    # each one maps to a constant string chosen here.

    @staticmethod
    def _update_args(body: dict) -> list[str]:
        args = ["-y"]
        if body.get("prune") is True:
            args.append("--prune")
        return args

    @staticmethod
    def _rollback_args(body: dict) -> list[str]:
        args = ["--rollback", "-y"]
        if body.get("clear") is True:
            args.append("--clear")
        return args

    def _start(self, kind: str, args: list[str]) -> None:
        job_id, busy = RUNNER.start(kind, args)
        if job_id is None:
            self._send(409, {"error": "a job is already running", "job_id": busy})
            return
        self._send(202, {"job_id": job_id, "kind": kind, "service": SERVICE})


def main() -> None:
    if not TOKEN:
        raise SystemExit("HOMELAB_AGENT_TOKEN is not set; refusing to start")
    if not UPDATE_SH.is_file():
        raise SystemExit(f"{UPDATE_SH} not found or not readable by {os.getuid()}")
    for directory in (STATE_DIR, JOBS_DIR, RUN_DIR):
        directory.mkdir(parents=True, exist_ok=True)

    threading.Thread(target=refresh_loop, daemon=True).start()

    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    print(f"homelab-agent {AGENT_VERSION} serving {SERVICE} on {BIND}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
