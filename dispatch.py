#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Start one ephemeral GitHub Actions runner per queued job, and none while idle.

Usage: ./dispatch.py [--config config.toml]
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import platform
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import IO

SCRIPT_DIR = Path(__file__).resolve().parent
API_URL = "https://api.github.com"
# Repository-level runners always belong to the "Default" group
RUNNER_GROUP_ID = 1
LAUNCH_FAILURE_WINDOW = 30
LAUNCH_FAILURE_BACKOFF = 60
VERSION_CHECK_INTERVAL = 3600
RATE_LIMIT_WARN_THRESHOLD = 500
STOP_TIMEOUT = 120
SIGNAL_DEBOUNCE = 1.0
# GitHub's answer to deleting a runner that is running a job
RUNNER_BUSY_STATUS = 422
DOCKER_IMAGE = "gh-runner-jit"
DOCKER_POOL_LABEL = "github-runner-spawner.pool"
WINDOWS_WRAPPER = "spawner-run-jit.ps1"

REPO_RE = re.compile(r"^[a-z0-9_.-]+/[a-z0-9_.-]+$")
POOL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# runner_dir is embedded in the remote PowerShell command line
UNSAFE_REMOTE_CHARS = set("\"'`$;&|<>\n\r")

_log_lock = threading.Lock()


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
    with _log_lock:
        print(f"[{ts}] {msg}", flush=True)


# ---------------------------------------------------------------- config


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Pool:
    name: str
    kind: str
    labels: tuple[str, ...]
    repos: frozenset[str]
    max_runners: int
    host: str = ""
    runner_dir: str = ""

    @property
    def label_set(self) -> frozenset[str]:
        return frozenset(label.lower() for label in self.labels)


@dataclass(frozen=True)
class Config:
    pools: tuple[Pool, ...]
    poll_interval: int
    idle_timeout: int

    @property
    def repos(self) -> list[str]:
        return sorted(set().union(*(p.repos for p in self.pools)))


def host_arch_label() -> str:
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "ARM64"
    if machine in ("x86_64", "amd64"):
        return "X64"
    raise ConfigError(f"unsupported host architecture: {machine}")


def _require_int(table: dict, key: str, default: int, minimum: int, where: str) -> int:
    value = table.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise ConfigError(f"{where}.{key} must be an integer >= {minimum}")
    return value


def _require_str_list(table: dict, key: str, where: str) -> list[str]:
    value = table.get(key)
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        raise ConfigError(f"{where}.{key} must be a non-empty list of strings")
    return value


def _check_keys(table: dict, allowed: set[str], where: str) -> None:
    unknown = set(table) - allowed
    if unknown:
        raise ConfigError(f"{where}: unknown keys {sorted(unknown)}")


def parse_config(data: dict, arch_label: str) -> Config:
    _check_keys(data, {"poll_interval", "idle_timeout", "pools"}, "config")
    poll_interval = _require_int(data, "poll_interval", 15, 5, "config")
    idle_timeout = _require_int(data, "idle_timeout", 600, 60, "config")

    pools_table = data.get("pools")
    if not isinstance(pools_table, dict) or not pools_table:
        raise ConfigError("config.pools must define at least one pool")

    pools = []
    for name, table in pools_table.items():
        where = f"pools.{name}"
        if not POOL_NAME_RE.match(name):
            raise ConfigError(f"{where}: pool names may contain only a-z, 0-9 and '-'")
        if not isinstance(table, dict):
            raise ConfigError(f"{where} must be a table")
        kind = table.get("kind")
        common = {"kind", "labels", "repos", "max_runners"}

        labels = _require_str_list(table, "labels", where)
        repos = [r.lower() for r in _require_str_list(table, "repos", where)]
        for repo in repos:
            if not REPO_RE.match(repo):
                raise ConfigError(f"{where}.repos: '{repo}' is not owner/name")

        if kind == "docker":
            _check_keys(table, common, where)
            if arch_label.lower() not in {label.lower() for label in labels}:
                labels = [*labels, arch_label]
            pools.append(
                Pool(
                    name=name,
                    kind=kind,
                    labels=tuple(labels),
                    repos=frozenset(repos),
                    max_runners=_require_int(table, "max_runners", 1, 1, where),
                )
            )
        elif kind == "windows":
            _check_keys(table, common | {"host", "runner_dir"}, where)
            # The pool owns a single runner directory, which can host only one runner at a time
            if table.get("max_runners", 1) != 1:
                raise ConfigError(f"{where}.max_runners must be 1 for a windows pool")
            host = table.get("host")
            runner_dir = table.get("runner_dir")
            if not isinstance(host, str) or not host or host.startswith("-"):
                raise ConfigError(f"{where}.host must be an ssh host name")
            if not isinstance(runner_dir, str) or not runner_dir:
                raise ConfigError(f"{where}.runner_dir must be a path")
            if UNSAFE_REMOTE_CHARS & set(runner_dir):
                raise ConfigError(f"{where}.runner_dir contains characters that cannot be quoted safely")
            pools.append(
                Pool(
                    name=name,
                    kind=kind,
                    labels=tuple(labels),
                    repos=frozenset(repos),
                    max_runners=1,
                    host=host,
                    runner_dir=runner_dir.rstrip("\\"),
                )
            )
        else:
            raise ConfigError(f"{where}.kind must be 'docker' or 'windows'")

    return Config(pools=tuple(pools), poll_interval=poll_interval, idle_timeout=idle_timeout)


