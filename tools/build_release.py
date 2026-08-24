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
FORK_DIRECT_UPDATE_BLOCK = (
    b"\t\tif var_0_115.autoUpdateCheck[2] then\r\n"
    b"\t\t\tvar_0_115.autoUpdateCheck[2] = false\r\n"
    b"\t\t\t-- Updates are handled by ArzMarket_Loader.lua.\r\n"
    b"\t\tend"
)
LEGACY_FORK_DIRECT_UPDATE_BLOCK = (
    b"\t\tif var_0_115.autoUpdateCheck[2] then\r\n"
    b"\t\t\tvar_0_115.autoUpdateCheck[2] = false\r\n"
    b"\t\t\t-- Updates are handled by PirojkiSPovidlom_Loader.lua.\r\n"
    b"\t\tend"
)
FORK_REINSTALL_MARKER = b"-- PirojkiSPovidlom trusted reinstall control"
FORK_REINSTALL_HELPER_TEMPLATE = (
    b"-- PirojkiSPovidlom trusted reinstall control\n"
    b"local function pirojki_request_market_reinstall()\n"
    b"\tlocal pirojki_loader_directory = getWorkingDirectory() .. \"\\\\ArzMarketLoader\"\n"
    b"\n"
    b"\tif not doesDirectoryExist(pirojki_loader_directory) then\n"
    b"\t\tcreateDirectory(pirojki_loader_directory)\n"
    b"\tend\n"
    b"\n"
    b"\tlocal pirojki_request = io.open(pirojki_loader_directory .. \"\\\\force-reinstall.request\", \"wb\")\n"
    b"\n"
    b"\tif not pirojki_request then\n"
    b"\t\tAFKMessage(\"Fork: could not queue the GitHub reinstall.\")\n"
    b"\t\treturn\n"
    b"\tend\n"
    b"\n"
    b"\tpirojki_request:write(tostring(os.time()))\n"
    b"\tpirojki_request:close()\n"
    b"\tAFKMessage(\"Fork: GitHub reinstall queued.\")\n"
    b"end\n"
    b"\n"
)
FORK_REINSTALL_BUTTON_TEMPLATE = (
    b"\tvar_0_1.GetStyle().FrameBorderSize = var_0_139[0] and 1 or 0\n"
    b"\n"
    b"\tif var_0_1.Button(var_0_5(\"\\xCF\\xE5\\xF0\\xE5\\xE7\\xE0\\xE3\\xF0\\xF3\\xE7\\xE8\\xF2\\xFC Market \\xF1 GitHub\") .. \"##PirojkiForceReinstall\", var_0_1.ImVec2(var_0_1.GetWindowWidth(), 27)) then\n"
    b"\t\tpirojki_request_market_reinstall()\n"
    b"\tend\n"
    b"\n"
    b"\tvar_0_1.GetStyle().FrameBorderSize = 0\n"
    b"\n"
)
UNSAFE_PUBLIC_MARKERS = (
    b"AMBridge",
    b"marketplaceBridge",
    b"marketplace_bridge.json",
    b"marketplace_data.json",
    b"sharedAuth",
)


def load_config(path: Path) -> dict:
    config = json.loads(path.read_text(encoding="utf-8"))
    for field in ("manifest_url", "release_url", "items_update", "loader_latest", "loader_url"):
        if field not in config:
            raise RuntimeError(f"Missing '{field}' in {path}")
    for field in ("manifest_url", "release_url", "loader_url"):
        parsed = urlparse(config[field])
        if parsed.scheme != "https" or not parsed.hostname:
            raise RuntimeError(f"'{field}' must be an absolute HTTPS URL")
        if "YOUR_GITHUB_LOGIN" in config[field] or "YOUR_REPOSITORY" in config[field]:
            raise RuntimeError("Replace the placeholders in config/fork.json before building a release")
    return config


def replace_unique_block(data: bytes, expected: bytes, replacement: bytes, description: str) -> bytes:
    occurrences = data.count(expected)
    if occurrences != 1:
        raise RuntimeError(f"Expected exactly one {description}, found {occurrences}. Review the source before releasing it.")
    return data.replace(expected, replacement, 1)


def source_line_ending(data: bytes) -> bytes:
    return b"\r\n" if b"\r\nfunction cfg_menu(arg_194_0)" in data else b"\n"


def with_line_ending(template: bytes, line_ending: bytes) -> bytes:
    return template.replace(b"\r\n", b"\n").replace(b"\n", line_ending)


