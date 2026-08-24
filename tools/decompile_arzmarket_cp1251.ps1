[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    # Optional local copy of luajit-decompiler-v2.exe.
    [string]$DecompilerPath,

    # Optional LuaJIT path for the compile-only check. When omitted, the script
    # looks for MoonLoader's LuaJIT next to the supplied bytecode file.
    [string]$LuaJitPath
)

$ErrorActionPreference = 'Stop'

$expectedDecompilerSha256 = 'D98FEDF8041DF653904DB28A1DAAF65CE355487307AE49C573AE94491140BB6A'
$decompilerUrl = 'https://github.com/marsinator358/luajit-decompiler-v2/releases/download/Mar_24_2024/luajit-decompiler-v2.exe'

function Get-AbsolutePath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathEquals([string]$Left, [string]$Right) {
    return [string]::Equals(
        (Get-AbsolutePath $Left),
        (Get-AbsolutePath $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

$InputPath = (Resolve-Path -LiteralPath $InputPath).Path

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $inputDirectory = Split-Path -LiteralPath $InputPath -Parent
    $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $OutputPath = Join-Path $inputDirectory ($inputBaseName + '_decompiled_cp1251.lua')
} else {
    $OutputPath = Get-AbsolutePath $OutputPath
}

if (Test-PathEquals $InputPath $OutputPath) {
    throw 'The output must be a different file from the bytecode input.'
}

$outputDirectory = Split-Path -LiteralPath $OutputPath -Parent
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    throw 'Python 3.7 or newer was not found in PATH.'
}
$python = $pythonCommand.Source

if (-not [string]::IsNullOrWhiteSpace($DecompilerPath)) {
    $DecompilerPath = (Resolve-Path -LiteralPath $DecompilerPath).Path
} else {
    $cacheDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'arzmarket-luajit-decompiler-v2'
    $DecompilerPath = Join-Path $cacheDirectory 'luajit-decompiler-v2.exe'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null

    $downloadRequired = -not (Test-Path -LiteralPath $DecompilerPath -PathType Leaf)
    if (-not $downloadRequired) {
        $downloadRequired = (Get-FileHash -LiteralPath $DecompilerPath -Algorithm SHA256).Hash -ne $expectedDecompilerSha256
    }

    if ($downloadRequired) {
        Invoke-WebRequest -Uri $decompilerUrl -OutFile $DecompilerPath
    }

    $actualHash = (Get-FileHash -LiteralPath $DecompilerPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedDecompilerSha256) {
        throw "Invalid decompiler checksum: $actualHash"
    }
}

if ([string]::IsNullOrWhiteSpace($LuaJitPath)) {
    $moonloaderDirectory = Split-Path -LiteralPath $InputPath -Parent
    $candidateLuaJitPath = Join-Path $moonloaderDirectory 'lib\luajit\bin\luajit.exe'
    if (Test-Path -LiteralPath $candidateLuaJitPath -PathType Leaf) {
        $LuaJitPath = $candidateLuaJitPath
    }
} elseif (Test-Path -LiteralPath $LuaJitPath -PathType Leaf) {
    $LuaJitPath = (Resolve-Path -LiteralPath $LuaJitPath).Path
} else {
    throw "LuaJIT executable was not found: $LuaJitPath"
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('arzmarket-decompile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    # Supports LuaJIT 2.0/2.1 chunks, including stripped bytecode.
    & $DecompilerPath $InputPath -o $temporaryDirectory -f -s
    if ($LASTEXITCODE -ne 0) {
        throw "The LuaJIT decompiler failed with exit code $LASTEXITCODE."
    }

    $rawDecompiledPath = Join-Path $temporaryDirectory ([System.IO.Path]::GetFileName($InputPath))
    if (-not (Test-Path -LiteralPath $rawDecompiledPath -PathType Leaf)) {
        throw "Decompiler output was not created: $rawDecompiledPath"
    }

    $candidateOutputPath = Join-Path $temporaryDirectory 'readable_cp1251.lua'

    # This embedded pass only modifies decompiler output. It removes unreachable
    # anti-decompiler blocks, turns binary bytes into Lua escapes, and writes
    # readable Windows-1251 text without changing the runtime byte values.
    $pythonTransform = @'
from pathlib import Path
import re
import sys

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
raw = input_path.read_bytes()
if raw.startswith(b'\xef\xbb\xbf'):
    raw = raw[3:]

field_key = re.compile(rb'(?m)^([ \t]+)([\x80-\xff]+)([ \t]*=)')
def replace_field_key(match):
    key = b''.join(f'\\x{byte:02X}'.encode('ascii') for byte in match.group(2))
    return match.group(1) + b'["' + key + b'"]' + match.group(3)
raw = field_key.sub(replace_field_key, raw)

kept_lines = []
skipping = False
for line in raw.splitlines(keepends=True):
    bare = line.rstrip(b'\r\n')
    if not skipping and bare == b'if false then':
        skipping = True
        continue
    if skipping:
        if bare == b'end':
            skipping = False
        continue
    kept_lines.append(line)
if skipping:
    raise RuntimeError('unclosed top-level if false block')
raw = b''.join(kept_lines)

# Safely preserve PNG/binary data and decompiler artefacts.
raw = b''.join(bytes((byte,)) if byte < 0x80 else f'\\x{byte:02X}'.encode('ascii') for byte in raw)

hex_digits = b'0123456789abcdefABCDEF'
def unescape_lua(value):
    result = bytearray()
    i = 0
    simple = {ord('a'): 7, ord('b'): 8, ord('f'): 12, ord('n'): 10, ord('r'): 13,
              ord('t'): 9, ord('v'): 11, ord('\\'): 92, ord('"'): 34, ord("'"): 39}
    while i < len(value):
        byte = value[i]
        if byte != ord('\\'):
            result.append(byte)
            i += 1
            continue
        i += 1
        if i >= len(value):
            raise ValueError('trailing escape')
        byte = value[i]
        if byte == ord('x') and i + 2 < len(value) and value[i + 1] in hex_digits and value[i + 2] in hex_digits:
            result.append(int(value[i + 1:i + 3], 16))
            i += 3
        elif ord('0') <= byte <= ord('9'):
            end = i
            while end < min(i + 3, len(value)) and ord('0') <= value[end] <= ord('9'):
                end += 1
            result.append(int(value[i:end], 10))
            i = end
        elif byte == ord('z'):
            i += 1
            while i < len(value) and value[i] in b' \t\r\n\v\f':
                i += 1
        elif byte in simple:
            result.append(simple[byte])
            i += 1
        else:
            result.append(byte)
            i += 1
    return bytes(result)

def is_cyrillic(char):
    return '\u0410' <= char <= '\u044f' or char in '\u0401\u0451'

def quote_lua_cp1251(text):
    result = bytearray(b'"')
    for char in text:
        if char == '\\': result += b'\\\\'
        elif char == '"': result += b'\\"'
        elif char == '\n': result += b'\\n'
        elif char == '\r': result += b'\\r'
        elif char == '\t': result += b'\\t'
        elif ord(char) < 32 or ord(char) == 127: result += f'\\x{ord(char):02X}'.encode('ascii')
        else: result += char.encode('cp1251')
    result += b'"'
    return bytes(result)

def readable_cp1251_text(content):
    if not re.search(rb'\\x[89A-Fa-f][0-9A-Fa-f]', content):
        return None
    try:
        text = unescape_lua(content).decode('cp1251')
    except (UnicodeDecodeError, ValueError):
        return None
    if not any(is_cyrillic(char) for char in text):
        return None
    if any(ord(char) < 32 and char not in '\n\r\t' for char in text):
        return None
    return text

# Later script versions may use a different decompiler-generated local name.
# Detect the local that receives require("encoding").UTF8 instead of assuming
# a fixed name such as var_0_5.
utf8_converter = re.search(
    rb'\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*require\(\s*["\']encoding["\']\s*\)\.UTF8\b',
    raw,
)
if utf8_converter:
    converter_name = utf8_converter.group(1)
    u8_call = re.compile(
        rb'(?<![A-Za-z0-9_\.])' + re.escape(converter_name) + rb'\s*\(\s*"((?:\\.|[^"\\\r\n])*)"\s*\)'
    )
    def replace_u8_call(match):
        text = readable_cp1251_text(match.group(1))
        return match.group(0) if text is None else converter_name + b'(' + quote_lua_cp1251(text) + b')'
    raw = u8_call.sub(replace_u8_call, raw)

# Other text literals are consumed as CP1251 by the original script/API.
literal = re.compile(rb'"((?:\\.|[^"\\\r\n])*)"')
def replace_literal(match):
    text = readable_cp1251_text(match.group(1))
    return match.group(0) if text is None else quote_lua_cp1251(text)
raw = literal.sub(replace_literal, raw)

raw = b'-- File encoding: Windows-1251\r\n' + raw
output_path.write_bytes(raw)
'@

    $pythonTransform | & $python - $rawDecompiledPath $candidateOutputPath
    if ($LASTEXITCODE -ne 0) {
        throw "The CP1251 conversion pass failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $candidateOutputPath -PathType Leaf)) {
        throw 'The CP1251 conversion pass did not create an output file.'
    }

    if (-not [string]::IsNullOrWhiteSpace($LuaJitPath)) {
        $LuaJitPath = (Resolve-Path -LiteralPath $LuaJitPath).Path
        $luaPathLiteral = $candidateOutputPath.Replace('\', '/')
        $compileCheck = "local p=[[$luaPathLiteral]]; local h=assert(io.open(p,[[rb]])); local s=h:read([[*a]]); h:close(); local f,e=loadstring(s,[[@]]..p); assert(f,e); assert(#string.dump(f,true)>0); print([[LuaJIT compile-only check passed.]])"
        & $LuaJitPath -e $compileCheck
        if ($LASTEXITCODE -ne 0) {
            throw "LuaJIT rejected the reconstructed source (exit code $LASTEXITCODE)."
        }
    } else {
        Write-Warning 'LuaJIT was not found next to the input file. The file was produced, but not compile-checked.'
    }

    Copy-Item -LiteralPath $candidateOutputPath -Destination $OutputPath -Force
    Write-Host "Done: $OutputPath"
    Write-Host 'Encoding: Windows-1251'
}
finally {
    # This unique directory was created under %TEMP% by this script.
    if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