# ---------------------------------------------------------------- decisions


def allows_self_hosted(repo_info: dict) -> bool:
    # A public repository lets anyone's pull request run code on these machines
    return repo_info.get("private") is True and repo_info.get("visibility") == "private"


def match_pool(pools: tuple[Pool, ...], repo: str, job_labels: list[str]) -> Pool | None:
    wanted = {label.lower() for label in job_labels}
    if not wanted:
        return None
    for pool in pools:
        if repo in pool.repos and wanted <= pool.label_set:
            return pool
    return None


@dataclass
class Runner:
    name: str
    pool: Pool
    repo: str
    runner_id: int
    started_at: float
    proc: subprocess.Popen | None = None
    assigned: bool = False
    # The local process is gone but GitHub still reports the runner online (e.g. ssh dropped)
    detached: bool = False

    @property
    def waiting(self) -> bool:
        return not self.assigned and not self.detached


def count_demand(pools: tuple[Pool, ...], queued: dict[str, list[list[str]]]) -> Counter:
    demand: Counter = Counter()
    for repo, jobs in queued.items():
        for labels in jobs:
            pool = match_pool(pools, repo, labels)
            if pool is not None:
                demand[(pool.name, repo)] += 1
    return demand


def plan_spawns(
    pools: tuple[Pool, ...],
    demand: Counter,
    runners: list[Runner],
    blocked_pools: set[str],
) -> list[tuple[Pool, str]]:
    by_name = {p.name: p for p in pools}
    waiting = Counter((r.pool.name, r.repo) for r in runners if r.waiting)
    active = Counter(r.pool.name for r in runners)
    spawns = []
    for (pool_name, repo), count in sorted(demand.items()):
        if pool_name in blocked_pools:
            continue
        pool = by_name[pool_name]
        n = min(count - waiting[(pool_name, repo)], pool.max_runners - active[pool_name])
        if n > 0:
            active[pool_name] += n
            spawns.extend([(pool, repo)] * n)
    return spawns


def idle_runners(runners: list[Runner], now: float, idle_timeout: int) -> list[Runner]:
    return [r for r in runners if r.waiting and now - r.started_at > idle_timeout]


def runner_name(pool: Pool, repo: str) -> str:
    repo_name = repo.split("/", 1)[1][:30]
    return f"{pool.name}-{repo_name}-{secrets.token_hex(3)}"


# ---------------------------------------------------------------- GitHub API


class ApiError(Exception):
    def __init__(self, status: int, method: str, path: str, detail: str):
        super().__init__(f"{method} {path} -> {status or 'network error'}: {detail}")
        self.status = status


