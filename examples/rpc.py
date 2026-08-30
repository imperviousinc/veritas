#!/usr/bin/env python3
"""Call the embedded spaced JSON-RPC (Veritas mainnet)."""

from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.error
import urllib.request

RPC_URL = "http://127.0.0.1:12888"
RPC_USER = "436813c5b4dc2c63"
RPC_PASSWORD = "19a87f2055b28a5054635ac6baaa40fc"


def as_space(name: str) -> str:
    """getspace wants '@lunde', not a handle like 'andrew@lunde'."""
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
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode(errors='replace')}")
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
        ("getspace", "name", "space name, e.g. @lunde"),
        ("getspaceowner", "name", "space name, e.g. @lunde"),
        ("getnum", "subject", "num subject, e.g. #1-2-3"),
        ("getcommitment", "subject", "@space, #numeric, or num1..."),
        ("getdelegation", "subject", "@space, #numeric, or num1..."),
        ("getfallback", "subject", "@space, #numeric, or num1..."),
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
        value = getattr(args, "name", None) or getattr(args, "subject")
        if cmd in ("getspace", "getspaceowner"):
            value = as_space(value)
        result = call(cmd, [value])

    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
