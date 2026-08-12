#!/usr/bin/env python3
"""Secretless local MCP proxy, broker, and approval controller."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import pwd
import secrets
import selectors
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, NoReturn

SOCKET_ROOT = "/var/run/dotfiles-agent-secrets"
APPROVAL_TTL_ENV = "AGENT_SECRET_BROKER_APPROVAL_TTL"
MAX_LINE = 1 << 20
READ_BUFFER = 64 << 10
RESPONSE_DRAIN_TIMEOUT = 30
_ALLOWED_METHODS = frozenset({"initialize", "notifications/initialized", "ping", "tools/list", "tools/call"})

# macOS getsockopt(SOL_LOCAL, LOCAL_PEERCRED) reads struct xucred (sys/ucred.h);
# CPython's socket module exposes neither the constants nor a getpeereid() method.
_DARWIN_SOL_LOCAL = 0
_DARWIN_LOCAL_PEERCRED = 0x001
_DARWIN_XUCRED_FORMAT = "=IIH2x16I"


class ConfigError(Exception):
    """A policy or command-line boundary rejected an input."""


@dataclass(frozen=True)
class UpstreamPolicy:
    argv: tuple[str, ...]
    credential_env: str
    credential_file: pathlib.Path


@dataclass(frozen=True)
class BrokerPolicy:
    consumer: str
    request_uid: int
    operator_uid: int
    upstream: UpstreamPolicy
    read_tools: frozenset[str]
    write_tools: frozenset[str]
    credential: str

    @property
    def allowed_tools(self) -> frozenset[str]:
        return self.read_tools | self.write_tools


@dataclass
class PendingApproval:
    consumer: str
    tool: str
    arguments: dict[str, Any]
    canonical_arguments: str
    nonce: str
    expires_at: int
    approval: str
    state: str = "pending"
    retire_at: float = 0.0


@dataclass(frozen=True)
class ClaimResult:
    status: str
    pending: PendingApproval | None = None


def _fail(message: str) -> NoReturn:
    raise ConfigError(message)


def _approval_ttl() -> int:
    raw = os.environ.get(APPROVAL_TTL_ENV)
    if raw is None:
        return 60
    try:
        ttl = int(raw)
    except ValueError:
        _fail(f"{APPROVAL_TTL_ENV} must be a positive integer")
    if ttl <= 0:
        _fail(f"{APPROVAL_TTL_ENV} must be a positive integer")
    return ttl


APPROVAL_TTL = _approval_ttl()


def _validate_abs_path(value: Any, label: str) -> pathlib.Path:
    if not isinstance(value, str) or not value or not value.startswith("/"):
        _fail(f"{label} must be an absolute path")
    path = pathlib.Path(value)
    if path.name in {"", ".", ".."}:
        _fail(f"invalid {label}")
    try:
        parent = path.parent
        if parent.is_symlink() or not parent.is_dir():
            _fail(f"{label} parent is not a directory")
    except OSError:
        _fail(f"cannot inspect {label}")
    return path


def _safe_file(path: pathlib.Path, label: str, executable: bool = False) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError:
        _fail(f"{label} is unavailable")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        _fail(f"{label} must be a regular file")
    if info.st_uid not in {0, os.geteuid()} or info.st_mode & 0o022:
        _fail(f"{label} ownership or mode is unsafe")
    if executable and not info.st_mode & 0o111:
        _fail(f"{label} is not executable")
    return info


def _string_list(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or any(
        not isinstance(item, str) or not item or "\x00" in item for item in value
    ):
        _fail(f"{label} must be a non-empty string list")
    return tuple(value)


def _tool_list(value: Any, label: str) -> frozenset[str]:
    if not isinstance(value, list) or any(
        not isinstance(item, str) or not item or "\x00" in item for item in value
    ):
        _fail(f"{label} must be a string list")
    return frozenset(value)


def _read_credential(path: pathlib.Path) -> str:
    info = _safe_file(path, "credential file")
    if info.st_mode & 0o077:
        _fail("credential file must not be accessible by group or other")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as handle:
            raw = handle.read(1 << 20)
    except OSError:
        _fail("credential file cannot be read")
    try:
        credential = raw.decode("utf-8")
    except UnicodeDecodeError:
        _fail("credential file is not UTF-8")
    if credential.endswith("\n"):
        credential = credential[:-1]
        credential = credential.removesuffix("\r")
    if not credential or "\x00" in credential:
        _fail("credential file is empty or contains NUL")
    return credential


def load_policy(path_value: str) -> BrokerPolicy:
    path = _validate_abs_path(path_value, "policy path")
    _safe_file(path, "policy file")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        _fail("policy is not valid JSON")
    if not isinstance(document, dict):
        _fail("policy must be an object")
    required = {"consumer", "request_uid", "operator_uid", "upstream", "tools"}
    if set(document) != required:
        _fail("policy keys are invalid")
    consumer = document["consumer"]
    if not isinstance(consumer, str) or not consumer or any(
        character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        for character in consumer
    ):
        _fail("consumer is invalid")
    request_uid = document["request_uid"]
    operator_uid = document["operator_uid"]
    if any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in (request_uid, operator_uid)):
        _fail("policy UIDs are invalid")
    upstream = document["upstream"]
    tools = document["tools"]
    if not isinstance(upstream, dict) or set(upstream) != {"argv", "credential_env", "credential_file"}:
        _fail("upstream policy is invalid")
    if not isinstance(tools, dict) or set(tools) != {"read", "write"}:
        _fail("tool policy is invalid")
    argv = _string_list(upstream["argv"], "upstream argv")
    executable = _validate_abs_path(argv[0], "upstream executable").resolve(strict=True)
    _safe_file(executable, "upstream executable", executable=True)
    argv = (str(executable), *argv[1:])
    credential_env = upstream["credential_env"]
    if not isinstance(credential_env, str) or not credential_env.isidentifier() or "\x00" in credential_env:
        _fail("credential environment name is invalid")
    credential_file = _validate_abs_path(upstream["credential_file"], "credential path")
    read_tools = _tool_list(tools["read"], "read tools")
    write_tools = _tool_list(tools["write"], "write tools")
    if read_tools & write_tools:
        _fail("a tool cannot be both read and write")
    credential = _read_credential(credential_file)
    if any(credential in argument for argument in argv):
        _fail("credential cannot be present in upstream argv")
    return BrokerPolicy(
        consumer=consumer,
        request_uid=request_uid,
        operator_uid=operator_uid,
        upstream=UpstreamPolicy(argv, credential_env, credential_file),
        read_tools=read_tools,
        write_tools=write_tools,
        credential=credential,
    )


def socket_path(value: str, label: str) -> pathlib.Path:
    path = _validate_abs_path(value, label)
    if path.parent == path:
        _fail(f"invalid {label}")
    return path


def ensure_socket_parent(value: str, request_gid: int) -> None:
    path = pathlib.Path(value)
    parent = path.parent
    if parent != pathlib.Path(SOCKET_ROOT):
        _fail("socket path parent is not managed")
    if os.geteuid() != 0:
        _fail("creating the managed socket parent requires root")
    try:
        parent.mkdir(mode=0o710, parents=True, exist_ok=True)
        info = parent.lstat()
    except OSError as exc:
        raise ConfigError("socket path parent cannot be created") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        _fail("socket path parent is not a directory")
    if info.st_uid != 0:
        _fail("socket path parent must be root-owned")
    try:
        os.chown(parent, 0, request_gid)
        os.chmod(parent, 0o710)
    except OSError as exc:
        raise ConfigError("socket path parent permissions cannot be set") from exc


def default_request_socket(consumer: str) -> pathlib.Path:
    return pathlib.Path(SOCKET_ROOT) / f"{consumer}.sock"


def default_control_socket(consumer: str) -> pathlib.Path:
    return pathlib.Path(SOCKET_ROOT) / f"{consumer}.control.sock"


def _peer_uid(connection: socket.socket) -> int:
    try:
        if sys.platform.startswith("linux"):
            credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            return struct.unpack("3i", credentials)[1]
        if sys.platform == "darwin":
            credentials = connection.getsockopt(
                _DARWIN_SOL_LOCAL, _DARWIN_LOCAL_PEERCRED, struct.calcsize(_DARWIN_XUCRED_FORMAT)
            )
            return struct.unpack(_DARWIN_XUCRED_FORMAT, credentials)[1]
    except (AttributeError, OSError, struct.error, TypeError, ValueError):
        pass
    raise ConfigError("peer credentials are unavailable")


def _json_line(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode(
        "utf-8"
    )


def _id_key(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _rpc_error(request_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def _redact(value: Any, secret: str) -> Any:
    if isinstance(value, str):
        return value.replace(secret, "[REDACTED]")
    if isinstance(value, list):
        return [_redact(item, secret) for item in value]
    if isinstance(value, dict):
        return {_redact(key, secret): _redact(item, secret) for key, item in value.items()}
    return value


def _canonical_arguments(arguments: dict[str, Any]) -> str:
    return json.dumps(arguments, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _approval_digest(consumer: str, tool: str, canonical_arguments: str, nonce: str, expires_at: int) -> str:
    material = f"{consumer}{tool}{canonical_arguments}{nonce}{expires_at}".encode()
    return hashlib.sha256(material).hexdigest()


class PendingStore:
    def __init__(self, policy: BrokerPolicy):
        self._policy = policy
        self._lock = threading.RLock()
        self._by_nonce: dict[str, PendingApproval] = {}
        self._by_key: dict[tuple[str, str], PendingApproval] = {}

    def _cleanup(self, now: float) -> None:
        for nonce, item in list(self._by_nonce.items()):
            if item.state in {"pending", "approved"} and now >= item.expires_at:
                item.state = "expired"
                item.retire_at = now + APPROVAL_TTL
                self._by_key.pop((item.tool, item.canonical_arguments), None)
            elif item.state in {"expired", "consumed"} and item.retire_at and now >= item.retire_at:
                self._by_nonce.pop(nonce, None)

    def create_or_get(self, tool: str, arguments: dict[str, Any]) -> PendingApproval:
        canonical = _canonical_arguments(arguments)
        key = (tool, canonical)
        now = time.time()
        with self._lock:
            self._cleanup(now)
            previous = self._by_key.get(key)
            if previous is not None and previous.state in {"pending", "approved"}:
                return previous
            nonce = secrets.token_urlsafe(24)
            expires_at = int(now) + APPROVAL_TTL
            item = PendingApproval(
                consumer=self._policy.consumer,
                tool=tool,
                arguments=arguments,
                canonical_arguments=canonical,
                nonce=nonce,
                expires_at=expires_at,
                approval=_approval_digest(self._policy.consumer, tool, canonical, nonce, expires_at),
            )
            self._by_nonce[nonce] = item
            self._by_key[key] = item
            return item

    def claim(self, tool: str, arguments: dict[str, Any], nonce: str | None = None) -> ClaimResult:
        canonical = _canonical_arguments(arguments)
        now = time.time()
        with self._lock:
            self._cleanup(now)
            if nonce is not None:
                item = self._by_nonce.get(nonce)
                if item is None or item.tool != tool or item.canonical_arguments != canonical:
                    return ClaimResult("mismatch")
                if item.state == "consumed":
                    return ClaimResult("replay", item)
                if item.state == "expired":
                    return ClaimResult("expired", item)
            item = self._by_key.get((tool, canonical))
            if item is None:
                return ClaimResult("none")
            if item.state == "pending" or nonce is None:
                return ClaimResult("pending", item)
            if item.state == "expired":
                return ClaimResult("expired", item)
            if item.state == "consumed":
                return ClaimResult("replay", item)
            if item.state != "approved" or now >= item.expires_at:
                item.state = "expired"
                item.retire_at = now + APPROVAL_TTL
                self._by_key.pop((tool, canonical), None)
                return ClaimResult("expired", item)
            if nonce != item.nonce:
                return ClaimResult("mismatch", item)
            item.state = "consumed"
            item.retire_at = now + APPROVAL_TTL
            self._by_key.pop((tool, canonical), None)
            return ClaimResult("approved", item)

    def approve(self, nonce: str, details: dict[str, Any]) -> tuple[str, PendingApproval | None]:
        now = time.time()
        with self._lock:
            self._cleanup(now)
            item = self._by_nonce.get(nonce)
            if item is None:
                return "unknown", None
            if item.state in {"approved", "consumed"}:
                return "replay", item
            if item.state == "expired" or now >= item.expires_at:
                item.state = "expired"
                item.retire_at = now + APPROVAL_TTL
                self._by_key.pop((item.tool, item.canonical_arguments), None)
                return "expired", item
            if not self._details_match(item, details):
                return "mismatch", item
            item.state = "approved"
            return "approved", item

    @staticmethod
    def _details_match(item: PendingApproval, details: dict[str, Any]) -> bool:
        if "approval" in details and details["approval"] != item.approval:
            return False
        if "consumer" in details and details["consumer"] != item.consumer:
            return False
        if "tool" in details and details["tool"] != item.tool:
            return False
        if "expires_at" in details and details["expires_at"] != item.expires_at:
            return False
        if "arguments" in details:
            arguments = details["arguments"]
            if not isinstance(arguments, dict) or _canonical_arguments(arguments) != item.canonical_arguments:
                return False
        return True

    def snapshot(self, secret: str) -> list[dict[str, Any]]:
        with self._lock:
            self._cleanup(time.time())
            return [
                {
                    "consumer": item.consumer,
                    "tool": item.tool,
                    "arguments": _redact(item.arguments, secret),
                    "nonce": item.nonce,
                    "expires_at": item.expires_at,
                    "approval": item.approval,
                    "state": item.state,
                }
                for item in self._by_nonce.values()
                if item.state in {"pending", "approved"}
            ]


def _resolve_run_user(name: str | None, policy: BrokerPolicy) -> pwd.struct_passwd | None:
    if not name:
        return None
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        _fail("service user does not exist")
    if account.pw_uid in {0, policy.request_uid, policy.operator_uid}:
        _fail("service user must be distinct from root, requester, and operator")
    if os.geteuid() != 0:
        _fail("--run-user requires root")
    return account


def _drop_privileges(account: pwd.struct_passwd) -> None:
    try:
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
    except OSError:
        _fail("cannot enter service identity")
    if os.geteuid() != account.pw_uid or os.getegid() != account.pw_gid:
        _fail("service identity transition failed")


class UpstreamSession:
    def __init__(
        self,
        policy: BrokerPolicy,
        on_line: Callable[[bytes], None],
        upstream_home: pathlib.Path,
    ):
        self._policy = policy
        self._on_line = on_line
        self._upstream_home = upstream_home
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._reader: threading.Thread | None = None

    def send(self, payload: bytes) -> None:
        with self._lock:
            if self._process is None:
                try:
                    executable_dir = str(pathlib.Path(self._policy.upstream.argv[0]).parent)
                    self._process = subprocess.Popen(
                        self._policy.upstream.argv,
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        cwd=self._upstream_home,
                        env={
                            self._policy.upstream.credential_env: self._policy.credential,
                            "HOME": str(self._upstream_home),
                            "NO_COLOR": "1",
                            "PATH": f"{executable_dir}:/usr/local/bin:/usr/bin:/bin",
                        },
                        close_fds=True,
                    )
                except OSError as exc:
                    raise RuntimeError("upstream unavailable") from exc
                self._reader = threading.Thread(target=self._read, daemon=True)
                self._reader.start()
            process = self._process
            if process.stdin is None:
                raise RuntimeError("upstream unavailable")
            try:
                process.stdin.write(payload.rstrip(b"\r\n") + b"\n")
                process.stdin.flush()
            except OSError as exc:
                raise RuntimeError("upstream unavailable") from exc

    def _read(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        try:
            for line in process.stdout:
                self._on_line(line)
        except OSError:
            return

    def close(self) -> None:
        with self._lock:
            process = self._process
            self._process = None
        if process is None:
            return
        try:
            if process.stdin is not None:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass


class ClientSession:
    def __init__(self, broker: Broker, connection: socket.socket):
        self.broker = broker
        self.connection = connection
        self._output_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._upstream: UpstreamSession | None = None
        self._methods: dict[str, str] = {}
        self._idle = threading.Event()
        self._idle.set()

    def send(self, value: Any) -> None:
        payload = _json_line(_redact(value, self.broker.policy.credential))
        try:
            with self._output_lock:
                self.connection.sendall(payload)
        except OSError:
            pass

    def send_error(self, request: dict[str, Any] | None, code: int, message: str, data: Any = None) -> None:
        if request is not None and "id" not in request:
            return
        request_id = request.get("id") if request is not None else None
        self.send(_rpc_error(request_id, code, message, data))

    def forward(self, request: dict[str, Any], raw: bytes | None = None) -> bool:
        if self._upstream is None:
            self._upstream = UpstreamSession(
                self.broker.policy,
                self._upstream_line,
                self.broker.upstream_home,
            )
        if "id" in request and isinstance(request.get("method"), str):
            with self._state_lock:
                self._methods[_id_key(request["id"])] = request["method"]
                self._idle.clear()
        payload = raw if raw is not None else _json_line(request)
        try:
            self._upstream.send(payload)
        except RuntimeError:
            self.send_error(request, -32010, "upstream unavailable")
            return False
        return True

    def _upstream_line(self, line: bytes) -> None:
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            if self.broker.policy.credential.encode("utf-8") in line:
                self.send_error(None, -32011, "upstream response rejected")
            return
        if not isinstance(message, dict):
            return
        has_id = "id" in message
        if has_id:
            with self._state_lock:
                method = self._methods.pop(_id_key(message["id"]), None)
            if method == "tools/list":
                self._filter_tools(message)
        if "result" in message and isinstance(message["result"], dict):
            self._filter_tools(message)
        self.send(message)
        if has_id:
            with self._state_lock:
                if not self._methods:
                    self._idle.set()

    def _filter_tools(self, message: dict[str, Any]) -> None:
        result = message.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
            return
        allowed = self.broker.policy.allowed_tools
        result["tools"] = [
            tool
            for tool in result["tools"]
            if isinstance(tool, dict) and isinstance(tool.get("name"), str) and tool["name"] in allowed
        ]

    def _handle_tool_call(self, request: dict[str, Any], raw: bytes) -> None:
        params = request.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            self.send_error(request, -32602, "invalid tool call")
            return
        tool = params["name"]
        arguments = params.get("arguments", {})
        if not isinstance(arguments, dict):
            self.send_error(request, -32602, "invalid tool arguments")
            return
        if tool not in self.broker.policy.allowed_tools:
            self.send_error(request, -32602, "tool denied")
            return
        if tool in self.broker.policy.read_tools:
            self.forward(request, raw)
            return
        pending = self.broker.pending.create_or_get(tool, arguments)
        nonce = params.get("approval_nonce", params.get("_approval_nonce"))
        claim = self.broker.pending.claim(tool, arguments, nonce if isinstance(nonce, str) else None)
        if claim.status == "approved":
            forwarded = dict(request)
            forwarded_params = dict(params)
            forwarded_params.pop("approval_nonce", None)
            forwarded_params.pop("_approval_nonce", None)
            forwarded["params"] = forwarded_params
            self.forward(forwarded)
            return
        data = {
            "nonce": pending.nonce,
            "expires_at": pending.expires_at,
            "approval": pending.approval,
        }
        if claim.status == "mismatch":
            self.send_error(request, -32004, "approval mismatch", data)
        elif claim.status == "expired":
            self.send_error(request, -32002, "approval expired", data)
        elif claim.status == "replay":
            self.send_error(request, -32003, "approval replay", data)
        else:
            self.send_error(request, -32001, "approval pending", data)

    def handle_line(self, line: bytes) -> None:
        if len(line) > MAX_LINE:
            self.send_error(None, -32700, "message too large")
            return
        raw = line.rstrip(b"\r\n")
        try:
            request = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(None, -32700, "parse error")
            return
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
            self.send_error(request if isinstance(request, dict) else None, -32600, "invalid request")
            return
        method = request.get("method")
        if not isinstance(method, str):
            self.send_error(request, -32600, "invalid request")
            return
        if method not in _ALLOWED_METHODS:
            self.send_error(request, -32601, "method not allowed")
            return
        if method == "tools/call":
            self._handle_tool_call(request, raw)
            return
        self.forward(request, raw)

    def run(self) -> None:
        try:
            with self.connection, self.connection.makefile("rb") as stream:
                for line in stream:
                    self.handle_line(line)
                self._idle.wait(RESPONSE_DRAIN_TIMEOUT)
        except OSError:
            pass
        finally:
            if self._upstream is not None:
                self._upstream.close()


class Broker:
    def __init__(
        self,
        policy: BrokerPolicy,
        request_socket: pathlib.Path,
        control_socket: pathlib.Path,
        run_user: pwd.struct_passwd | None = None,
        upstream_home: pathlib.Path = pathlib.Path("/var/empty"),
    ):
        if request_socket == control_socket:
            raise ConfigError("request and control sockets must differ")
        self.policy = policy
        self.request_socket_path = request_socket
        self.control_socket_path = control_socket
        self.run_user = run_user
        self.upstream_home = upstream_home
        self.pending = PendingStore(policy)
        self._stop = threading.Event()
        self._request_listener: socket.socket | None = None
        self._control_listener: socket.socket | None = None

    @staticmethod
    def _bind(path: pathlib.Path, owner_uid: int) -> socket.socket:
        try:
            existing = path.lstat()
        except FileNotFoundError:
            existing = None
        except OSError as exc:
            raise ConfigError("socket path cannot be inspected") from exc
        if existing is not None:
            if not stat.S_ISSOCK(existing.st_mode):
                raise ConfigError("socket path is not a socket")
            path.unlink()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(path))
            listener.listen(64)
            # Narrow the mode before handing the socket away. chmod needs the
            # euid to own the file or CAP_FOWNER, and the unit's bounding set
            # is CAP_CHOWN/CAP_SETGID/CAP_SETUID only — so chowning first makes
            # the chmod fail with EPERM. This order also never widens exposure:
            # the socket is 0600 before any other uid can own it.
            os.chmod(path, 0o600)
            if os.geteuid() == 0:
                os.chown(path, owner_uid, -1)
            elif owner_uid != os.geteuid():
                raise ConfigError("socket owner differs from broker user")
        except (ConfigError, OSError) as exc:
            listener.close()
            raise ConfigError(f"socket cannot be created: {path}") from exc
        return listener

    def start(self) -> None:
        self._request_listener = self._bind(
            self.request_socket_path,
            self.policy.request_uid,
        )
        try:
            self._control_listener = self._bind(
                self.control_socket_path,
                self.policy.operator_uid,
            )
            if self.run_user is not None:
                _drop_privileges(self.run_user)
        except BaseException:
            self._request_listener.close()
            self.request_socket_path.unlink(missing_ok=True)
            raise
        threading.Thread(target=self._accept_requests, daemon=True).start()
        threading.Thread(target=self._accept_controls, daemon=True).start()

    def _accept_requests(self) -> None:
        listener = self._request_listener
        if listener is None:
            return
        while not self._stop.is_set():
            connection: socket.socket | None = None
            try:
                connection, _address = listener.accept()
                uid = _peer_uid(connection)
            except (ConfigError, OSError):
                if connection is not None:
                    connection.close()
                continue
            if uid != self.policy.request_uid:
                try:
                    connection.sendall(_json_line(_rpc_error(None, -32012, "request peer denied")))
                except OSError:
                    pass
                connection.close()
                continue
            threading.Thread(target=ClientSession(self, connection).run, daemon=True).start()

    def _accept_controls(self) -> None:
        listener = self._control_listener
        if listener is None:
            return
        while not self._stop.is_set():
            connection: socket.socket | None = None
            try:
                connection, _address = listener.accept()
                uid = _peer_uid(connection)
            except (ConfigError, OSError):
                if connection is not None:
                    connection.close()
                continue
            threading.Thread(target=self._control_session, args=(connection, uid), daemon=True).start()

    def _control_session(self, connection: socket.socket, uid: int) -> None:
        with connection:
            if uid != self.policy.operator_uid:
                try:
                    connection.sendall(_json_line({"ok": False, "error": {"code": "unauthorized", "message": "operator denied"}}))
                except OSError:
                    pass
                return
            try:
                with connection.makefile("rb") as stream:
                    line = stream.readline(MAX_LINE + 1)
                if not line or len(line) > MAX_LINE:
                    response = {"ok": False, "error": {"code": "invalid_request", "message": "invalid control request"}}
                else:
                    response = self._control_message(line)
            except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
                response = {"ok": False, "error": {"code": "invalid_request", "message": "invalid control request"}}
            try:
                connection.sendall(_json_line(response))
            except OSError:
                pass

    def _control_message(self, line: bytes) -> dict[str, Any]:
        message = json.loads(line.decode("utf-8"))
        if not isinstance(message, dict):
            return {"ok": False, "error": {"code": "invalid_request", "message": "invalid control request"}}
        action = message.get("action")
        if action in {"pending", "list"}:
            return {"ok": True, "pending": self.pending.snapshot(self.policy.credential)}
        if action != "approve" or not isinstance(message.get("nonce"), str) or not message["nonce"]:
            return {"ok": False, "error": {"code": "invalid_request", "message": "invalid control request"}}
        status, _ = self.pending.approve(message["nonce"], message)
        if status == "approved":
            return {"ok": True, "action": "approve", "nonce": message["nonce"]}
        if status == "mismatch":
            return {"ok": False, "error": {"code": "mismatch", "message": "approval mismatch"}}
        if status == "expired":
            return {"ok": False, "error": {"code": "expired", "message": "approval expired"}}
        if status == "replay":
            return {"ok": False, "error": {"code": "replay", "message": "approval replay"}}
        return {"ok": False, "error": {"code": "unknown", "message": "approval not found"}}

    def close(self) -> None:
        self._stop.set()
        for listener, path in (
            (self._request_listener, self.request_socket_path),
            (self._control_listener, self.control_socket_path),
        ):
            if listener is not None:
                listener.close()
            try:
                if path.is_socket():
                    path.unlink()
            except OSError:
                pass

    def run(self) -> int:
        self.start()
        try:
            while not self._stop.wait(1):
                pass
        except KeyboardInterrupt:
            return 0
        finally:
            self.close()
        return 0


def _proxy_socket(args: argparse.Namespace) -> pathlib.Path:
    if args.socket:
        return socket_path(args.socket, "socket path")
    if not args.consumer:
        _fail("--socket or --consumer is required")
    return socket_path(str(default_request_socket(args.consumer)), "socket path")


def run_proxy(args: argparse.Namespace) -> int:
    path = _proxy_socket(args)
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(path))
    except OSError:
        return 1
    selector = selectors.DefaultSelector()
    selector.register(connection, selectors.EVENT_READ, "socket")
    selector.register(sys.stdin.buffer, selectors.EVENT_READ, "stdin")
    try:
        while selector.get_map():
            for key, _mask in selector.select():
                if key.data == "stdin":
                    chunk = os.read(sys.stdin.fileno(), READ_BUFFER)
                    if not chunk:
                        selector.unregister(sys.stdin.buffer)
                        try:
                            connection.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        continue
                    connection.sendall(chunk)
                else:
                    chunk = connection.recv(READ_BUFFER)
                    if not chunk:
                        return 0
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
    except OSError:
        return 1
    finally:
        selector.close()
        connection.close()
    return 0


def _control_socket(args: argparse.Namespace) -> pathlib.Path:
    value = args.sub_socket or args.socket
    if value:
        return socket_path(value, "control socket path")
    if not args.consumer:
        _fail("--socket or --consumer is required")
    return socket_path(str(default_control_socket(args.consumer)), "control socket path")


def run_control(args: argparse.Namespace) -> int:
    path = _control_socket(args)
    message: dict[str, Any]
    if args.action in {"pending", "list"}:
        message = {"action": "pending"}
    else:
        message = {"action": "approve", "nonce": args.nonce}
        for name in ("approval", "consumer", "tool", "expires_at", "arguments"):
            value = getattr(args, name, None)
            if value is not None:
                message[name] = value
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            connection.sendall(_json_line(message))
            with connection.makefile("rb") as stream:
                response_line = stream.readline(MAX_LINE + 1)
        response = json.loads(response_line.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return 1
    print(json.dumps(response, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0 if isinstance(response, dict) and response.get("ok") is True else 1


def _parse_json_arguments(value: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ConfigError("arguments are not valid JSON") from exc
    if not isinstance(parsed, dict):
        _fail("arguments must be a JSON object")
    return parsed


def _build_parser(mode: str | None) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"agent-secret-{mode or 'broker'}")
    parser.add_argument("--mode", choices=("broker", "proxy", "control"), default=mode)
    if mode in {None, "broker"}:
        parser.add_argument("--policy")
        parser.add_argument("--socket")
        parser.add_argument("--control-socket")
        parser.add_argument("--run-user")
        parser.add_argument("--upstream-home", default="/")
        parser.add_argument("--ensure-socket-parent", action="store_true")
    if mode == "proxy":
        parser.add_argument("--socket")
        parser.add_argument("--consumer")
    if mode == "control":
        parser.add_argument("--socket")
        parser.add_argument("--control-socket", dest="sub_socket")
        parser.add_argument("--consumer")
        subparsers = parser.add_subparsers(dest="action", required=True)
        approve = subparsers.add_parser("approve")
        approve.add_argument("--socket", dest="sub_socket")
        approve.add_argument("--control-socket", dest="sub_socket")
        approve.add_argument("--consumer")
        approve.add_argument("--nonce", required=True)
        approve.add_argument("--approval")
        approve.add_argument("--approval-consumer")
        approve.add_argument("--tool")
        approve.add_argument("--expires-at", type=int)
        approve.add_argument("--arguments", type=_parse_json_arguments)
        pending = subparsers.add_parser("pending")
        pending.add_argument("--socket", dest="sub_socket")
        pending.add_argument("--control-socket", dest="sub_socket")
        pending.add_argument("--consumer")
        listed = subparsers.add_parser("list")
        listed.add_argument("--socket", dest="sub_socket")
        listed.add_argument("--control-socket", dest="sub_socket")
        listed.add_argument("--consumer")
    return parser


def _mode_from_argv0() -> str | None:
    name = pathlib.Path(sys.argv[0]).name
    return {"agent-secret-broker": "broker", "agent-secret-proxy": "proxy", "agent-secretctl": "control"}.get(name)


def _requested_mode(mode: str | None, argv: list[str] | None) -> str | None:
    if mode is not None:
        return mode
    values = sys.argv[1:] if argv is None else argv
    try:
        index = values.index("--mode")
        return values[index + 1]
    except (ValueError, IndexError):
        return mode

def main(argv: list[str] | None = None) -> int:
    mode = _requested_mode(_mode_from_argv0(), argv)
    parser = _build_parser(mode)
    args = parser.parse_args(argv)
    mode = args.mode or mode
    if mode == "broker":
        if not args.policy:
            parser.error("--policy is required")
        policy = load_policy(args.policy)
        request_value = args.socket or str(default_request_socket(policy.consumer))
        control_value = args.control_socket or str(default_control_socket(policy.consumer))
        run_user = _resolve_run_user(args.run_user, policy)
        if args.ensure_socket_parent:
            request_gid = pwd.getpwuid(policy.request_uid).pw_gid
            ensure_socket_parent(request_value, request_gid)
            ensure_socket_parent(control_value, request_gid)
        upstream_home = pathlib.Path(args.upstream_home)
        if not upstream_home.is_absolute() or not upstream_home.is_dir():
            _fail("upstream home must be an existing absolute directory")
        if run_user is not None:
            info = upstream_home.stat()
            if info.st_uid != run_user.pw_uid or info.st_mode & 0o077:
                _fail("upstream home must be private and owned by the service user")
        broker = Broker(
            policy,
            socket_path(request_value, "socket path"),
            socket_path(control_value, "control socket path"),
            run_user,
            upstream_home,
        )
        return broker.run()
    if mode == "proxy":
        return run_proxy(args)
    if mode == "control":
        if getattr(args, "action", None) == "approve" and getattr(args, "approval_consumer", None):
            args.consumer = args.approval_consumer
        return run_control(args)
    parser.error("a mode is required")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ConfigError as exc:
        print(f"agent-secret-broker: {exc}", file=sys.stderr)
        raise SystemExit(2)