class GitHub:
    def __init__(self) -> None:
        self._token = self._read_token()
        self._etags: dict[str, tuple[str, object]] = {}
        self._rate_warned_at = 0.0

    @staticmethod
    def _read_token() -> str:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        token = result.stdout.strip()
        if result.returncode != 0 or not token:
            raise SystemExit("Error: gh is not authenticated. Run: gh auth login")
        return token

    def request(self, method: str, path: str, body: dict | None = None, _retry: bool = True):
        req = urllib.request.Request(API_URL + path, method=method)
        req.add_header("Authorization", f"Bearer {self._token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        cached = self._etags.get(path) if method == "GET" else None
        if cached:
            # 304 responses do not count against the rate limit
            req.add_header("If-None-Match", cached[0])
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, data=data, timeout=30) as resp:
                self._note_rate_limit(resp.headers)
                raw = resp.read()
                payload = json.loads(raw) if raw else None
                etag = resp.headers.get("ETag")
                if method == "GET" and etag:
                    self._etags[path] = (etag, payload)
                return payload
        except urllib.error.HTTPError as e:
            if e.code == 304 and cached:
                return cached[1]
            if e.code == 401 and _retry:
                self._token = self._read_token()
                return self.request(method, path, body, _retry=False)
            detail = e.read().decode(errors="replace")[:300]
            raise ApiError(e.code, method, path, detail) from None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ApiError(0, method, path, str(e)) from None

    def _note_rate_limit(self, headers) -> None:
        remaining = headers.get("X-RateLimit-Remaining")
        if remaining is None or int(remaining) >= RATE_LIMIT_WARN_THRESHOLD:
            return
        now = time.monotonic()
        if now - self._rate_warned_at > 600:
            self._rate_warned_at = now
            log(f"WARNING: GitHub API rate limit low ({remaining} left). Consider a larger poll_interval.")


# ---------------------------------------------------------------- launchers


def _quote_remote(value: str) -> str:
    return f'"{value}"'


