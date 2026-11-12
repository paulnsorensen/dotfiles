"""Call approved read tools through the local agent-secret broker."""

from __future__ import annotations

import argparse
import json
import math
import re
import socket
import sys
import time
from typing import Any

MAX_LINE = 1 << 20
ESCAPE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|.)")
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
TOOLS = {
    ("tavily", "search"): ("tavily_search", ("query",)),
    ("tavily", "extract"): ("tavily_extract", ("urls",)),
    ("context7", "library"): ("resolve-library-id", ("libraryName", "query")),
    ("context7", "docs"): ("query-docs", ("libraryId", "query")),
}


class ClientError(Exception):
    """A broker or input failure safe to show to the caller."""


def clean_text(value: str) -> str:
    return CONTROL.sub("", ESCAPE.sub("", value))


def arguments_for(
    provider: str, command: str, values: list[str], extra: str
) -> tuple[str, dict[str, Any]]:
    name, fields = TOOLS[(provider, command)]
    if provider == "tavily" and command == "extract":
        if not values:
            raise ClientError("extract requires at least one URL")
        arguments = {"urls": values}
    else:
        if len(values) != len(fields) or any(not value for value in values):
            raise ClientError(f"{command} requires {len(fields)} non-empty argument(s)")
        arguments = dict(zip(fields, values))
    try:
        additional = json.loads(extra)
    except json.JSONDecodeError as exc:
        raise ClientError("--arguments must be a JSON object") from exc
    if not isinstance(additional, dict):
        raise ClientError("--arguments must be a JSON object")
    if set(additional) & set(arguments):
        raise ClientError("--arguments cannot replace positional fields")
    arguments.update(additional)
    return name, arguments


# macOS Python 3.9 keeps socket.timeout separate from TimeoutError.
def send(connection: socket.socket, message: dict[str, Any], deadline: float) -> None:
    payload = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
    if len(payload) > MAX_LINE:
        raise ClientError("request is too large")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ClientError("broker timed out")
    connection.settimeout(remaining)
    try:
        connection.sendall(payload)
    except (TimeoutError, socket.timeout) as exc:  # noqa: UP041
        raise ClientError("broker timed out") from exc
    except OSError as exc:
        raise ClientError("broker disconnected") from exc


def response(
    connection: socket.socket, request_id: int, deadline: float, buffer: bytes
) -> tuple[Any, bytes]:
    while True:
        while b"\n" not in buffer:
            if len(buffer) > MAX_LINE:
                raise ClientError("broker response is too large")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ClientError("broker timed out")
            connection.settimeout(remaining)
            try:
                chunk = connection.recv(65536)
            except (TimeoutError, socket.timeout) as exc:  # noqa: UP041
                raise ClientError("broker timed out") from exc
            except OSError as exc:
                raise ClientError("broker disconnected") from exc
            if not chunk:
                raise ClientError("broker disconnected")
            buffer += chunk
        line, buffer = buffer.split(b"\n", 1)
        if len(line) > MAX_LINE:
            raise ClientError("broker response is too large")
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ClientError("malformed broker response") from exc
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise ClientError("malformed broker response")
        if "id" not in message:
            if not isinstance(message.get("method"), str):
                raise ClientError("malformed broker response")
            continue
        if message["id"] != request_id:
            raise ClientError("unexpected broker response ID")
        if "error" in message:
            error = message["error"]
            if not isinstance(error, dict):
                raise ClientError("malformed broker response")
            detail = error.get("message")
            raise ClientError(
                clean_text(detail) if isinstance(detail, str) else "broker RPC error"
            )
        if "result" not in message or "error" in message:
            raise ClientError("malformed broker response")
        return message["result"], buffer


def result_text(result: dict[str, Any]) -> str:
    content = result.get("content")
    if isinstance(content, list):
        parts = [
            clean_text(item["text"])
            for item in content
            if isinstance(item, dict) and isinstance(item.get("text"), str)
        ]
        if parts:
            return "\n".join(parts)
    if "structuredContent" in result:
        return json.dumps(result["structuredContent"])
    raise ClientError("tool returned no printable result")


def parser_for(provider: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tvly-broker" if provider == "tavily" else "ctx7-broker"
    )
    parser.add_argument(
        "--socket", default=f"/var/run/dotfiles-agent-secrets/{provider}.sock"
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--arguments", default="{}")
    commands = parser.add_subparsers(dest="command", required=True)
    if provider == "tavily":
        commands.add_parser("search").add_argument("values", nargs=1, metavar="QUERY")
        commands.add_parser("extract").add_argument("values", nargs="+", metavar="URL")
    else:
        library = commands.add_parser("library")
        library.add_argument("library", metavar="LIBRARY_NAME")
        library.add_argument("query", metavar="QUERY")
        docs = commands.add_parser("docs")
        docs.add_argument("library", metavar="LIBRARY_ID")
        docs.add_argument("query", metavar="QUERY")
    return parser


def run() -> int:
    bootstrap = argparse.ArgumentParser(add_help=False)
    bootstrap.add_argument("--provider", required=True, choices=("tavily", "context7"))
    known, remaining = bootstrap.parse_known_args()
    args = parser_for(known.provider).parse_args(remaining)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise ClientError("--timeout must be positive and finite")
    if not args.socket or "\x00" in args.socket:
        raise ClientError("--socket must be a socket path")
    values = args.values if known.provider == "tavily" else [args.library, args.query]
    name, arguments = arguments_for(
        known.provider, args.command, values, args.arguments
    )
    deadline = time.monotonic() + args.timeout
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(args.timeout)
        connection.connect(args.socket)
    except (TimeoutError, socket.timeout) as exc:  # noqa: UP041
        raise ClientError("broker timed out") from exc
    except OSError as exc:
        raise ClientError(
            f"broker unavailable at {args.socket}; check the agent-secret service"
        ) from exc
    try:
        buffer = b""
        send(
            connection,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "agent-secret-client", "version": "1"},
                },
            },
            deadline,
        )
        initialized, buffer = response(connection, 1, deadline, buffer)
        if not isinstance(initialized, dict) or not isinstance(
            initialized.get("protocolVersion"), str
        ):
            raise ClientError("malformed initialize response")
        send(
            connection,
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            deadline,
        )
        send(
            connection,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            },
            deadline,
        )
        result, _ = response(connection, 2, deadline, buffer)
    finally:
        connection.close()
    if not isinstance(result, dict):
        raise ClientError("malformed tool result")
    if result.get("isError"):
        raise ClientError("tool returned an error")
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(result_text(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except ClientError as exc:
        print(f"agent-secret-client: {clean_text(str(exc))}", file=sys.stderr)
        sys.exit(1)
