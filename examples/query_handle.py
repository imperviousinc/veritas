#!/usr/bin/env python3
"""Query a fabric handle (default: subspace@space) from certrelay."""

from __future__ import annotations

import json
import os
import random
import sys
import urllib.error
import urllib.parse
import urllib.request

HANDLE = sys.argv[1] if len(sys.argv) > 1 else "subspace@space"
DEFAULT_RELAYS = (
    "https://relay-cosmos.spacesprotocol.org",
    "https://relay-atlas.spacesprotocol.org",
    "https://relay-orion.spacesprotocol.org",
    "https://relay-pulsar.spacesprotocol.org",
)
EXCLUDE_CERTRELAY_URL = os.environ.get(
    "EXCLUDE_CERTRELAY_URL", "http://70.251.209.207:47778"
)


def fabric_q(handle: str) -> str:
    if "@" not in handle or handle.startswith("@"):
        sys.exit("usage: query_handle.py <label@space>     e.g. subspace@space")
    space = "@" + handle.rsplit("@", 1)[-1]
    return f"{space},{handle}"


def relay_key(url: str) -> str:
    parsed = urllib.parse.urlparse(url.strip())
    host = (parsed.hostname or "").lower()
    if parsed.port:
        return f"{host}:{parsed.port}"
    netloc = parsed.netloc.lower()
    return netloc.split("@")[-1]


def excluded_keys() -> set[str]:
    return {
        relay_key(part)
        for part in EXCLUDE_CERTRELAY_URL.split(",")
        if part.strip()
    }


def is_excluded(url: str, blocked: set[str]) -> bool:
    key = relay_key(url)
    return bool(key) and key in blocked


def discover_relays(seeds: list[str], blocked: set[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()

    def add(url: str) -> None:
        url = url.strip().rstrip("/")
        key = relay_key(url)
        if not key or key in seen:
            return
        if is_excluded(url, blocked):
            if key not in seen:
                print(f"skip excluded relay {url}")
                seen.add(key)
            return
        seen.add(key)
        ordered.append(url)

    for seed in seeds:
        add(seed)

    for seed in list(ordered):
        req = urllib.request.Request(
            f"{seed}/peers", headers={"User-Agent": "veritas-examples"}
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, TimeoutError):
            continue
        peers = data if isinstance(data, list) else data.get("peers") or data.get("relays") or []
        for peer in peers:
            url = peer.get("url") if isinstance(peer, dict) else peer
            if url:
                add(str(url))

    return ordered


def main() -> None:
    q = fabric_q(HANDLE)
    blocked = excluded_keys()
    seeds = [os.environ["CERTRELAY_URL"]] if os.environ.get("CERTRELAY_URL") else list(DEFAULT_RELAYS)
    relays = discover_relays(seeds, blocked)
    if not relays:
        sys.exit(f"No relays left after EXCLUDE_CERTRELAY_URL={EXCLUDE_CERTRELAY_URL}")
    random.shuffle(relays)

    last_error = "no relays"
    for relay in relays:
        url = f"{relay}/query?{urllib.parse.urlencode({'q': q})}"
        print(f"GET {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "veritas-examples"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
                print(f"HTTP {resp.status}  {len(body)} bytes")
                if resp.status == 200 and body:
                    print("To decode this proof and print the handle:")
                    print(f"  cargo run --example resolve_handle -- {HANDLE}")
                    return
        except urllib.error.HTTPError as e:
            last_error = f"HTTP {e.code}: {e.read().decode(errors='replace') or '(empty body)'}"
            print(last_error)
        except urllib.error.URLError as e:
            last_error = f"request failed: {e.reason}"
            print(last_error)

    sys.exit(f"No relay returned a proof for {HANDLE} ({last_error})")


if __name__ == "__main__":
    main()
