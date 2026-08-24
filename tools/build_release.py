#!/usr/bin/env python3
"""Prepare a manual ArzMarket fork release from a reviewed Lua source file.

This tool changes only two safe, deterministic client values in a copy:
  1. the updater manifest URL;
  2. the script's displayed version.

It does not add bridges, copy credentials, alter marketplace authentication, or
publish anything to GitHub.  Publishing remains a deliberate git commit/push.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
OFFICIAL_MANIFEST = b"https://raw.githubusercontent.com/FREYM1337/forumnick/main/ArzMarketV3/updateArzMarket.js"
VERSION_PATTERN = re.compile(rb'(scriptVersion\s*=\s*\{\s*\r?\n\s*)"[^"]+"')
DIRECT_UPDATE_BLOCK = (
    b"\t\tif var_0_115.autoUpdateCheck[2] then\r\n"
    b"\t\t\tvar_0_115.autoUpdateCheck[2] = false\r\n\r\n"
    b"\t\t\tautoUpdateCheckUrl()\r\n"
    b"\t\tend"
)


def load_config(path: Path) -> dict:
    config = json.loads(path.read_text(encoding="utf-8"))
    for field in ("manifest_url", "release_url", "items_update"):
        if field not in config:
            raise RuntimeError(f"Missing '{field}' in {path}")
    for field in ("manifest_url", "release_url"):
        parsed = urlparse(config[field])
        if parsed.scheme != "https" or not parsed.hostname:
            raise RuntimeError(f"'{field}' must be an absolute HTTPS URL")
        if "YOUR_GITHUB_LOGIN" in config[field] or "YOUR_REPOSITORY" in config[field]:
            raise RuntimeError("Replace the placeholders in config/fork.json before building a release")
    return config


def patch_source(data: bytes, manifest_url: str, version: str) -> bytes:
    encoded_manifest = manifest_url.encode("ascii")
    occurrences = data.count(OFFICIAL_MANIFEST)
    if occurrences != 1:
        raise RuntimeError(f"Expected exactly one official manifest URL, found {occurrences}. Review the upstream update code first.")
    output = data.replace(OFFICIAL_MANIFEST, encoded_manifest, 1)
    version_bytes = version.encode("ascii")
    output, replacements = VERSION_PATTERN.subn(lambda m: m.group(1) + b'"' + version_bytes + b'"', output, count=1)
    if replacements != 1:
        raise RuntimeError("Could not locate the scriptVersion literal. Review the source before releasing it.")
    direct_updates = output.count(DIRECT_UPDATE_BLOCK)
    if direct_updates != 1:
        raise RuntimeError(
            f"Expected exactly one built-in direct-update block, found {direct_updates}. "
            "Review the source before releasing it."
        )
    output = output.replace(
        DIRECT_UPDATE_BLOCK,
        b"\t\tif var_0_115.autoUpdateCheck[2] then\r\n"
        b"\t\t\tvar_0_115.autoUpdateCheck[2] = false\r\n"
        b"\t\t\t-- Updates are handled by PirojkiSPovidlom_Loader.lua.\r\n"
        b"\t\tend",
        1,
    )
    return output


def luajit_check(luajit: Path, lua_file: Path) -> None:
    lua_path = str(lua_file.resolve()).replace("\\", "/")
    command = f"local p=[[{lua_path}]]; local h=assert(io.open(p,[[rb]])); local s=h:read([[*a]]); h:close(); assert(loadstring(s,[[=@]]..p)); print([[LuaJIT syntax check passed.]])"
    subprocess.run([str(luajit), "-e", command], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Reviewed CP1251 Lua source")
    parser.add_argument("--version", required=True, help="Fork version, e.g. 3.56-fork.1")
    parser.add_argument("--config", type=Path, default=ROOT / "config" / "fork.json")
    parser.add_argument("--output", type=Path, default=ROOT / "release")
    parser.add_argument("--luajit", type=Path, help="Optional luajit.exe for a compile-only syntax check")
    arguments = parser.parse_args()

    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]{0,63}", arguments.version):
        raise RuntimeError("Version may contain only letters, digits, dot, underscore, and hyphen")
    source = arguments.source.resolve()
    if not source.is_file():
        raise RuntimeError(f"Source file not found: {source}")
    config = load_config(arguments.config.resolve())
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    release_lua = output / "ArzMarket.lua"
    release_data = patch_source(source.read_bytes(), config["manifest_url"], arguments.version)
    release_lua.write_bytes(release_data)

    manifest = {
        "updateurl": config["release_url"],
        "latest": arguments.version,
        "itemsUpdate": int(config["items_update"]),
        "sha256": hashlib.sha256(release_data).hexdigest(),
        "channel": "manual-review",
        "loaderLatest": "1.0.1",
        "loaderUpdateUrl": "https://raw.githubusercontent.com/f3rkomen/PirojkiSPovidlom/main/release/PirojkiSPovidlom_Loader.lua"
    }
    manifest_path = output / "updateArzMarket.js"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if arguments.luajit:
        luajit = arguments.luajit.resolve()
        if not luajit.is_file():
            raise RuntimeError(f"LuaJIT was not found: {luajit}")
        luajit_check(luajit, release_lua)

    print(f"Release prepared: {release_lua}")
    print(f"Manifest prepared: {manifest_path}")
    print(f"SHA-256: {manifest['sha256']}")
    print("Nothing was uploaded. Inspect the two files, then commit and push them manually.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