def reject_unsafe_public_code(data: bytes) -> None:
    found = [marker.decode("ascii") for marker in UNSAFE_PUBLIC_MARKERS if marker in data]
    if found:
        raise RuntimeError(
            "Refusing to prepare a public release containing private bridge/auth-transfer code: "
            + ", ".join(found)
        )


def inject_reinstall_control(data: bytes) -> bytes:
    marker_count = data.count(FORK_REINSTALL_MARKER)
    if marker_count > 1:
        raise RuntimeError("Fork reinstall control marker is duplicated")

    line_ending = source_line_ending(data)
    helper_marker = b"function cfg_menu(arg_194_0)" + line_ending
    button_marker = b"\tvar_0_1.PushItemWidth(150)" + line_ending
    helper = with_line_ending(FORK_REINSTALL_HELPER_TEMPLATE, line_ending)
    button = with_line_ending(FORK_REINSTALL_BUTTON_TEMPLATE, line_ending)
    if marker_count == 1:
        helper_start = data.index(FORK_REINSTALL_MARKER)
        helper_end = data.index(helper_marker, helper_start)
        data = data[:helper_start] + helper + data[helper_end:]
        button_start = data.index(button_marker, helper_end) + len(button_marker)
        next_setting_marker = b"\tif var_0_1.ToggleButton("
        button_end = data.index(next_setting_marker, button_start)
        return data[:button_start] + button + data[button_end:]
    data = replace_unique_block(data, helper_marker, helper + helper_marker, "cfg_menu declaration")
    return replace_unique_block(data, button_marker, button_marker + button, "cfg_menu item-width marker")


def patch_source(data: bytes, manifest_url: str, version: str, allow_existing_fork: bool = False) -> bytes:
    reject_unsafe_public_code(data)
    encoded_manifest = manifest_url.encode("ascii")
    occurrences = data.count(OFFICIAL_MANIFEST)
    if occurrences == 1:
        output = data.replace(OFFICIAL_MANIFEST, encoded_manifest, 1)
    elif allow_existing_fork and data.count(encoded_manifest) == 1:
        output = data
    else:
        raise RuntimeError(f"Expected exactly one official manifest URL, found {occurrences}. Review the upstream update code first.")
    version_bytes = version.encode("ascii")
    output, replacements = VERSION_PATTERN.subn(lambda m: m.group(1) + b'"' + version_bytes + b'"', output, count=1)
    if replacements != 1:
        raise RuntimeError("Could not locate the scriptVersion literal. Review the source before releasing it.")
    line_ending = source_line_ending(output)
    direct_update_block = with_line_ending(DIRECT_UPDATE_BLOCK, line_ending)
    fork_direct_update_block = with_line_ending(FORK_DIRECT_UPDATE_BLOCK, line_ending)
    legacy_fork_direct_update_block = with_line_ending(LEGACY_FORK_DIRECT_UPDATE_BLOCK, line_ending)
    if output.count(direct_update_block) == 1:
        output = output.replace(direct_update_block, fork_direct_update_block, 1)
    elif allow_existing_fork and output.count(legacy_fork_direct_update_block) == 1:
        output = output.replace(legacy_fork_direct_update_block, fork_direct_update_block, 1)
    elif not (allow_existing_fork and output.count(fork_direct_update_block) == 1):
        raise RuntimeError("Could not locate the built-in direct-update block. Review the source before releasing it.")
    output = inject_reinstall_control(output)
    reject_unsafe_public_code(output)
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
    parser.add_argument(
        "--refresh-existing",
        action="store_true",
        help="Refresh a reviewed fork release without changing its upstream version",
    )
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
    release_data = patch_source(
        source.read_bytes(),
        config["manifest_url"],
        arguments.version,
        allow_existing_fork=arguments.refresh_existing,
    )
    release_lua.write_bytes(release_data)

    loader_path = output / "ArzMarket_Loader.lua"
    if not loader_path.is_file():
        raise RuntimeError(f"Required loader file was not found: {loader_path}")

    manifest = {
        "updateurl": config["release_url"],
        "latest": arguments.version,
        "itemsUpdate": int(config["items_update"]),
        "sha256": hashlib.sha256(release_data).hexdigest(),
        "channel": "manual-review",
        "loaderLatest": config["loader_latest"],
        "loaderUpdateUrl": config["loader_url"],
        "loaderSha256": hashlib.sha256(loader_path.read_bytes()).hexdigest(),
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
