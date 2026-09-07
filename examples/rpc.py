#!/usr/bin/env python3
"""Call the embedded spaced JSON-RPC (Veritas mainnet)."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file(Path(__file__).resolve().parent / "rpc.env")

RPC_URL = os.environ.get("SPACED_RPC_URL", "http://127.0.0.1:12888")
RPC_USER = os.environ.get("SPACED_RPC_USER", "")
RPC_PASSWORD = os.environ.get("SPACED_RPC_PASSWORD", "")
if not RPC_USER or not RPC_PASSWORD:
    sys.exit(
        "Set SPACED_RPC_USER and SPACED_RPC_PASSWORD (they change each Veritas start).\n"
        "Copy them from Settings → RPC Credentials, then either:\n"
        "  export SPACED_RPC_USER=... SPACED_RPC_PASSWORD=...\n"
        "  or write them to examples/rpc.env (see rpc.env.example)"
    )


def as_space(name: str) -> str:
    """getspace wants '@space', not a handle like 'subspace@space'."""
    if "@" in name and not name.startswith("@"):
        space = "@" + name.rsplit("@", 1)[-1]
        print(
            f"note: getspace takes a space, not a handle; using {space} (from {name})",
            file=sys.stderr,
        )
        return space
    return name


def call(method: str, params: list | None = None) -> object:
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    ).encode()
    token = base64.b64encode(f"{RPC_USER}:{RPC_PASSWORD}".encode()).decode()
    req = urllib.request.Request(
        RPC_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Basic {token}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        extra = ""
        if e.code == 401:
            extra = (
                "\nRPC credentials are stale. Copy the current pair from "
                "Settings → RPC Credentials, then update SPACED_RPC_USER / "
                "SPACED_RPC_PASSWORD or examples/rpc.env."
            )
        sys.exit(f"HTTP {e.code}: {body}{extra}")
    except urllib.error.URLError as e:
        sys.exit(f"Could not reach {RPC_URL} ({e.reason}). Is Veritas running?")

    if payload.get("error"):
        sys.exit(json.dumps(payload["error"], indent=2))
    return payload.get("result")


def main() -> None:
    p = argparse.ArgumentParser(description="spaced JSON-RPC helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("getserverinfo")
    sub.add_parser("getrootanchors")
    sub.add_parser("discover")

    for name, arg, help_text in [
        ("getspace", "name", "space name, e.g. @space"),
        ("getspaceowner", "name", "space name, e.g. @space"),
        ("getnum", "subject", "num subject, e.g. #1-2-3"),
        ("getcommitment", "subject", "@space, #numeric, or num1..."),
        ("getdelegation", "subject", "@space, #numeric, or num1..."),
        ("getfallback", "subject", "@space, #numeric, or num1..."),
        ("queryhandle", "handle", "fabric handle (subspace@space) or space (@space)"),
    ]:
        sp = sub.add_parser(name)
        sp.add_argument(arg, help=help_text)

    raw = sub.add_parser("raw")
    raw.add_argument("method")
    raw.add_argument("params", nargs="?", default="[]", help="JSON array of params")

    args = p.parse_args()
    cmd = args.cmd

    if cmd == "getserverinfo":
        result = call("getserverinfo")
    elif cmd == "getrootanchors":
        result = call("getrootanchors")
    elif cmd == "discover":
        result = call("rpc.discover")
    elif cmd == "getcommitment":
        result = call("getcommitment", [args.subject, None])
    elif cmd == "raw":
        result = call(args.method, json.loads(args.params))
    else:
        value = getattr(args, "name", None) or getattr(args, "subject", None) or getattr(args, "handle", None)
        if cmd in ("getspace", "getspaceowner"):
            value = as_space(value)
        result = call(cmd, [value])

    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