class DockerLauncher:
    def __init__(self, pool: Pool, gh: GitHub) -> None:
        self.pool = pool
        self.gh = gh
        self.version: str | None = None
        self._checked_at = 0.0

    def prepare(self) -> None:
        leftovers = subprocess.run(
            ["docker", "ps", "-aq", "--filter", f"label={DOCKER_POOL_LABEL}={self.pool.name}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
        if leftovers:
            log(f"[{self.pool.name}] Removing {len(leftovers)} leftover container(s)")
            subprocess.run(["docker", "rm", "-f", *leftovers], capture_output=True)
        self.refresh_image()
        if self.version is None:
            raise SystemExit(f"Error: could not build the runner image for pool {self.pool.name}")

    def tick(self, now: float) -> None:
        if now - self._checked_at >= VERSION_CHECK_INTERVAL:
            self.refresh_image()

    def refresh_image(self) -> None:
        self._checked_at = time.monotonic()
        try:
            latest = self.gh.request("GET", "/repos/actions/runner/releases/latest")["tag_name"].lstrip("v")
        except ApiError as e:
            log(f"[{self.pool.name}] WARNING: could not fetch the latest runner version: {e}")
            return
        if latest == self.version:
            return
        log(f"[{self.pool.name}] Building {DOCKER_IMAGE}:{latest}")
        # BuildKit is required: the classic builder does not set TARGETARCH
        result = subprocess.run(
            [
                "docker",
                "build",
                "--build-arg",
                f"RUNNER_VERSION={latest}",
                "-t",
                f"{DOCKER_IMAGE}:{latest}",
                str(SCRIPT_DIR / "pools" / "docker"),
            ],
            env={**os.environ, "DOCKER_BUILDKIT": "1"},
        )
        if result.returncode != 0:
            log(f"[{self.pool.name}] WARNING: image build failed, keeping {self.version}")
            return
        self.version = latest

    def command(self, name: str, repo: str) -> list[str]:
        slug = repo.replace("/", "-")
        return [
            "docker",
            "run",
            "-i",
            "--rm",
            "--name",
            name,
            "--label",
            f"{DOCKER_POOL_LABEL}={self.pool.name}",
            "-v",
            f"gh-runner-{slug}-npm-cache:/home/runner/.npm",
            "-v",
            f"gh-runner-{slug}-playwright:/home/runner/pw-browsers",
            "-v",
            f"gh-runner-{slug}-hook-test-slots:/home/runner/.local/state/run_hook_tests",
            "-e",
            "PLAYWRIGHT_BROWSERS_PATH=/home/runner/pw-browsers",
            f"{DOCKER_IMAGE}:{self.version}",
        ]

    def stop(self, runner: Runner) -> None:
        subprocess.run(["docker", "rm", "-f", runner.name], capture_output=True, timeout=STOP_TIMEOUT)


class WindowsLauncher:
    def __init__(self, pool: Pool) -> None:
        self.pool = pool
        self.wrapper_path = f"{pool.runner_dir}\\{WINDOWS_WRAPPER}"

    def _ssh(self, *remote: str) -> list[str]:
        return [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=4",
            "-o",
            "LogLevel=ERROR",
            self.pool.host,
            *remote,
        ]

    def _wrapper(self, *args: str) -> list[str]:
        return self._ssh(
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            _quote_remote(self.wrapper_path),
            "-RunnerDir",
            _quote_remote(self.pool.runner_dir),
            *args,
        )

    def prepare(self) -> None:
        remote = self.wrapper_path.replace("\\", "/")
        result = subprocess.run(
            [
                "scp",
                "-q",
                "-o",
                "BatchMode=yes",
                "-o",
                "LogLevel=ERROR",
                str(SCRIPT_DIR / "pools" / "windows" / "run-jit.ps1"),
                f"{self.pool.host}:{remote}",
            ],
        )
        if result.returncode != 0:
            raise SystemExit(f"Error: could not copy the runner wrapper to {self.pool.host}")
        # Runners left by a previous dispatcher are no longer tracked; clear them before the first job
        self._run_stop()

    def tick(self, now: float) -> None:
        pass

    def command(self, name: str, repo: str) -> list[str]:
        return self._wrapper()

    def stop(self, runner: Runner) -> None:
        self._run_stop()

    def _run_stop(self) -> None:
        result = subprocess.run(
            self._wrapper("-Stop"),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=STOP_TIMEOUT,
        )
        for line in (result.stdout + result.stderr).splitlines():
            log(f"[{self.pool.name}] {line}")
        if result.returncode != 0:
            log(f"[{self.pool.name}] WARNING: stopping the remote runner failed (exit {result.returncode})")


def start_process(name: str, command: list[str], jit_config: str) -> subprocess.Popen:
    # A new session keeps Ctrl+C in the terminal from reaching the runners, so draining can let jobs finish
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    assert proc.stdin is not None and proc.stdout is not None
    try:
        proc.stdin.write(jit_config + "\n")
        proc.stdin.close()
    except BrokenPipeError:
        pass
    threading.Thread(target=_stream_output, args=(name, proc.stdout), daemon=True).start()
    return proc


def _stream_output(name: str, stream: IO[str]) -> None:
    for line in stream:
        log(f"[{name}] {line.rstrip()}")


# ---------------------------------------------------------------- dispatcher


class Dispatcher:
    def __init__(self, config: Config, gh: GitHub) -> None:
        self.config = config
        self.gh = gh
        self.launchers: dict[str, DockerLauncher | WindowsLauncher] = {}
        for pool in config.pools:
            if pool.kind == "docker":
                self.launchers[pool.name] = DockerLauncher(pool, gh)
            else:
                self.launchers[pool.name] = WindowsLauncher(pool)
        self.runners: list[Runner] = []
        self.blocked_until: dict[str, float] = {}
        self.refused_repos: set[str] = set()
        self.draining = False
        self._drain_started = 0.0
        self.force_stop = False
        self._wake = threading.Event()

    # -- lifecycle

    def handle_signal(self, signum, frame) -> None:
        now = time.monotonic()
        if not self.draining:
            self.draining = True
            self._drain_started = now
            log("Draining: no new runners; busy runners finish their jobs. Press Ctrl+C again to stop them now.")
        # `uv run` forwards the terminal's SIGINT, so one Ctrl+C arrives twice
        elif now - self._drain_started > SIGNAL_DEBOUNCE:
            self.force_stop = True
            log("Stopping all runners now")
        self._wake.set()

    def check_repos(self) -> None:
        for repo in self.config.repos:
            try:
                info = self.gh.request("GET", f"/repos/{repo}")
            except ApiError as e:
                raise SystemExit(f"Error: cannot read {repo}: {e}") from None
            if not allows_self_hosted(info):
                raise SystemExit(f"Error: {repo} is not a private repository; self-hosted runners are refused")

    def run(self) -> None:
        self.check_repos()
        for pool in self.config.pools:
            self.launchers[pool.name].prepare()
        log(f"Watching {', '.join(self.config.repos)} every {self.config.poll_interval}s")
        while True:
            if self.force_stop:
                for runner in list(self.runners):
                    self.terminate(runner, "shutdown", force=True)
                break
            self.reap_exited()
            self.settle_detached()
            if self.draining:
                for runner in [r for r in self.runners if r.waiting]:
                    self.terminate(runner, "draining")
                if not self.runners:
                    break
            else:
                self.dispatch_once()
            self._wake.wait(self.config.poll_interval)
            self._wake.clear()
        log("Stopped.")

    def dispatch_once(self) -> None:
        now = time.monotonic()
        queued, assigned = self.scan()
        for runner in self.runners:
            if runner.name in assigned and not runner.assigned:
                runner.assigned = True
        for runner in idle_runners(self.runners, now, self.config.idle_timeout):
            self.terminate(runner, "idle timeout")
        demand = count_demand(self.config.pools, queued)
        blocked = {name for name, until in self.blocked_until.items() if until > now}
        for pool, repo in plan_spawns(self.config.pools, demand, self.runners, blocked):
            self.spawn(pool, repo)
        for launcher in self.launchers.values():
            launcher.tick(now)

    # -- GitHub state

    def scan(self) -> tuple[dict[str, list[list[str]]], set[str]]:
        queued: dict[str, list[list[str]]] = {}
        assigned: set[str] = set()
        for repo in self.config.repos:
            try:
                if not self._repo_allowed(repo):
                    continue
                run_ids: dict[int, None] = {}
                for status in ("queued", "in_progress"):
                    data = self.gh.request("GET", f"/repos/{repo}/actions/runs?status={status}&per_page=100")
                    for run in data["workflow_runs"]:
                        run_ids[run["id"]] = None
                for run_id in run_ids:
                    data = self.gh.request(
                        "GET", f"/repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"
                    )
                    for job in data["jobs"]:
                        if job["status"] == "queued":
                            queued.setdefault(repo, []).append(job["labels"])
                        if job.get("runner_name"):
                            assigned.add(job["runner_name"])
            except ApiError as e:
                log(f"WARNING: scanning {repo} failed: {e}")
        return queued, assigned

    def _repo_allowed(self, repo: str) -> bool:
        allowed = allows_self_hosted(self.gh.request("GET", f"/repos/{repo}"))
        if not allowed and repo not in self.refused_repos:
            log(f"WARNING: {repo} is no longer private; not starting runners for it")
            self.refused_repos.add(repo)
        elif allowed:
            self.refused_repos.discard(repo)
        return allowed

    # -- runner lifecycle

    def spawn(self, pool: Pool, repo: str) -> None:
        name = runner_name(pool, repo)
        launcher = self.launchers[pool.name]
        try:
            resp = self.gh.request(
                "POST",
                f"/repos/{repo}/actions/runners/generate-jitconfig",
                {"name": name, "runner_group_id": RUNNER_GROUP_ID, "labels": list(pool.labels)},
            )
        except ApiError as e:
            log(f"[{name}] ERROR: could not create a JIT config: {e}")
            self._back_off(pool)
            return
        runner = Runner(name=name, pool=pool, repo=repo, runner_id=resp["runner"]["id"], started_at=time.monotonic())
        try:
            runner.proc = start_process(name, launcher.command(name, repo), resp["encoded_jit_config"])
        except OSError as e:
            log(f"[{name}] ERROR: could not start the runner: {e}")
            self._delete_registration(runner)
            self._back_off(pool)
            return
        self.runners.append(runner)
        log(f"[{name}] Started for {repo} (pool {pool.name})")

    def reap_exited(self) -> None:
        now = time.monotonic()
        for runner in list(self.runners):
            if runner.proc is None or runner.proc.poll() is None:
                continue
            log(f"[{runner.name}] Exited (code {runner.proc.returncode})")
            runner.proc = None
            if not runner.assigned and now - runner.started_at < LAUNCH_FAILURE_WINDOW:
                self._back_off(runner.pool)
            self._settle(runner)

    def settle_detached(self) -> None:
        for runner in [r for r in self.runners if r.detached]:
            self._settle(runner)

    def _settle(self, runner: Runner) -> None:
        try:
            info = self.gh.request("GET", f"/repos/{runner.repo}/actions/runners/{runner.runner_id}")
        except ApiError as e:
            if e.status == 404:
                self._forget(runner)
            else:
                runner.detached = True
            return
        if info.get("status") == "online":
            if not runner.detached:
                log(f"[{runner.name}] Process ended but GitHub reports it online; waiting for it to finish")
            runner.detached = True
            return
        self._delete_registration(runner)
        self._forget(runner)

    def terminate(self, runner: Runner, reason: str, force: bool = False) -> None:
        if not runner.assigned:
            # Deleting the registration makes an idle listener exit, and GitHub refuses it once the runner has a job.
            # This catches a job picked up since the last scan.
            if self._delete_registration(runner) == RUNNER_BUSY_STATUS and not force:
                runner.assigned = True
                log(f"[{runner.name}] Picked up a job; letting it finish")
                return
        log(f"[{runner.name}] Stopping ({reason})")
        try:
            self.launchers[runner.pool.name].stop(runner)
        except subprocess.TimeoutExpired:
            log(f"[{runner.name}] WARNING: stop command timed out")
        if runner.proc is not None:
            try:
                runner.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                runner.proc.kill()
                runner.proc.wait()
        if self._delete_registration(runner) == RUNNER_BUSY_STATUS:
            log(
                f"[{runner.name}] Its job was interrupted. Once GitHub shows the runner offline, "
                f"remove it with ./cleanup-runners.sh {runner.repo}"
            )
        self._forget(runner)

    def _forget(self, runner: Runner) -> None:
        if runner in self.runners:
            self.runners.remove(runner)

    def _delete_registration(self, runner: Runner) -> int:
        """Return 0 once the registration is gone, otherwise the HTTP status of the refusal."""
        try:
            self.gh.request("DELETE", f"/repos/{runner.repo}/actions/runners/{runner.runner_id}")
        except ApiError as e:
            if e.status == 404:
                return 0
            if e.status != RUNNER_BUSY_STATUS:
                log(f"[{runner.name}] WARNING: could not delete the runner registration: {e}")
            return e.status
        return 0

    def _back_off(self, pool: Pool) -> None:
        self.blocked_until[pool.name] = time.monotonic() + LAUNCH_FAILURE_BACKOFF
        log(f"[{pool.name}] Launch failed; pausing this pool for {LAUNCH_FAILURE_BACKOFF}s")


# ---------------------------------------------------------------- main


def load_config(path: Path) -> Config:
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        raise SystemExit(f"Error: {path} not found. Copy config.example.toml to start.") from None
    except tomllib.TOMLDecodeError as e:
        raise SystemExit(f"Error: {path}: {e}") from None
    try:
        return parse_config(data, host_arch_label())
    except ConfigError as e:
        raise SystemExit(f"Error: {path}: {e}") from None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=SCRIPT_DIR / "config.toml")
    args = parser.parse_args()

    config = load_config(args.config)
    # Two dispatchers on one config would each start runners for the same jobs
    lock = args.config.open("rb")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(f"Error: another dispatcher is already using {args.config}") from None

    dispatcher = Dispatcher(config, GitHub())
    signal.signal(signal.SIGINT, dispatcher.handle_signal)
    signal.signal(signal.SIGTERM, dispatcher.handle_signal)
    dispatcher.run()


if __name__ == "__main__":
    sys.exit(main())
