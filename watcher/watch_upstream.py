#!/usr/bin/env python3
"""Stage, but never publish or execute, a new upstream ArzMarket release.

The script downloads only the official update manifest and the candidate file it
names.  It does not run, unpack, decompile, patch, or publish downloaded data.
That review boundary is intentional: a client release is created separately
with tools/build_release.py after a human has inspected the candidate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent


def timestamp() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in {path}: {exc}") from exc


def atomic_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def fetch(url: str, timeout: int = 25) -> tuple[bytes, dict[str, str]]:
    request = urllib.request.Request(url, headers={"User-Agent": "ArzMarket-Fork-Upstream-Watcher/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(), dict(response.headers.items())


def require_https_url(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"Manifest field '{field}' must be a non-empty string")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname:
        raise RuntimeError(f"Manifest field '{field}' must be an absolute HTTPS URL")
    return value


def validate_update_url(url: str, config: dict[str, Any]) -> None:
    parsed = urlparse(url)
    hosts = set(config["allowed_update_hosts"])
    prefixes = tuple(config["allowed_update_path_prefixes"])
    if parsed.hostname not in hosts:
        raise RuntimeError(f"Candidate host is not allow-listed: {parsed.hostname}")
    if not parsed.path.startswith(prefixes):
        raise RuntimeError(f"Candidate path is not allow-listed: {parsed.path}")


def validate_manifest(data: object, config: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise RuntimeError("Upstream manifest must be a JSON object")
    update_url = require_https_url(data.get("updateurl"), "updateurl")
    latest = data.get("latest")
    if not isinstance(latest, (str, int, float)) or not str(latest).strip():
        raise RuntimeError("Manifest field 'latest' is missing")
    validate_update_url(update_url, config)
    return {"latest": str(latest), "updateurl": update_url, "itemsUpdate": data.get("itemsUpdate")}


def stage_candidate(config: dict[str, Any], state: dict[str, Any]) -> bool:
    manifest_url = require_https_url(config["upstream_manifest_url"], "upstream_manifest_url")
    raw_manifest, _headers = fetch(manifest_url)
    try:
        manifest = validate_manifest(json.loads(raw_manifest.decode("utf-8")), config)
    except UnicodeDecodeError as exc:
        raise RuntimeError("Upstream manifest is not UTF-8") from exc

    candidate_id = hashlib.sha256(
        f"{manifest['latest']}\n{manifest['updateurl']}".encode("utf-8")
    ).hexdigest()
    if state.get("last_candidate_id") == candidate_id:
        print(f"[{timestamp()}] Upstream unchanged: {manifest['latest']}")
        return False

    payload, headers = fetch(manifest["updateurl"])
    if not payload:
        raise RuntimeError("Upstream candidate is empty")

    staging_root = (ROOT / config["staging_directory"]).resolve()
    destination = staging_root / manifest["latest"]
    destination.mkdir(parents=True, exist_ok=True)
    candidate_path = destination / "ArzMarket-upstream.lua"
    candidate_path.write_bytes(payload)

    metadata = {
        "fetched_at": timestamp(),
        "upstream_manifest_url": manifest_url,
        "latest": manifest["latest"],
        "updateurl": manifest["updateurl"],
        "itemsUpdate": manifest["itemsUpdate"],
        "sha256": hashlib.sha256(payload).hexdigest(),
        "content_length": len(payload),
        "content_type": headers.get("Content-Type", ""),
        "status": "review-required"
    }
    atomic_json(destination / "metadata.json", metadata)
    atomic_json(ROOT / config["state_file"], {
        "last_candidate_id": candidate_id,
        "last_seen_at": timestamp(),
        "latest": manifest["latest"],
        "sha256": metadata["sha256"]
    })
    print(f"[{timestamp()}] Staged upstream {manifest['latest']} ({len(payload)} bytes). Review required: {destination}")
    return True


def run_once(config_path: Path) -> int:
    config = read_json(config_path, None)
    if not isinstance(config, dict):
        raise RuntimeError(f"Config must be a JSON object: {config_path}")
    required = ("upstream_manifest_url", "staging_directory", "state_file", "allowed_update_hosts", "allowed_update_path_prefixes")
    missing = [field for field in required if field not in config]
    if missing:
        raise RuntimeError("Missing config fields: " + ", ".join(missing))
    if not isinstance(config["allowed_update_hosts"], list) or not isinstance(config["allowed_update_path_prefixes"], list):
        raise RuntimeError("Allow-list fields must be JSON arrays")
    state = read_json(ROOT / config["state_file"], {})
    if not isinstance(state, dict):
        raise RuntimeError("Watcher state must be a JSON object")
    stage_candidate(config, state)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "watcher-config.json")
    parser.add_argument("--once", action="store_true", help="Check once (for systemd timer/Task Scheduler)")
    arguments = parser.parse_args()
    config_path = arguments.config.resolve()

    while True:
        try:
            run_once(config_path)
        except (OSError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
            print(f"[{timestamp()}] ERROR: {exc}", file=sys.stderr)
            if arguments.once:
                return 1

        if arguments.once:
            return 0
        config = read_json(config_path, {})
        delay = int(config.get("poll_seconds", 600))
        time.sleep(max(delay, 60))


if __name__ == "__main__":
    raise SystemExit(main())
