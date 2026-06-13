#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────
#  Let's LLM Installer
#
#  Downloads Claude Code from npm, applies patches, replaces claude command
#
#  用法:
#    curl -fsSL https://raw.githubusercontent.com/syntharea/llmgod/main/install.sh | bash
#    # 或
#    bash install.sh [--version 2.1.89]
# ─────────────────────────────────────────────────────────

LLMGOD_DIR="$HOME/.llmgod"
BIN_DIR="$HOME/.local/bin"
VERSION="${LLMGOD_VERSION:-latest}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) VERSION="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) shift ;;
  esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${RED}✗${NC} $1"; }
dim()   { echo -e "  ${DIM}$1${NC}"; }

echo ""
echo -e "${BOLD}  Let's LLM Installer${NC}"
echo ""

# ─── Uninstall ─────────────────────────────────────────

if [ "$UNINSTALL" = "1" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  for DIR in "${CLAUDE_BIN:+$(dirname "$CLAUDE_BIN")}" "$BIN_DIR"; do
    [ -z "$DIR" ] && continue
    if [ -e "$DIR/claude.orig" ]; then
      # Has backup — restore it
      mv "$DIR/claude.orig" "$DIR/claude"
      info "Original claude restored ($DIR/claude)"
    elif [ -f "$DIR/claude" ] && grep -q "llmgod" "$DIR/claude" 2>/dev/null; then
      # Our launcher, no backup — remove it (otherwise it points to deleted cli.js)
      rm -f "$DIR/claude"
      info "Removed Let's LLM launcher ($DIR/claude)"
    fi
    # Always remove the explicit llmgod alias if it's ours
    if [ -f "$DIR/llmgod" ] && grep -q "llmgod" "$DIR/llmgod" 2>/dev/null; then
      rm -f "$DIR/llmgod"
      info "Removed Let's LLM alias ($DIR/llmgod)"
    fi
  done
  rm -rf "$LLMGOD_DIR/node_modules" "$LLMGOD_DIR/vendor" "$LLMGOD_DIR/bun-runtime" "$LLMGOD_DIR/cli.original.js" "$LLMGOD_DIR/cli.original.js.bak" "$LLMGOD_DIR/cli.original.cjs" "$LLMGOD_DIR/cli.original.cjs.bak" "$LLMGOD_DIR/cli.js" "$LLMGOD_DIR/cli.cjs" "$LLMGOD_DIR/patch.mjs" "$LLMGOD_DIR/patch.js" "$LLMGOD_DIR/extract-natives.mjs" "$LLMGOD_DIR/post-process.mjs" "$LLMGOD_DIR/repatch.mjs" "$LLMGOD_DIR/.source-version"
  hash -r 2>/dev/null
  info "Let's LLM uninstalled"
  echo ""
  warn "  Restart your terminal or run: hash -r"
  echo ""
  exit 0
fi

# ─── Prerequisites ─────────────────────────────────────

if ! command -v node &>/dev/null; then
  warn "Node.js is required (>= 18) for the patcher. Install from https://nodejs.org"
  exit 1
fi

NODE_VERSION=$(node -e "console.log(process.versions.node.split('.')[0])")
if [ "$NODE_VERSION" -lt 18 ]; then
  warn "Node.js >= 18 required (found v$NODE_VERSION)"
  exit 1
fi

# ─── Ensure Bun (runtime that executes the patched cli.js) ─────────────

BUN_BIN=""
if command -v bun &>/dev/null; then
  BUN_BIN=$(command -v bun)
elif [ -x "$HOME/.bun/bin/bun" ]; then
  BUN_BIN="$HOME/.bun/bin/bun"
else
  dim "Installing Bun (required runtime for v2.1.113+ cli.js) ..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
  BUN_BIN="$HOME/.bun/bin/bun"
  if [ ! -x "$BUN_BIN" ]; then
    warn "Bun installation failed. Install manually: https://bun.sh/install"
    exit 1
  fi
fi
info "Bun: $($BUN_BIN --version)"

# ─── Bun version pre-flight ───────────────────────────────────────────
# Anthropic builds the native binary with Bun's canary channel; stable
# bun.sh trails by one version. Bun < 1.3.14 panics on cli.original.cjs
# with "Expected CommonJS module to have a function wrapper". Refuse
# early — no npm download / no patch / no late sanity surprise.
# Bump MIN_BUN_VERSION when Anthropic moves the embedded Bun forward
# again (track via 'bun upgrade --canary' on a runner + smoke test).

MIN_BUN_VERSION="1.3.14"
BUN_VERSION_RAW=$($BUN_BIN --version 2>/dev/null | head -1)
BUN_VERSION_NUM=$(echo "$BUN_VERSION_RAW" | sed 's/-.*//')
if [ -z "$BUN_VERSION_NUM" ] \
   || [ "$(printf '%s\n%s\n' "$BUN_VERSION_NUM" "$MIN_BUN_VERSION" | sort -V | head -1)" != "$MIN_BUN_VERSION" ]; then
  warn ""
  warn "Bun ${BUN_VERSION_RAW:-<unknown>} is below the required minimum ($MIN_BUN_VERSION)."
  warn ""
  warn "  Anthropic builds claude-code with Bun's canary channel. Older Bun"
  warn "  panics on cli.original.cjs with 'Expected CommonJS module to have"
  warn "  a function wrapper'. This is a hard requirement, not a warning."
  warn ""
  warn "  Upgrade with one of:"
  warn "    bun upgrade --canary               (if installed via curl/install.sh)"
  warn "    brew upgrade bun                   (homebrew)"
  warn "    scoop uninstall bun && \\           (scoop — shim blocks self-replace)"
  warn "      irm https://bun.sh/install.ps1 | iex && bun upgrade --canary"
  warn ""
  warn "  Then re-run this installer."
  exit 1
fi

# ─── ripgrep prerequisite (search/grep tool) ──────────────────────────
# Without rg the Grep tool inside Claude Code fails. Bun-bundled ripgrep
# is only reachable from inside the standalone executable; running the
# extracted cli.js under Bun runtime means we depend on system rg.
# This is a hard prerequisite — refuse to install otherwise.

if ! command -v rg &>/dev/null; then
  warn "ripgrep (rg) is required but not found in PATH."
  warn "  Claude Code's Grep tool will not function without it."
  warn ""
  case "$(uname -s)" in
    Darwin) warn "  Install: brew install ripgrep" ;;
    Linux)  warn "  Install: apt install ripgrep   |   dnf install ripgrep   |   pacman -S ripgrep" ;;
    *)      warn "  Install: https://github.com/BurntSushi/ripgrep#installation" ;;
  esac
  warn ""
  warn "  Re-run this script after installing rg."
  exit 1
fi
info "ripgrep: $(rg --version | head -1)"

# ─── Locate native Bun binary (cli.js source) ──────────────────────────
# v2.1.113+ ships a Bun standalone executable as the only canonical form.
# We extract cli.js text from this binary, patch it, then run via Bun
# runtime. Source: npm registry (@anthropic-ai/claude-code-<platform>).
# Local binary detection is intentionally skipped — see policy note below.

mkdir -p "$LLMGOD_DIR" "$BIN_DIR"

NATIVE_BIN=""
NATIVE_BIN_LABEL=""
NATIVE_BIN_TMPDIR=""

# Detection policy: ALWAYS pull from the npm registry @latest.
#
# Earlier versions of this script also probed local `node_modules` roots
# (npm-global, bun-global) before falling back to the registry. That was
# a stale-source trap: once llmgod is installed it patches out
# `claude update`, so users never re-run `npm install -g` / `bun add -g`.
# Both directories freeze at whatever version was on disk the day llmgod
# was first installed, and `claude update` (which is now redirected here)
# would re-detect that frozen binary forever — never reaching the
# registry. See INCIDENT_LOG 2026-04-29 entry. The fix is to skip local
# detection entirely; the npm tarball is ~60-90 MB compressed, fetched
# once per upgrade, and npm's HTTP cache keeps repeats fast.

# Detect platform suffix (used by the npm fetch below)
case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *)      os="" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x64" ;;
  *)             arch="" ;;
esac
if [ "$os" = "linux" ] && (ldd /bin/ls 2>/dev/null | grep -q musl); then
  PLATFORM="${os}-${arch}-musl"
else
  PLATFORM="${os}-${arch}"
fi

# Pull the Bun standalone binary from the npm registry. Anthropic publishes
# per-platform packages (e.g. claude-code-darwin-arm64); their tarball ships
# the binary directly under package/.
if [ -z "$NATIVE_BIN" ]; then
  if ! command -v npm &>/dev/null; then
    warn "No native Claude Code binary found locally, and npm is not installed."
    warn "  Either install the official binary first:"
    warn "    curl -fsSL https://claude.ai/install.sh | bash"
    warn "  or install npm so we can fetch it from the registry."
    exit 1
  fi
  if [ -z "$os" ] || [ -z "$arch" ]; then
    warn "Unsupported platform: $(uname -s) $(uname -m)"
    exit 1
  fi
  NPM_PKG="@anthropic-ai/claude-code-${PLATFORM}"
  dim "Fetching $NPM_PKG@latest from npm registry ..."
  NATIVE_BIN_TMPDIR=$(mktemp -d)
  if ( cd "$NATIVE_BIN_TMPDIR" && npm pack "$NPM_PKG@latest" --silent >/dev/null 2>&1 ); then
    TARBALL=$(ls "$NATIVE_BIN_TMPDIR"/*.tgz 2>/dev/null | head -1)
    if [ -n "$TARBALL" ]; then
      ( cd "$NATIVE_BIN_TMPDIR" && tar xzf "$TARBALL" )
      cand="$NATIVE_BIN_TMPDIR/package/claude"
      if [ -f "$cand" ]; then
        sz=$(stat -f%z "$cand" 2>/dev/null || stat -c%s "$cand" 2>/dev/null || echo 0)
        if [ "$sz" -gt 10000000 ]; then
          NATIVE_BIN="$cand"
          NATIVE_BIN_LABEL=$(node -e "console.log(require('$NATIVE_BIN_TMPDIR/package/package.json').version)" 2>/dev/null || echo "npm-latest")
        fi
      fi
    fi
  fi
  if [ -z "$NATIVE_BIN" ]; then
    rm -rf "$NATIVE_BIN_TMPDIR"
    warn "Failed to download $NPM_PKG from npm."
    warn "  Install the official Claude Code binary manually:"
    warn "    curl -fsSL https://claude.ai/install.sh | bash"
    exit 1
  fi
  info "Downloaded $NPM_PKG@$NATIVE_BIN_LABEL"
fi

if [ -z "$NATIVE_BIN" ]; then
  warn "Native Claude Code binary not found"
  warn "Install the official binary first:"
  warn "  curl -fsSL https://claude.ai/install.sh | bash"
  warn "Then re-run this script."
  exit 1
fi

# Write extractor to a temp file (used both for cli.js and .node modules)
cat > "$LLMGOD_DIR/extract-natives.mjs" << 'EXTRACTOR_EOF'
#!/usr/bin/env node
/**
 * Let's LLM native module extractor
 *
 * Extracts embedded .node NAPI modules from a Bun single-file executable
 * (the official Claude Code native binary).
 *
 * Supports:
 *   - Mach-O (macOS) — arm64 + x86_64 thin binaries
 *   - ELF (Linux)    — arm64 + x86_64
 *   - PE (Windows)   — x86_64 + arm64
 *
 * Usage:
 *   node extract-natives.mjs <binary-path> <output-dir>
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'fs';
import { join, basename } from 'path';

// ─── Mach-O constants ────────────────────────────────────────────────

const MH_MAGIC_64 = 0xfeedfacf;           // little-endian 64-bit
const LC_SEGMENT_64 = 0x19;
const LC_ID_DYLIB = 0x0d;
const MH_DYLIB = 6;
const CPU_TYPE_X86_64 = 0x01000007;
const CPU_TYPE_ARM64 = 0x0100000c;

// ─── ELF constants ───────────────────────────────────────────────────

const ELF_MAGIC = Buffer.from([0x7f, 0x45, 0x4c, 0x46]); // 7f 'E' 'L' 'F'
const ET_DYN = 3;                          // shared object
const EM_X86_64 = 62;
const EM_AARCH64 = 183;

// ─── PE constants ────────────────────────────────────────────────────

const MZ_MAGIC = Buffer.from([0x4d, 0x5a]);   // "MZ"
const PE_MAGIC = Buffer.from([0x50, 0x45, 0, 0]); // "PE\0\0"
const IMAGE_FILE_MACHINE_AMD64 = 0x8664;
const IMAGE_FILE_MACHINE_ARM64 = 0xaa64;
const IMAGE_FILE_DLL = 0x2000;

// ─── Helpers ─────────────────────────────────────────────────────────

function archName(format, cputype) {
  if (format === 'macho') {
    if (cputype === CPU_TYPE_ARM64) return 'arm64';
    if (cputype === CPU_TYPE_X86_64) return 'x64';
  }
  if (format === 'elf') {
    if (cputype === EM_AARCH64) return 'arm64';
    if (cputype === EM_X86_64) return 'x64';
  }
  if (format === 'pe') {
    if (cputype === IMAGE_FILE_MACHINE_ARM64) return 'arm64';
    if (cputype === IMAGE_FILE_MACHINE_AMD64) return 'x64';
  }
  return null;
}

function platformSuffix(format, arch) {
  const os = format === 'macho' ? 'darwin' : format === 'elf' ? 'linux' : 'win32';
  return `${arch}-${os}`;
}

// ─── Mach-O parser ───────────────────────────────────────────────────

function parseMachODylib(buf, off) {
  const magic = buf.readUInt32LE(off);
  if (magic !== MH_MAGIC_64) return null;

  const cputype = buf.readUInt32LE(off + 4);
  if (cputype !== CPU_TYPE_ARM64 && cputype !== CPU_TYPE_X86_64) return null;

  const filetype = buf.readUInt32LE(off + 12);
  if (filetype !== MH_DYLIB) return null;

  const ncmds = buf.readUInt32LE(off + 16);
  if (ncmds === 0 || ncmds > 500) return null;

  let totalFileEnd = 0;
  let installName = null;
  let cmdOff = off + 32;

  for (let i = 0; i < ncmds; i++) {
    if (cmdOff + 8 > buf.length) return null;

    const cmd = buf.readUInt32LE(cmdOff);
    const cmdsize = buf.readUInt32LE(cmdOff + 4);
    if (cmdsize === 0 || cmdsize > 65536) return null;

    if (cmd === LC_SEGMENT_64) {
      const fileoff = Number(buf.readBigUInt64LE(cmdOff + 40));
      const filesize = Number(buf.readBigUInt64LE(cmdOff + 48));
      const end = fileoff + filesize;
      if (end > totalFileEnd) totalFileEnd = end;
    } else if (cmd === LC_ID_DYLIB) {
      // dylib_command: uint32 cmd, cmdsize, str_offset, timestamp, version...
      // then name string at cmdOff + str_offset
      const strOff = buf.readUInt32LE(cmdOff + 8);
      const nameStart = cmdOff + strOff;
      const nameEnd = buf.indexOf(0, nameStart);
      if (nameEnd !== -1 && nameEnd - nameStart < 1024) {
        installName = buf.slice(nameStart, nameEnd).toString('utf8');
      }
    }

    cmdOff += cmdsize;
  }

  if (totalFileEnd === 0) return null;

  return {
    offset: off,
    size: totalFileEnd,
    arch: archName('macho', cputype),
    installName,
  };
}

function extractMachODylibs(buf) {
  const dylibs = [];
  // Magic bytes for fast indexOf scan: cf fa ed fe (MH_MAGIC_64 LE)
  const magicBytes = Buffer.from([0xcf, 0xfa, 0xed, 0xfe]);

  let off = 1;  // skip the main binary at offset 0
  while ((off = buf.indexOf(magicBytes, off)) !== -1) {
    const info = parseMachODylib(buf, off);
    if (info && off + info.size <= buf.length) {
      dylibs.push(info);
      off += info.size;  // skip past this dylib
    } else {
      off += 4;
    }
  }

  return dylibs;
}

// ─── ELF parser ──────────────────────────────────────────────────────

function parseELFSharedObject(buf, off) {
  if (buf.length - off < 64) return null;
  if (!buf.slice(off, off + 4).equals(ELF_MAGIC)) return null;

  const eiClass = buf.readUInt8(off + 4);        // 1=32-bit, 2=64-bit
  if (eiClass !== 2) return null;

  const eiData = buf.readUInt8(off + 5);         // 1=LE, 2=BE
  if (eiData !== 1) return null;                 // only LE supported

  const eType = buf.readUInt16LE(off + 16);
  if (eType !== ET_DYN) return null;

  const eMachine = buf.readUInt16LE(off + 18);
  if (eMachine !== EM_X86_64 && eMachine !== EM_AARCH64) return null;

  // ELF64 header layout:
  //   e_shoff (section header offset): off + 40 (u64)
  //   e_shentsize: off + 58 (u16)
  //   e_shnum:     off + 60 (u16)
  const shoff = Number(buf.readBigUInt64LE(off + 40));
  const shentsize = buf.readUInt16LE(off + 58);
  const shnum = buf.readUInt16LE(off + 60);

  if (shentsize !== 64 || shnum === 0 || shnum > 1000) return null;

  // Total size = shoff + shnum * shentsize (the section header table is at the end)
  const totalSize = shoff + shnum * shentsize;
  if (totalSize > buf.length - off) return null;

  return {
    offset: off,
    size: totalSize,
    arch: archName('elf', eMachine),
    installName: null,  // ELF soname requires dynamic section walk; we'll rely on adjacent strings
  };
}

function extractELFSharedObjects(buf) {
  const sos = [];

  // Scan for ELF magic; ELF headers are rare in data so 4-byte alignment is fine
  for (let off = 4; off < buf.length - 64; off += 4) {
    if (buf.readUInt8(off) !== 0x7f) continue;
    const info = parseELFSharedObject(buf, off);
    if (!info) continue;
    if (off + info.size > buf.length) continue;
    sos.push(info);
  }

  return sos;
}

// ─── PE parser ───────────────────────────────────────────────────────

function parsePEDll(buf, off) {
  if (buf.length - off < 1024) return null;
  if (!buf.slice(off, off + 2).equals(MZ_MAGIC)) return null;

  // PE header offset at MZ + 0x3c (e_lfanew)
  const peOff = buf.readUInt32LE(off + 0x3c);
  if (peOff > 4096) return null;                 // sanity

  if (off + peOff + 24 > buf.length) return null;
  if (!buf.slice(off + peOff, off + peOff + 4).equals(PE_MAGIC)) return null;

  const machine = buf.readUInt16LE(off + peOff + 4);
  if (machine !== IMAGE_FILE_MACHINE_AMD64 && machine !== IMAGE_FILE_MACHINE_ARM64) return null;

  const numberOfSections = buf.readUInt16LE(off + peOff + 6);
  const sizeOfOptionalHeader = buf.readUInt16LE(off + peOff + 20);
  const characteristics = buf.readUInt16LE(off + peOff + 22);
  if (!(characteristics & IMAGE_FILE_DLL)) return null;

  // Walk sections to find the max (PointerToRawData + SizeOfRawData)
  const sectionHeaderOff = off + peOff + 24 + sizeOfOptionalHeader;
  let totalSize = sectionHeaderOff - off;  // header area minimum

  for (let i = 0; i < numberOfSections; i++) {
    const secOff = sectionHeaderOff + i * 40;
    if (secOff + 40 > buf.length) return null;
    const sizeOfRawData = buf.readUInt32LE(secOff + 16);
    const pointerToRawData = buf.readUInt32LE(secOff + 20);
    const end = pointerToRawData + sizeOfRawData;
    if (end > totalSize) totalSize = end;
  }

  if (totalSize === 0 || totalSize > 50 * 1024 * 1024) return null;

  return {
    offset: off,
    size: totalSize,
    arch: archName('pe', machine),
    installName: null,
  };
}

function extractPEDlls(buf) {
  const dlls = [];

  for (let off = 0; off < buf.length - 1024; off++) {
    if (buf.readUInt8(off) !== 0x4d) continue;
    if (buf.readUInt8(off + 1) !== 0x5a) continue;
    const info = parsePEDll(buf, off);
    if (!info) continue;
    if (off + info.size > buf.length) continue;
    dlls.push(info);
  }

  return dlls;
}

// ─── Main dispatch ───────────────────────────────────────────────────

function detectFormat(buf) {
  if (buf.readUInt32LE(0) === MH_MAGIC_64) return 'macho';
  if (buf.slice(0, 4).equals(ELF_MAGIC)) return 'elf';
  if (buf.slice(0, 2).equals(MZ_MAGIC)) return 'pe';
  return null;
}

// Names to look for from install names / nearby strings
const KNOWN_MODULES = [
  'image-processor',
  'audio-capture',
  'computer-use-input',
  'computer-use-swift',
  'url-handler',
];

function identifyDylib(buf, dylib) {
  // 1. Try install name (most reliable)
  if (dylib.installName) {
    const base = basename(dylib.installName).replace(/\.(node|dylib|so|dll)$/, '');
    for (const m of KNOWN_MODULES) {
      if (base === m) return m;
      // Handle variants like "libcomputer_use_input.dylib"
      if (base === `lib${m.replace(/-/g, '_')}`) return m;
      if (base === `lib${m.replace(/-/g, '')}`) return m;
      if (base.toLowerCase().includes(m.replace(/-/g, ''))) return m;
    }
  }

  // 2. Scan the dylib body for known module name strings
  const body = buf.slice(dylib.offset, dylib.offset + dylib.size);
  for (const m of KNOWN_MODULES) {
    if (body.indexOf(Buffer.from(m)) !== -1) return m;
  }

  return null;
}

// ─── cli.js text extraction (Bun standalone) ─────────────────────────
//
// Two-stage anchor strategy:
//  1. Primary: Bun's bunfs path marker, observed in Mach-O / ELF builds.
//  2. Fallback: an application-level invariant ("cli_after_main_complete")
//     followed by a backwards scan to the IIFE start. Some Windows PE
//     builds don't appear to embed the bunfs path string we expect, so
//     this fallback recovers the same payload via app-level signals.

const CLI_PATH_MARKER = Buffer.from('file:///$bunfs/root/src/entrypoints/cli.js');
const CLI_FN_MARKER = Buffer.from('(function(exports, require, module');
const CLI_TAIL_MARKER = Buffer.from('cli_after_main_complete")}');
const CLI_END_MARKER = Buffer.from(');})');

function extractCliJs(buf) {
  // Primary anchor
  let fnStart = -1;
  const pathOff = buf.indexOf(CLI_PATH_MARKER);
  if (pathOff !== -1) {
    const candidate = buf.indexOf(CLI_FN_MARKER, pathOff);
    if (candidate !== -1 && candidate - pathOff <= 1024) fnStart = candidate;
  }

  // Fallback anchor: walk back from the source-level tail marker.
  if (fnStart === -1) {
    const tailMark = buf.indexOf(CLI_TAIL_MARKER);
    if (tailMark === -1) return null;
    const candidate = buf.lastIndexOf(CLI_FN_MARKER, tailMark);
    // The IIFE wraps the entire ~13 MB cli.js, so a valid candidate must
    // sit at least 1 MB before the tail marker. Smaller gaps mean we
    // matched a different (function(exports... wrapper for a sub-module.
    if (candidate === -1 || tailMark - candidate < 1024 * 1024) return null;
    fnStart = candidate;
  }

  // Resolve the IIFE close — search forward from fnStart so that we close
  // the wrapper we actually opened, regardless of which anchor located it.
  const tailFromFn = buf.indexOf(CLI_TAIL_MARKER, fnStart);
  if (tailFromFn === -1) return null;
  const ending = buf.indexOf(CLI_END_MARKER, tailFromFn);
  if (ending === -1 || ending - tailFromFn > 4096) return null;
  return buf.slice(fnStart, ending + CLI_END_MARKER.length).toString('utf8');
}

function main() {
  const [, , binaryPath, outputDir, ...rest] = process.argv;
  const wantCliJs = rest.includes('--cli-js');

  if (!binaryPath || !outputDir) {
    console.error('Usage: extract-natives.mjs <binary-path> <output-dir> [--cli-js]');
    process.exit(1);
  }

  if (!existsSync(binaryPath)) {
    console.error(`Binary not found: ${binaryPath}`);
    process.exit(1);
  }

  const stat = statSync(binaryPath);
  if (stat.size < 10 * 1024 * 1024) {
    console.error(`Binary too small (${stat.size} bytes) — not a native Claude Code binary`);
    process.exit(1);
  }

  const buf = readFileSync(binaryPath);
  const format = detectFormat(buf);

  if (!format) {
    console.error('Unknown binary format (expected Mach-O / ELF / PE)');
    process.exit(1);
  }

  console.log(`Format:  ${format}`);
  console.log(`Size:    ${(buf.length / 1024 / 1024).toFixed(1)} MB`);

  if (wantCliJs) {
    const js = extractCliJs(buf);
    if (!js) {
      console.error('Could not locate cli.js payload in binary (markers missing).');
      process.exit(2);
    }
    mkdirSync(outputDir, { recursive: true });
    const out = join(outputDir, 'cli.original.js');
    writeFileSync(out, js);
    console.log(`  cli.js  ${(js.length / 1024 / 1024).toFixed(2)} MB → ${out}`);
    return;
  }

  let libs = [];
  if (format === 'macho') libs = extractMachODylibs(buf);
  else if (format === 'elf') libs = extractELFSharedObjects(buf);
  else if (format === 'pe') libs = extractPEDlls(buf);

  // Skip the first (main binary itself)
  libs = libs.filter(l => l.offset !== 0);

  console.log(`Found:   ${libs.length} embedded native libraries`);
  console.log();

  mkdirSync(outputDir, { recursive: true });

  const summary = { extracted: [], skipped: [] };

  for (const lib of libs) {
    const name = identifyDylib(buf, lib);
    if (!name) {
      summary.skipped.push({ ...lib, reason: 'unidentified' });
      continue;
    }

    const platform = platformSuffix(format, lib.arch);
    const targetDir = join(outputDir, name, platform);
    mkdirSync(targetDir, { recursive: true });
    const targetFile = join(targetDir, `${name}.node`);

    const data = buf.slice(lib.offset, lib.offset + lib.size);
    writeFileSync(targetFile, data);

    console.log(`  ✓ ${name.padEnd(20)} ${lib.arch.padEnd(6)} ${(lib.size / 1024).toFixed(0).padStart(5)} KB → ${targetFile}`);
    summary.extracted.push({ name, platform, size: lib.size });
  }

  console.log();
  console.log(`Extracted ${summary.extracted.length}, skipped ${summary.skipped.length}`);

  if (summary.skipped.length > 0) {
    console.log('\nSkipped (unidentified):');
    for (const s of summary.skipped) {
      console.log(`  offset=${s.offset} arch=${s.arch} size=${(s.size / 1024).toFixed(0)}KB`);
    }
  }
}

main();
EXTRACTOR_EOF

# ─── Extract cli.js + native modules from Bun binary ──────────
# Note: extract-natives.mjs and post-process.mjs are kept around (NOT deleted)
# so the wrapper's drift detector can re-run them when the user upgrades
# their native Claude binary.

VENDOR_DIR="$LLMGOD_DIR/vendor"
rm -rf "$VENDOR_DIR" 2>/dev/null
mkdir -p "$VENDOR_DIR"

dim "Extracting cli.js from $(echo "$NATIVE_BIN_LABEL") ..."
if ! node "$LLMGOD_DIR/extract-natives.mjs" "$NATIVE_BIN" "$LLMGOD_DIR" --cli-js 2>&1 | while IFS= read -r line; do echo "  $line"; done; then
  err "Failed to extract cli.js from native binary"
  exit 1
fi
[ -f "$LLMGOD_DIR/cli.original.js" ] || { err "cli.js missing after extraction"; exit 1; }

dim "Extracting native modules from $(echo "$NATIVE_BIN_LABEL") ..."
node "$LLMGOD_DIR/extract-natives.mjs" "$NATIVE_BIN" "$VENDOR_DIR" 2>&1 | while IFS= read -r line; do echo "  $line"; done || true

# ─── Post-process cli.js for Bun runtime ──────────────────────
# 1. Rewrite /$bunfs/root/X.node paths to point at extracted vendor modules
# 2. Rewrite build-time /home/runner/.../*.ts URLs (used by ripgrep,
#    sandbox, computer-use, etc. for asset resolution) to __filename so
#    relative resolutions land near our cli.original.cjs
# 3. Wrap the Bun-cjs IIFE with an actual invocation so `require()` runs it
# 4. Save as .cjs (Bun + CJS module wrapper)

dim "Rewriting bunfs paths and IIFE invocation ..."
cat > "$LLMGOD_DIR/post-process.mjs" << 'POSTPROC_EOF'
import { readFileSync, writeFileSync, unlinkSync } from 'fs';
import { dirname } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const src = `${here}/cli.original.js`;
const dst = `${here}/cli.original.cjs`;

let code = readFileSync(src, 'utf8');

// (1) bunfs .node module paths → runtime vendor lookup
code = code.replace(
  /require\(['"](\/\$bunfs\/root\/([\w-]+)\.node)['"]\)/g,
  (m, _full, name) =>
    `require(require('path').join(__dirname,'vendor',${JSON.stringify(name)},\`\${process.arch==='arm64'?'arm64':'x64'}-\${process.platform==='darwin'?'darwin':process.platform==='linux'?'linux':'win32'}\`,${JSON.stringify(name + '.node')}))`,
);

// (2) build-time fileURLToPath() leaks → use cli.cjs's own __filename
code = code.replace(
  /[\w$]+\.fileURLToPath\("file:\/\/\/home\/runner\/work\/claude-cli-internal\/claude-cli-internal\/[^"]*"\)/g,
  () => '__filename',
);

// (3) make the outer (function(...){...}) actually run
code = code.replace(/\}\)\s*$/, '})(exports, require, module, __filename, __dirname)');

writeFileSync(dst, code);
unlinkSync(src);
console.log(`cli.original.cjs: ${code.length} bytes`);
POSTPROC_EOF
node "$LLMGOD_DIR/post-process.mjs" 2>&1 | while IFS= read -r line; do echo "  $line"; done
[ -f "$LLMGOD_DIR/cli.original.cjs" ] || { err "Post-process failed"; exit 1; }

# Stamp the source version so the wrapper can detect drift on next launch
echo "$NATIVE_BIN_LABEL" > "$LLMGOD_DIR/.source-version"

# If we pulled the binary from npm into a tmpdir, clean it up now —
# extraction is done, drift detection only consults ~/.local/share/claude/versions/.
if [ -n "$NATIVE_BIN_TMPDIR" ]; then
  rm -rf "$NATIVE_BIN_TMPDIR"
fi

info "cli.original.cjs ready ($NATIVE_BIN_LABEL)"

# ─── Write re-patch helper (used by wrapper on version drift) ─────────

cat > "$LLMGOD_DIR/repatch.mjs" << 'REPATCH_EOF'
#!/usr/bin/env bun
// Re-extract + post-process + patch the user's currently-installed
// native Claude binary. Invoked by cli.cjs when it detects that
// .source-version no longer matches the latest binary in versions/.
import { spawnSync } from 'child_process';
import { writeFileSync, existsSync, mkdirSync, rmSync } from 'fs';
import { dirname, join, basename } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const nativeBin = process.argv[2];

if (!nativeBin || !existsSync(nativeBin)) {
  console.error('repatch: native binary path required and must exist');
  process.exit(1);
}

const vendor = join(here, 'vendor');
rmSync(vendor, { recursive: true, force: true });
mkdirSync(vendor, { recursive: true });

const runtime = process.execPath;

function run(label, args) {
  const r = spawnSync(runtime, args, { cwd: here, stdio: 'inherit' });
  if (r.status !== 0) {
    console.error(`repatch: ${label} failed (exit ${r.status})`);
    process.exit(1);
  }
}

const extractor = join(here, 'extract-natives.mjs');
const postProc = join(here, 'post-process.mjs');
const patcher = join(here, 'patch.mjs');

run('extract cli.js', [extractor, nativeBin, here, '--cli-js']);
run('extract natives', [extractor, nativeBin, vendor]);
run('post-process', [postProc]);
run('patcher', [patcher]);

writeFileSync(join(here, '.source-version'), basename(nativeBin) + '\n');
console.log(`[llmgod] re-patched to ${basename(nativeBin)}`);
REPATCH_EOF
chmod +x "$LLMGOD_DIR/repatch.mjs"
info "Re-patch helper installed (repatch.mjs)"

# ─── Write OVERDRIVE runtime modules (generated; see scripts/embed-overdrive.mjs) ─
mkdir -p "$LLMGOD_DIR/overdrive"
# >>> OVERDRIVE MODULES >>>
# (regenerate with: node scripts/embed-overdrive.mjs)
cat > "$LLMGOD_DIR/overdrive/pricing.mjs" << 'OVERDRIVE_PRICING_MJS_EOF'
// >>> OVERDRIVE pricing.mjs >>>
// src/overdrive/pricing.mjs
// USD per 1,000,000 tokens (standard <=200k tier). VERIFY against current public
// pricing at platform.claude.com/docs/about-claude/pricing before release.
export const PRICE_TABLE = {
  "claude-opus-4-8":   { input: 15, output: 75, cacheWrite1h: 30,  cacheWrite5m: 18.75, cacheRead: 1.5 },
  "claude-sonnet-4-6": { input: 3,  output: 15, cacheWrite1h: 6,   cacheWrite5m: 3.75,  cacheRead: 0.3 },
  "claude-haiku-4-5":  { input: 1,  output: 5,  cacheWrite1h: 2,   cacheWrite5m: 1.25,  cacheRead: 0.1 },
};

export function normalizeModel(model) {
  if (!model) return "";
  return String(model).replace(/\[1m\]$/i, "").replace(/^.*\//, "").trim();
}

export function resolvePrice(model, overrides = {}) {
  if (overrides && overrides[model]) return overrides[model];
  const norm = normalizeModel(model);
  if (overrides && overrides[norm]) return overrides[norm];
  return PRICE_TABLE[norm] || null;
}

export function computeCost(model, tokens = {}, overrides = {}) {
  const p = resolvePrice(model, overrides);
  if (!p) return { usd: 0, priced: false };
  const per = (n, rate) => ((Number(n) || 0) / 1e6) * (Number(rate) || 0);
  const usd =
    per(tokens.input, p.input) +
    per(tokens.output, p.output) +
    per(tokens.cacheCreate, p.cacheWrite1h ?? p.cacheWrite5m ?? p.input) +
    per(tokens.cacheRead, p.cacheRead);
  return { usd, priced: true };
}
// <<< OVERDRIVE pricing.mjs <<<
OVERDRIVE_PRICING_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/metering.mjs" << 'OVERDRIVE_METERING_MJS_EOF'
// >>> OVERDRIVE metering.mjs >>>
// src/overdrive/metering.mjs
import { readFileSync, writeFileSync, renameSync, mkdirSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { computeCost } from "./pricing.mjs";

export function emptyMeter(sessionId, model = "") {
  const now = Date.now();
  return {
    sessionId, model, startedAt: now, updatedAt: now, turns: 0,
    tokens: { input: 0, output: 0, cacheCreate: 0, cacheRead: 0 },
    cacheHitRate: 0, cost: { usd: 0, priced: false },
  };
}

// Pure: fold one API usage record into a meter, returning a new meter.
export function accumulate(meter, usage = {}, overrides = {}) {
  const t = meter.tokens;
  const tokens = {
    input: t.input + (usage.input_tokens || 0),
    output: t.output + (usage.output_tokens || 0),
    cacheCreate: t.cacheCreate + (usage.cache_creation_input_tokens || 0),
    cacheRead: t.cacheRead + (usage.cache_read_input_tokens || 0),
  };
  const cacheable = tokens.input + tokens.cacheCreate + tokens.cacheRead;
  const cacheHitRate = cacheable > 0 ? tokens.cacheRead / cacheable : 0;
  const model = usage.model || meter.model;
  return {
    ...meter, model, updatedAt: Date.now(),
    turns: meter.turns + (usage.__turn ? 1 : 0),
    tokens, cacheHitRate, cost: computeCost(model, tokens, overrides),
  };
}

const dirFor = (dir) => join(dir, "metering");
export const meterPath = (dir, id) => join(dirFor(dir), `session-${id}.json`);

export function saveMeter(dir, meter) {
  mkdirSync(dirFor(dir), { recursive: true });
  const p = meterPath(dir, meter.sessionId);
  const tmp = p + ".tmp";
  writeFileSync(tmp, JSON.stringify(meter));
  renameSync(tmp, p);
}

export function loadMeter(dir, id, model = "") {
  try { return JSON.parse(readFileSync(meterPath(dir, id), "utf8")); }
  catch { return emptyMeter(id, model); }
}

export function newestMeter(dir) {
  try {
    const files = readdirSync(dirFor(dir)).filter((f) => f.startsWith("session-") && f.endsWith(".json"));
    if (!files.length) return null;
    const scored = files.map((f) => {
      const full = join(dirFor(dir), f);
      let updatedAt = 0;
      try { updatedAt = JSON.parse(readFileSync(full, "utf8")).updatedAt || 0; } catch {}
      return { f, mtime: statSync(full).mtimeMs, updatedAt };
    });
    scored.sort((a, b) => (b.mtime - a.mtime) || (b.updatedAt - a.updatedAt));
    return JSON.parse(readFileSync(join(dirFor(dir), scored[0].f), "utf8"));
  } catch { return null; }
}
// <<< OVERDRIVE metering.mjs <<<
OVERDRIVE_METERING_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/probe.mjs" << 'OVERDRIVE_PROBE_MJS_EOF'
// >>> OVERDRIVE probe.mjs >>>
// src/overdrive/probe.mjs
import { loadMeter, saveMeter, accumulate } from "./metering.mjs";

// Pure: pull merged usage out of an SSE message stream body.
export function parseUsageFromSSE(text) {
  const usage = { model: "" };
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s.startsWith("data:")) continue;
    let obj;
    try { obj = JSON.parse(s.slice(5).trim()); } catch { continue; }
    if (obj.type === "message_start" && obj.message) {
      usage.model = obj.message.model || usage.model;
      Object.assign(usage, obj.message.usage || {});
    } else if (obj.type === "message_delta" && obj.usage) {
      Object.assign(usage, obj.usage); // output_tokens lands here
    }
  }
  return usage;
}

const isMessagesUrl = (u) => typeof u === "string" ? /\/v1\/messages\b/.test(u)
  : !!(u && u.url && /\/v1\/messages\b/.test(u.url));

// Installs a globalThis.fetch wrapper. Returns an uninstall fn.
// Fully fault-isolated: any failure falls back to the original fetch.
export function installProbe(config = {}, dir, sessionId) {
  const original = globalThis.fetch;
  const overrides = config.pricing || {};
  globalThis.fetch = async function (input, init) {
    const res = await original(input, init);
    try {
      const url = typeof input === "string" ? input : input?.url;
      if (isMessagesUrl(url) && res && res.body) {
        const clone = res.clone();
        clone.text().then((body) => {
          try {
            const usage = parseUsageFromSSE(body);
            usage.__turn = true;
            const meter = accumulate(loadMeter(dir, sessionId, usage.model), usage, overrides);
            saveMeter(dir, meter);
          } catch { /* metering is best-effort */ }
        }).catch(() => {});
      }
    } catch { /* never perturb the request */ }
    return res;
  };
  return function uninstall() { globalThis.fetch = original; };
}
// <<< OVERDRIVE probe.mjs <<<
OVERDRIVE_PROBE_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/statusline.mjs" << 'OVERDRIVE_STATUSLINE_MJS_EOF'
// >>> OVERDRIVE statusline.mjs >>>
// src/overdrive/statusline.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";

// stdin: Claude Code statusLine payload. Field names are defensive — confirm
// against code.claude.com/docs/en/statusline; unknown fields are simply dropped.
export function formatStatusline(stdin = {}, meter = null) {
  const parts = [];

  const ctx = stdin?.context?.used_pct ?? stdin?.context_percent;
  if (typeof ctx === "number" && isFinite(ctx)) parts.push(`ctx ${Math.round(ctx)}%`);

  const usd = stdin?.cost?.total_cost_usd ?? (meter?.cost?.priced ? meter.cost.usd : null);
  if (typeof usd === "number" && isFinite(usd)) parts.push(`$${usd.toFixed(2)}`);

  if (meter) {
    const t = meter.tokens;
    if (t && (t.cacheRead + t.input + t.cacheCreate) > 0)
      parts.push(`cache ${Math.round((meter.cacheHitRate || 0) * 100)}%`);
  }

  return parts.join(" · ");
}

async function readStdin() {
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  try { return JSON.parse(data); } catch { return {}; }
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    const stdin = await readStdin();
    process.stdout.write(formatStatusline(stdin, newestMeter(dir)));
  } catch { /* a broken statusline must never break the prompt */ }
}
// <<< OVERDRIVE statusline.mjs <<<
OVERDRIVE_STATUSLINE_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/panel.mjs" << 'OVERDRIVE_PANEL_MJS_EOF'
// >>> OVERDRIVE panel.mjs >>>
// src/overdrive/panel.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";
import { readFileSync } from "fs";

const n = (x) => (Number(x) || 0).toLocaleString();

export function formatPanel(meter, config = {}) {
  if (!meter) return "llmgod xray: no metering data yet — run a turn first.";
  const t = meter.tokens;
  const thirdParty = !!(config.baseURL && !/anthropic\.com/i.test(config.baseURL));
  const lines = [
    `Session ${meter.sessionId}  ·  ${meter.model || "unknown"}`,
    ``,
    `  input        ${n(t.input)}`,
    `  output       ${n(t.output)}`,
    `  cache write  ${n(t.cacheCreate)}`,
    `  cache read   ${n(t.cacheRead)}`,
    `  cache hit    ${Math.round((meter.cacheHitRate || 0) * 100)}%`,
    ``,
    meter.cost.priced
      ? `  cost         $${meter.cost.usd.toFixed(4)}`
      : `  cost         (no price for model — set provider.json.pricing)`,
    `  billing header ${thirdParty ? "disabled (third-party cache fix active)" : "enabled (Anthropic)"}`,
  ];
  return lines.join("\n");
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    let config = {};
    try { config = JSON.parse(readFileSync(join(dir, "provider.json"), "utf8")); } catch {}
    process.stdout.write(formatPanel(newestMeter(dir), config) + "\n");
  } catch (e) {
    process.stdout.write("llmgod xray: unavailable\n");
  }
}
// <<< OVERDRIVE panel.mjs <<<
OVERDRIVE_PANEL_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/limits-env.mjs" << 'OVERDRIVE_LIMITS_ENV_MJS_EOF'
// >>> OVERDRIVE limits-env.mjs >>>
// src/overdrive/limits-env.mjs
// Pure: translate config.limits into a plan of env vars to apply.
// Keys prefixed `__unset_` request deletion of that env var by the caller.
export function limitEnv(limits = {}, env = {}) {
  const out = {};

  if (Number.isInteger(limits.thinkingBudget) && limits.thinkingBudget > 0) {
    out.MAX_THINKING_TOKENS = String(limits.thinkingBudget);
  }

  if (limits.context1m === true) {
    const with1m = (val, fallback) => {
      const base = val || fallback;
      return /\[1m\]$/i.test(base) ? base : base + "[1m]";
    };
    out.ANTHROPIC_DEFAULT_OPUS_MODEL = with1m(env.ANTHROPIC_DEFAULT_OPUS_MODEL, "claude-opus-4-8");
    out.ANTHROPIC_DEFAULT_SONNET_MODEL = with1m(env.ANTHROPIC_DEFAULT_SONNET_MODEL, "claude-sonnet-4-6");
    out.__unset_CLAUDE_CODE_DISABLE_1M_CONTEXT = true;
  }

  if (limits.concurrency === true) {
    out.LLMGOD_MAX_CONCURRENCY = "64";
  } else if (Number.isInteger(limits.concurrency) && limits.concurrency > 0) {
    out.LLMGOD_MAX_CONCURRENCY = String(limits.concurrency);
  }

  if (limits.modelAllowlist === true) {
    out.LLMGOD_ALLOW_ANY_MODEL = "1";
  }

  return out;
}
// <<< OVERDRIVE limits-env.mjs <<<
OVERDRIVE_LIMITS_ENV_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/workflow-cli.mjs" << 'OVERDRIVE_WORKFLOW_CLI_MJS_EOF'
// >>> OVERDRIVE workflow-cli.mjs >>>
// src/overdrive/workflow-cli.mjs
import { join } from "path";

// Extract { name, description } from a workflow file's `export const meta = {...}`.
// Defensive regex (does not execute the file); returns null when there is no name.
export function parseWorkflowMeta(source) {
  if (typeof source !== "string") return null;
  const name = source.match(/name\s*:\s*['"]([^'"]+)['"]/);
  if (!name) return null;
  const desc = source.match(/description\s*:\s*['"]([^'"]+)['"]/);
  return { name: name[1], description: desc ? desc[1] : "" };
}

// dirs: [{ scope, path }]; fs: { existsSync, readdirSync, readFileSync }.
// Returns [{ name, description, scope, path }] for every *.js workflow found.
export function listWorkflows(dirs, fs) {
  const out = [];
  for (const { scope, path } of dirs) {
    if (!fs.existsSync(path)) continue;
    for (const f of fs.readdirSync(path)) {
      if (!f.endsWith(".js")) continue;
      const full = join(path, f);
      let meta = null;
      try { meta = parseWorkflowMeta(fs.readFileSync(full, "utf8")); } catch {}
      out.push({ name: meta?.name ?? f.replace(/\.js$/, ""), description: meta?.description ?? "", scope, path: full });
    }
  }
  return out;
}

export function validName(name) {
  return typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name);
}

// A runnable starter the user fills in. The TODOs are intentional scaffold
// content for the end user, not plan placeholders.
export function scaffoldWorkflow(name) {
  return [
    "export const meta = {",
    "  name: '" + name + "',",
    "  description: 'TODO: one-line description of " + name + "',",
    "  phases: [{ title: 'Main' }],",
    "}",
    "",
    "phase('Main')",
    "const result = await agent('TODO: describe the task for this agent')",
    "return { result }",
    "",
  ].join("\n");
}

const USAGE = [
  "llmgod workflow — manage the Claude Code workflow library",
  "",
  "  ls                list user + project workflows",
  "  new <name>        scaffold ~/.claude/workflows/<name>.js",
  "  rm  <name>        remove ~/.claude/workflows/<name>.js",
  "",
  "Run a workflow from inside Claude Code with: Workflow({ name: '<name>' })",
  "",
].join("\n");

// deps: { argv (after 'workflow'), homeDir, cwd, out, err, fs }. Returns exit code.
export function runWorkflowCli({ argv, homeDir, cwd, out, err, fs }) {
  const userDir = join(homeDir, ".claude", "workflows");
  const projDir = join(cwd, ".claude", "workflows");
  const [sub, arg] = argv;

  if (sub === "ls") {
    const rows = listWorkflows([{ scope: "user", path: userDir }, { scope: "project", path: projDir }], fs);
    if (!rows.length) { out("(no workflows; create one with: llmgod workflow new <name>)\n"); return 0; }
    for (const r of rows) out(`${r.name}\t[${r.scope}]\t${r.description}\n`);
    return 0;
  }

  if (sub === "new") {
    if (!validName(arg)) { err("invalid name: " + arg + "\n"); return 1; }
    const p = join(userDir, arg + ".js");
    if (fs.existsSync(p)) { err("exists: " + p + "\n"); return 1; }
    if (!fs.existsSync(userDir)) fs.mkdirSync(userDir, { recursive: true });
    fs.writeFileSync(p, scaffoldWorkflow(arg));
    out("created " + p + "\n");
    return 0;
  }

  if (sub === "rm") {
    if (!validName(arg)) { err("invalid name: " + arg + "\n"); return 1; }
    const p = join(userDir, arg + ".js");
    if (!fs.existsSync(p)) { err("not found: " + p + "\n"); return 1; }
    fs.unlinkSync(p);
    out("removed " + p + "\n");
    return 0;
  }

  out(USAGE);
  return 0;
}

if (import.meta.main) {
  const fs = await import("fs");
  const os = await import("os");
  const code = runWorkflowCli({
    argv: process.argv.slice(2),
    homeDir: os.homedir(),
    cwd: process.cwd(),
    out: (s) => process.stdout.write(s),
    err: (s) => process.stderr.write(s),
    fs,
  });
  process.exit(code);
}
// <<< OVERDRIVE workflow-cli.mjs <<<
OVERDRIVE_WORKFLOW_CLI_MJS_EOF
cat > "$LLMGOD_DIR/overdrive/workflow-library.mjs" << 'OVERDRIVE_WORKFLOW_LIBRARY_MJS_EOF'
// >>> OVERDRIVE workflow-library.mjs >>>
// src/overdrive/workflow-library.mjs
import { join } from "path";

// Curated starter workflows seeded into ~/.claude/workflows/ (never-clobber).
// IMPORTANT: keep each `source` free of backticks and ${ } so it survives being
// stored in this module's string array AND embedded into install.sh's
// single-quoted heredoc unchanged.
const REVIEW = [
  "export const meta = {",
  "  name: 'review',",
  "  description: 'Review the git diff across dimensions, then adversarially verify each finding',",
  "  phases: [{ title: 'Review' }, { title: 'Verify' }],",
  "}",
  "",
  "const DIMENSIONS = [",
  "  { key: 'bugs', prompt: 'Run: git diff. Find correctness bugs in the diff. Return concrete findings.' },",
  "  { key: 'security', prompt: 'Run: git diff. Find security issues in the diff. Return concrete findings.' },",
  "]",
  "",
  "const FINDINGS = { type: 'object', properties: { findings: { type: 'array', items: {",
  "  type: 'object', properties: { title: { type: 'string' }, detail: { type: 'string' } }, required: ['title','detail'] } } }, required: ['findings'] }",
  "const VERDICT = { type: 'object', properties: { isReal: { type: 'boolean' }, reason: { type: 'string' } }, required: ['isReal','reason'] }",
  "",
  "const results = await pipeline(",
  "  DIMENSIONS,",
  "  (d) => agent(d.prompt, { label: 'review:' + d.key, phase: 'Review', schema: FINDINGS }),",
  "  (review, d) => parallel((review.findings || []).map((f) => () =>",
  "    agent('Adversarially verify; default isReal=false if unsure: ' + f.title + ' -- ' + f.detail,",
  "      { label: 'verify:' + d.key, phase: 'Verify', schema: VERDICT }).then((v) => ({ ...f, dimension: d.key, verdict: v })))),",
  ")",
  "const confirmed = results.flat().filter(Boolean).filter((f) => f.verdict && f.verdict.isReal)",
  "return { confirmed, total: confirmed.length }",
  "",
].join("\n");

export const STARTER_LIBRARY = [
  { name: "review", source: REVIEW },
];

// Write each starter into `dir` only when the target file is absent.
// fs: { existsSync, mkdirSync, writeFileSync }. Returns names actually written.
export function seedLibrary(dir, fs) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const seeded = [];
  for (const { name, source } of STARTER_LIBRARY) {
    const p = join(dir, name + ".js");
    if (fs.existsSync(p)) continue;
    fs.writeFileSync(p, source);
    seeded.push(name);
  }
  return seeded;
}
// <<< OVERDRIVE workflow-library.mjs <<<
OVERDRIVE_WORKFLOW_LIBRARY_MJS_EOF
# <<< OVERDRIVE MODULES <<<

# ─── Write wrapper (cli.cjs, runs under Bun) ──────────────────

cat > "$LLMGOD_DIR/cli.cjs" << 'WRAPPER_EOF'
#!/usr/bin/env bun
const { readFileSync, existsSync, mkdirSync, writeFileSync, readdirSync, statSync, renameSync } = require('fs');
const { join, basename } = require('path');
const { homedir } = require('os');
const { spawnSync } = require('child_process');

const llmgodDir = join(homedir(), '.llmgod');

// OVERDRIVE: `llmgod xray` deep panel — handle before anything else, then exit.
if (process.argv[2] === 'xray') {
  spawnSync(process.execPath, [join(llmgodDir, 'overdrive', 'panel.mjs'), ...process.argv.slice(3)], { stdio: 'inherit' });
  process.exit(0);
}

// Studio: `llmgod workflow <sub>` library manager — handle before launch, then exit.
if (process.argv[2] === 'workflow') {
  const r = spawnSync(process.execPath, [join(llmgodDir, 'overdrive', 'workflow-cli.mjs'), ...process.argv.slice(3)], { stdio: 'inherit' });
  process.exit(r.status ?? (r.signal ? 1 : 0));
}

// Note: there used to be a "drift detection" block here that scanned
// ~/.local/share/claude/versions/ for a newer binary and silently re-patched.
// Removed because:
//   1. Windows users don't have a `versions/` directory at all (Anthropic's
//      Windows install doesn't follow that convention).
//   2. We patch out `claude update` (it would otherwise overwrite the bun
//      runtime under our launcher), so `versions/` no longer auto-grows
//      on a healthy llmgod install.
// In practice the block was reading a directory that never changes, but
// could *retract* a fresher version that install.sh just pulled from npm
// registry — putting users into a re-patch loop. Upgrades now go through
// the patched `claude update` → install.sh redirect, which always pulls
// the latest from npm.

// One-time migration: earlier wrapper versions set CLAUDE_CONFIG_DIR=~/.llmgod,
// which made Claude Code read/write ~/.llmgod/.claude.json instead of the
// native ~/.claude.json (the file holding MCP config, project history, session
// index). Move it back transparently on first run after upgrade.
const nativeClaudeJson = join(homedir(), '.claude.json');
const strayClaudeJson = join(llmgodDir, '.claude.json');
if (existsSync(strayClaudeJson) && !existsSync(nativeClaudeJson)) {
  try { renameSync(strayClaudeJson, nativeClaudeJson); } catch {}
}

const providerDir = llmgodDir;
const configFile = join(providerDir, 'provider.json');

const defaultConfig = {
  apiKey: '',
  baseURL: 'https://api.anthropic.com',
  model: '',
  smallModel: '',
  timeoutMs: 3000000,
};

let config = { ...defaultConfig };
if (existsSync(configFile)) {
  try {
    const raw = JSON.parse(readFileSync(configFile, 'utf8'));
    config = { ...defaultConfig, ...raw };
  } catch {}
} else {
  mkdirSync(providerDir, { recursive: true });
  writeFileSync(configFile, JSON.stringify(defaultConfig, null, 2) + '\n');
}

const hasProviderApiKey = !!config.apiKey;

if (hasProviderApiKey) {
  process.env.ANTHROPIC_API_KEY = config.apiKey;
  if (config.baseURL) process.env.ANTHROPIC_BASE_URL = config.baseURL;
  if (config.model) process.env.ANTHROPIC_MODEL = config.model;
  if (config.smallModel) process.env.ANTHROPIC_SMALL_FAST_MODEL = config.smallModel;
  if (config.baseURL && !/anthropic\.com/i.test(config.baseURL)) {
    process.env.ANTHROPIC_AUTH_TOKEN ??= config.apiKey;
  }
} else if (config.baseURL && config.baseURL !== defaultConfig.baseURL) {
  process.env.ANTHROPIC_BASE_URL ??= config.baseURL;
}

// Third-party Anthropic-compatible proxies (DeepSeek / OneAPI / Bedrock /
// vLLM / etc.) don't share Anthropic's server-side handling of
// x-anthropic-billing-header. That header carries a per-request `cch` field
// which Anthropic's own server excludes from prompt-cache key calculation
// (via cacheScope:null), but third-party proxies fold into the prefix hash —
// so the cached prefix changes every request and cache hit rate drops to
// zero. Auto-disable the header whenever baseURL points away from Anthropic.
// Users can force re-enable with CLAUDE_CODE_ATTRIBUTION_HEADER=1 if needed.
if (config.baseURL && !/anthropic\.com/i.test(config.baseURL)) {
  process.env.CLAUDE_CODE_ATTRIBUTION_HEADER ??= '0';
}

if (config.timeoutMs) {
  process.env.API_TIMEOUT_MS ??= String(config.timeoutMs);
}
process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC ??= '1';
process.env.DISABLE_INSTALLATION_CHECKS ??= '1';
// Use system ripgrep (extracted vendor rg path was build-time-baked; system
// rg is the most reliable fallback under Bun runtime).
process.env.USE_BUILTIN_RIPGREP ??= '1';

const featuresFile = join(providerDir, 'features.json');
if (!process.env.CLAUDE_INTERNAL_FC_OVERRIDES && existsSync(featuresFile)) {
  try {
    const raw = readFileSync(featuresFile, 'utf8');
    JSON.parse(raw);
    process.env.CLAUDE_INTERNAL_FC_OVERRIDES = raw;
  } catch {}
}

// OVERDRIVE: seed ~/.claude/settings.json defaults (never clobber existing keys):
//   - X-ray statusLine when the user has none
//   - ultracode mode on by default — xhigh effort + standing dynamic-workflow
//     orchestration; enableWorkflows keeps the workflow half on even on Pro
//     plans (where it otherwise defaults off). Both honour an explicit user
//     value: we only seed when the key is absent, never overwrite false.
try {
  const settingsPath = join(homedir(), '.claude', 'settings.json');
  let s = {};
  try { s = JSON.parse(readFileSync(settingsPath, 'utf8')); } catch {}
  let dirty = false;
  if ((config.xray?.statusLine ?? true) && !s.statusLine) {
    s.statusLine = { type: 'command', command: `${process.execPath} ${join(llmgodDir, 'overdrive', 'statusline.mjs')}` };
    dirty = true;
  }
  if (s.ultracode === undefined) { s.ultracode = true; dirty = true; }
  if (s.enableWorkflows === undefined) { s.enableWorkflows = true; dirty = true; }
  if (dirty) {
    mkdirSync(join(homedir(), '.claude'), { recursive: true });
    writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
  }
} catch {}

// OVERDRIVE: apply Limits Unchained env plan + install X-ray probe, then start the CLI.
(async () => {
  const importUrl = (p) => require('url').pathToFileURL(p).href;
  try {
    const { limitEnv } = await import(importUrl(join(llmgodDir, 'overdrive', 'limits-env.mjs')));
    const plan = limitEnv(config.limits || {}, process.env);
    for (const [k, v] of Object.entries(plan)) {
      if (k.startsWith('__unset_')) { delete process.env[k.slice(8)]; continue; }
      if (process.env[k] == null) process.env[k] = v;
    }
  } catch {}
  try {
    if ((config.xray?.enabled ?? true)) {
      const sid = process.env.LLMGOD_SESSION || (process.env.LLMGOD_SESSION = require('crypto').randomUUID());
      const { installProbe } = await import(importUrl(join(llmgodDir, 'overdrive', 'probe.mjs')));
      installProbe(config, llmgodDir, sid);
    }
  } catch {}
  try {
    if ((config.workflow?.library ?? true)) {
      const { seedLibrary } = await import(importUrl(join(llmgodDir, 'overdrive', 'workflow-library.mjs')));
      seedLibrary(join(homedir(), '.claude', 'workflows'), { existsSync, mkdirSync, writeFileSync });
    }
  } catch {}
  require('./cli.original.cjs');
})();
WRAPPER_EOF
chmod +x "$LLMGOD_DIR/cli.cjs"
info "Wrapper created (cli.cjs)"

# ─── Write universal patcher ───────────────────────────

cat > "$LLMGOD_DIR/patch.mjs" << 'PATCHER_EOF'
#!/usr/bin/env node
/**
 * Let's LLM Universal Patcher — 正则模式匹配, 跨版本兼容
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TARGET = join(__dirname, 'cli.original.cjs');
const BACKUP = TARGET + '.bak';

// ─── Regex-based patches (version-agnostic) ──────────────

// llmgod's own release version, stamped from the git tag at release time by
// release.yml (it replaces the __LLMGOD_SELF_VERSION__ token). On local/main
// installs the token is left unreplaced; normalize anything that doesn't look
// like a real version (leading digit) to '' so the brand patch stays inert.
let LLMGOD_SELF_VERSION = '__LLMGOD_SELF_VERSION__';
if (!/^\d/.test(LLMGOD_SELF_VERSION)) LLMGOD_SELF_VERSION = '';

const patches = [
  {
    name: 'USER_TYPE → ant',
    pattern: /function ([\w$]+)\(\)\{return"external"\}/g,
    replacer: (m, fn) => `function ${fn}(){return"ant"}`,
    sentinel: 'return"external"',
  },
  {
    name: 'GrowthBook env overrides',
    pattern: /function ([\w$]+)\(\)\{if\(!([\w$]+)\)\2=!0;return ([\w$]+)\}/g,
    replacer: (m, fn, flag, val) =>
      `function ${fn}(){if(!${flag}){${flag}=!0;try{let e=process.env.CLAUDE_INTERNAL_FC_OVERRIDES;if(e)${val}=JSON.parse(e)}catch(e){}}return ${val}}`,
    unique: true,  // must match exactly 1
  },
  {
    name: 'GrowthBook config overrides',
    pattern: /function ([\w$]+)\(\)\{return\}(function)/g,
    replacer: (m, fn, next) =>
      `function ${fn}(){return null}${next}`,
    selectIndex: 0,
    validate: (match, code) => {
      const pos = code.indexOf(match);
      const nearby = code.substring(Math.max(0, pos - 500), pos + 500);
      return nearby.includes('growthBook') || nearby.includes('GrowthBook') || nearby.includes('FeatureValue');
    },
  },
  {
    name: 'Agent Teams always enabled',
    pattern: /function ([\w$]+)\(\)\{if\(![\w$]+\(process\.env\.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\)&&![\w$]+\(\)\)return!1;if\(![\w$]+\("tengu_amber_flint",!0\)\)return!1;return!0\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Computer Use subscription bypass',
    pattern: /function ([\w$]+)\(\)\{let [\w$]+=[\w$]+\(\);return [\w$]+==="max"\|\|[\w$]+==="pro"\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Computer Use default enabled',
    pattern: /([\w$]+=)\{enabled:!1,pixelValidation/g,
    replacer: (m, prefix) => `${prefix}{enabled:!0,pixelValidation`,
  },
  {
    // v2.1.92+ shape: name:"ultraplan",get description(){...},argumentHint:"<prompt>",isEnabled:()=>fnRef()
    // Older shape  : name:"ultraplan",description:`...`,argumentHint:"<prompt>",isEnabled:()=>!1
    // The middle metadata block changed from a literal description to a getter,
    // and the gate switched from a literal !1 to a GrowthBook-flag-check function call.
    // Match both.
    name: 'Ultraplan enable',
    pattern: /(name:"ultraplan",[\s\S]{1,500}?argumentHint:"<prompt>",isEnabled:\(\)=>)(?:!1|[\w$]+\(\))/g,
    replacer: (m, prefix) => `${prefix}!0`,
    sentinel: 'name:"ultraplan"',
  },
  {
    // ≤v2.1.110: function X(){return Y("tengu_review_bughunter_config",null)?.enabled===!0}
    // v2.1.119+: function X(){return Y("tengu_review_bughunter_config",null)} — bare getter
    //            and the gate at function Z(){return X()?.enabled===!0} elsewhere.
    // v2.1.152+: same bare-getter shape, but the returned config object now also
    //            feeds OIH/ca/Tm4 helpers that read .cost_note / .duration_note /
    //            .model. Earlier replacer returned `{enabled:!0}` flat — that
    //            stripped those fields, and some downstream init path read .model
    //            then hung the boot before the trust dialog ever rendered
    //            (issue #86, observed on 2.1.152). Preserve the original config
    //            shape and only force-flip the enabled flag.
    name: 'Ultrareview enable',
    pattern: /function ([\w$]+)\(\)\{return ([\w$]+)\("tengu_review_bughunter_config",null\)(\?\.enabled===!0)?\}/g,
    replacer: (m, fn, getter, gate) =>
      gate
        ? `function ${fn}(){return!0}`
        : `function ${fn}(){let _r=${getter}("tengu_review_bughunter_config",null);return _r?{..._r,enabled:!0}:{enabled:!0}}`,
    sentinel: '"tengu_review_bughunter_config"',
  },
  {
    name: 'Computer Use gate bypass',
    pattern: /function ([\w$]+)\(\)\{return [\w$]+\(\)&&[\w$]+\(\)\.enabled\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    name: 'Voice Mode enable (bypass GrowthBook kill)',
    pattern: /function ([\w$]+)\(\)\{return![\w$]+\("tengu_amber_quartz_disabled",!1\)\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  {
    // v2.1.158+: provider gate refactored into helper function:
    //   function mw$(H){if(H==="firstParty"||H==="anthropicAws")return!0;return CH(process.env.CLAUDE_CODE_ENABLE_AUTO_MODE)}
    //   Called as: if(!mw$(q))return!1;  inside the auto-mode model gate.
    //   Lookahead ensures we only strip the call inside the auto-mode gate
    //   (the next 300 chars must contain !=="firstParty") and not unrelated
    //   if(!fn(x))return!1; patterns elsewhere.
    //   Not present in ≤v2.1.149 (provider gate was inline).
    name: 'Auto-mode unlock for third-party API (provider helper gate)',
    pattern: /if\(!([\w$]+)\(([\w$]+)\)\)return!1;(?=(?:(?!function\s).){0,300}!=="firstParty")/g,
    replacer: () => '',
    optional: true,
  },
  {
    // ≤v2.1.149: if(Y!=="firstParty"&&Y!=="anthropicAws")return!1;
    // v2.1.158+: same shape with model-condition suffix:
    //   if(q!=="firstParty"&&q!=="anthropicAws"&&($==="claude-opus-4-6"||…))return!1;
    //   [^;]* absorbs the optional &&(…) tail safely (no semicolons inside
    //   the if-condition).
    name: 'Auto-mode unlock for third-party API (inline gate)',
    pattern: /if\(([\w$]+)!=="firstParty"&&\1!=="anthropicAws"[^;]*\)return!1;/g,
    replacer: () => '',
    sentinel: '!=="firstParty"&&',
  },
  {
    // CLI subcommand registered via commander chain:
    //   .command("update").alias("upgrade").description("…").action(async()=>{…})
    // The original action's update path is broken under llmgod: detectInstallType()
    // returns "unknown" because the launcher hides our cli.cjs from upstream's
    // path heuristics, and the unknown-fallback branch on macOS overwrites
    // ~/.bun/bin/bun by extracting the bun runtime out of the new native binary
    // (preserving Apr-19-build mtime). That **silently downgrades** llmgod's
    // required Bun and crashes cli.original.cjs the next launch with
    // "Expected CommonJS module to have a function wrapper". On Windows the
    // same fallback writes the new binary somewhere our drift detection
    // doesn't scan, so the user sees "Successfully updated" but never gets
    // the new version.
    //
    // Redirect to llmgod's own self-update so the upgrade goes through
    // install.sh (re-extract + re-patch + re-launcher). Always pull the
    // latest install.sh from the release so users get patcher fixes too.
    // Escape hatch printed on every run: `install.sh --uninstall` restores
    // claude.orig and lets vanilla `claude update` work again.
    name: "Redirect `claude update` to llmgod self-update",
    pattern: /(\.command\("update"\)\.alias\("upgrade"\)\.description\("[^"]+"\)\.action\(async\(\)=>\{)/g,
    replacer: (m, prefix) => {
      // PowerShell 5.1's Invoke-WebRequest ignores HTTP_PROXY/HTTPS_PROXY env
      // (only reads IE system proxy). Read env explicitly and pass via -Proxy
      // so it works on both PS 5.1 and PS 7. Use Invoke-RestMethod (irm) not
      // Invoke-WebRequest (iwr): under -UseBasicParsing on PS 5.1, iwr's
      // .Content is byte[] not string, so `iex (iwr -useb ...).Content`
      // throws "Cannot convert System.Byte[] to System.String". irm always
      // returns string in both versions. -EncodedCommand bypasses CLI
      // arg-quoting; payload must be UTF-16LE base64.
      const psScript =
        "$p=if($env:HTTPS_PROXY){$env:HTTPS_PROXY}elseif($env:HTTP_PROXY){$env:HTTP_PROXY}else{$null};" +
        "$u='https://github.com/syntharea/llmgod/releases/latest/download/install.ps1';" +
        "if($p){iex(irm -Proxy $p $u)}else{iex(irm $u)}";
      const psB64 = Buffer.from(psScript, 'utf16le').toString('base64');
      return (
        prefix +
        `process.stderr.write("[llmgod] 'claude update' is handled by llmgod self-update.\\n[llmgod] To leave llmgod and use vanilla update: bash ~/.llmgod/install.sh --uninstall\\n[llmgod] Continuing now\\u2026\\n");` +
        `const _w=process.platform==='win32';` +
        `const _c=_w?['powershell','-NoProfile','-EncodedCommand','${psB64}']:['bash','-c','curl -fsSL https://github.com/syntharea/llmgod/releases/latest/download/install.sh | bash'];` +
        `const _r=require('child_process').spawnSync(_c[0],_c.slice(1),{stdio:'inherit'});` +
        `process.exit(_r.status||0);`
      );
    },
    sentinel: '.command("update").alias("upgrade")',
  },
  // ── 绿色主题 (patch 标识) ──

  {
    name: 'Logo + brand color → green (RGB dark)',
    pattern: /clawd_body:"rgb\(215,119,87\)"/g,
    replacer: () => 'clawd_body:"rgb(34,197,94)"',
  },
  {
    name: 'Logo + brand color → green (ANSI)',
    pattern: /clawd_body:"ansi:redBright"/g,
    replacer: () => 'clawd_body:"ansi:greenBright"',
  },
  {
    name: 'Theme claude color → green (dark)',
    pattern: /claude:"rgb\(215,119,87\)"/g,
    replacer: () => 'claude:"rgb(34,197,94)"',
  },
  {
    name: 'Theme claude color → green (light)',
    pattern: /claude:"rgb\(255,153,51\)"/g,
    replacer: () => 'claude:"rgb(22,163,74)"',
  },
  {
    name: 'Shimmer → green',
    pattern: /claudeShimmer:"rgb\(2[34]5,1[45]9,1[12]7\)"/g,
    replacer: () => 'claudeShimmer:"rgb(74,222,128)"',
  },
  {
    name: 'Shimmer light → green',
    pattern: /claudeShimmer:"rgb\(255,183,101\)"/g,
    replacer: () => 'claudeShimmer:"rgb(34,197,94)"',
  },
  // ── 品牌 → Let's LLM (仅替换可见 UI 文案; 不动 name:"claude-code" 与系统提示) ──
  {
    // Prepend llmgod's own version to the welcome-box brand line so it reads
    //   Let's LLM v<llmgod>-v<claude-code>   e.g.  Let's LLM v1.1.11-v2.1.170
    // Anchors on the inactive-coloured version token next to the box title.
    // MUST run before the "Claude Code" → "Let's LLM" title flips below: it
    // keeps the "Claude Code" literal in its output so those still match.
    // Inert when LLMGOD_SELF_VERSION is '' (local/non-release installs) and
    // idempotent (the rewritten `v…-v${x}` no longer matches `v${x}`).
    name: "Brand: prepend llmgod version to welcome box",
    pattern: /(\("Claude Code"\)\}\s*\$\{[\w$]+\("inactive",[\w$]+\)\()`v\$\{([\w$]+)\}`/g,
    replacer: (m, pre, pvar) =>
      LLMGOD_SELF_VERSION ? pre + '`v' + LLMGOD_SELF_VERSION + '-v${' + pvar + '}`' : m,
    optional: true,
  },
  {
    name: "Brand: header title → Let's LLM",
    pattern: /title:"Claude Code"/g,
    replacer: () => `title:"Let's LLM"`,
  },
  {
    name: "Brand: welcome banner → Let's LLM",
    pattern: /"Welcome to Claude Code"/g,
    replacer: () => `"Welcome to Let's LLM"`,
  },
  // ── 品牌 logo → letsllm 眼镜蛇/cobra (吉祥物四帧统一为静态; 单色随 clawd_body 变绿) ──
  {
    name: "Brand logo: mascot frames → letsllm cobra",
    pattern: /y9f=\{default:\{[^}]*\},"look-left":\{[^}]*\},"look-right":\{[^}]*\},"arms-up":\{[^}]*\}\}/g,
    replacer: () => 'y9f={default:{r1L:"▗▟",r1E:"█████",r1R:"▙▖",r2L:"▐█",r2R:"█▌"},"look-left":{r1L:"▗▟",r1E:"█████",r1R:"▙▖",r2L:"▐█",r2R:"█▌"},"look-right":{r1L:"▗▟",r1E:"█████",r1R:"▙▖",r2L:"▐█",r2R:"█▌"},"arms-up":{r1L:"▗▟",r1E:"█████",r1R:"▙▖",r2L:"▐█",r2R:"█▌"}}',
  },
  {
    name: "Brand logo: mascot row3 → letsllm cobra",
    pattern: /E9f=\{default:"[^"]*","look-left":"[^"]*","look-right":"[^"]*","arms-up":"[^"]*"\}/g,
    replacer: () => 'E9f={default:" ▜█████▛ ","look-left":" ▜█████▛ ","look-right":" ▜█████▛ ","arms-up":" ▜█████▛ "}',
  },
  {
    name: "Brand: welcome box title → Let's LLM",
    pattern: /bold:!0\},"Claude Code"/g,
    replacer: () => `bold:!0},"Let's LLM"`,
  },
  {
    name: "Brand logo: welcome box base row → cobra",
    pattern: /"\\u2598\\u2598 \\u259D\\u259D"/g,
    replacer: () => '"▜███▛"',
  },
  {
    // 第2行核心 5 格在原始压缩代码里硬编码为 5 个实心块 (clawd_background 反衬),
    // 接管它把中间两格挖成负空间缺角 ▟▙ → 眼镜蛇的双眼 (单色下只能靠"洞"造眼)。
    // 整行渲染: r2L"▐█" + "█▟▙██" + r2R"█▌" = ▐██▟▙███▌
    name: "Brand logo: mascot row2 core → cobra eyes (negative-space notches)",
    pattern: /backgroundColor:"clawd_background"\},"\\u2588\\u2588\\u2588\\u2588\\u2588"/g,
    replacer: () => 'backgroundColor:"clawd_background"},"█▟▙██"',
    sentinel: 'backgroundColor:"clawd_background"},"\\u2588\\u2588\\u2588\\u2588\\u2588"',
  },
  {
    // 第3行底座 ▜███▛ 在两个渲染路径 (y9f 欢迎框 / h9f "terminal" pose) 各出现一次;
    // 中间塞一个 ▼ 作蛇吻/下颌尖 → ▜█▼█▛。放在 base-row patch 之后, 保证任何版本都不残留 ▜███▛。
    name: "Brand logo: mascot snout → cobra ▼ (both render paths)",
    pattern: /▜███▛/g,
    replacer: () => '▜█▼█▛',
    sentinel: '▜███▛',
  },
  {
    name: "Brand: box border title (plain) → Let's LLM",
    pattern: /\("Claude Code"\)/g,
    replacer: () => `("Let's LLM")`,
  },
  {
    name: "Brand: box border title (padded) → Let's LLM",
    pattern: /\(" Claude Code "\)/g,
    replacer: () => `(" Let's LLM ")`,
  },
  {
    name: 'Hex brand color → green',
    pattern: /#da7756/g,
    replacer: () => '#22c55e',
  },

  // ── 限制移除 ──

  {
    name: 'Remove CYBER_RISK_INSTRUCTION',
    pattern: /([\w$]+)="IMPORTANT: Assist with authorized security testing[^"]*"/g,
    replacer: (m, varName) => `${varName}=""`,
    sentinel: 'Assist with authorized security testing',
  },
  {
    name: 'Remove URL generation restriction',
    pattern: /\n\$\{[\w$]+\}\nIMPORTANT: You must NEVER generate or guess URLs[^.]*\. You may use URLs provided by the user in their messages or local files\./g,
    replacer: () => '',
    sentinel: 'IMPORTANT: You must NEVER generate or guess URLs',
  },
  {
    name: 'Remove cautious actions section',
    // v2.1.88-~v2.1.122: function GSY(){return`# Executing actions...`}
    // v2.1.123+: function _j3(H){if(LE8(H)==="compact")return`# Executing...short`;return`# Executing...long`}
    pattern: /function ([\w$]+)\(([\w$]*)\)\{(?:if\([\s\S]{1,200}?\)return`# Executing actions with care\n\n[\s\S]*?`;)?return`# Executing actions with care\n\n[\s\S]*?`\}/g,
    replacer: (m, fn, arg) => `function ${fn}(${arg}){return\`\`}`,
    sentinel: '# Executing actions with care',
  },
  {
    name: 'Remove "Not logged in" notice',
    pattern: /Not logged in\. Run [\w ]+ to authenticate\./g,
    replacer: () => '',
    optional: true,
  },

  // ── 消息过滤 ──

  {
    // v2.1.88-~v2.1.91: fn()!=="ant"){if(q.attachment.type==="hook_additional_context"...
    // v2.1.92+        : fn()!=="ant"&&paY.has(q.attachment.type) — paY is an empty Set
    //                    in v2.1.110, so this filter is effectively a no-op; patch anyway
    //                    to guard against paY being populated in future versions.
    name: 'Attachment filter bypass',
    pattern: /([\w$]+)\(\)!=="ant"(&&[\w$]+\.has\([\w$]+\.attachment\.type\)|\)\{if\([\w$]+\.attachment\.type==="hook_additional_context")/g,
    replacer: (m) => m.replace(/([\w$]+)\(\)!=="ant"/, 'false'),
    optional: true,  // filter may be removed entirely in future versions
  },
  {
    // Legacy (≤v2.1.91) ternary form: fn()!=="ant"?tRY(_,sRY(K)):K
    name: 'Message list filter bypass (legacy ternary)',
    pattern: /([\w$]+)\(\)!=="ant"\?([\w$]+)\(([\w$]+),([\w$]+)\(([\w$]+)\)\):([\w$]+)/g,
    replacer: (m, fn, tRY, underscore, sRY, K, fallback) => fallback,
    optional: true,  // removed in v2.1.92+
  },
  {
    // v2.1.92+ (s_8): if(fn()==="ant")return _;let z=...;return FaY(_,z)
    // Flip the guard so non-ant users also return the pre-filtered list.
    name: 'Message list filter bypass (s_8 form)',
    pattern: /if\(([\w$]+)\(\)==="ant"\)return ([\w$]+);let ([\w$]+)=([\w$]+) instanceof Set\?\4:([\w$]+)\(\4\);return ([\w$]+)\(\2,\3\)/g,
    replacer: (m, fn, ret) => `return ${ret}`,
    optional: true,  // legacy versions had a ternary instead
  },
  {
    // Shell-integration generator (iT6 in v2.1.140, was Wa1 in older versions)
    // emits a zsh/bash function that calls the native claude binary with
    // ARGV0=ugrep|rg|... for multitool dispatch. After llmgod installs, the
    // baked path points at our shell-script launcher — but shell scripts
    // CANNOT preserve argv[0] (kernel shebang re-exec overwrites it, and zsh
    // additionally refuses to export ARGV0 as env). The shell function then
    // fails because bun receives e.g. -G and errors with "Invalid Argument".
    //
    // Fix: redirect the baked path to claude.orig (the native binary backup
    // llmgod creates at install time). Then the multitool dispatch reaches
    // a real binary that honors argv[0]. See issue #82.
    //
    // Generator shape across versions:
    //   v2.1.88 (Wa1):  let Y=E4([_]),...  ← _ is the claude binary path, no in-function compute
    //   v2.1.140 (iT6): let ...,z=FJ$.join(Le(),A?"claude.exe":"claude"),Y=A?rL(z):z,...
    //                   ← path computed inside via join(versionsDir, "claude[.exe]")
    // Anchor on the join(...) ternary form unique to the generator — the
    // bare "claude.exe":"claude" string also appears in u18() (basename
    // helper) but never inside a path.join(), so this regex hits exactly the
    // shell-integration generator and nothing else.
    name: 'Shell integration → claude.orig (multitool dispatch fix)',
    pattern: /([\w$]+\.join\([\w$]+\(\),[\w$]+\?)"claude\.exe":"claude"(\))/g,
    replacer: (m, prefix, suffix) => `${prefix}"claude.orig.exe":"claude.orig"${suffix}`,
    sentinel: '?"claude.exe":"claude")',
    optional: true,  // v2.1.88-era bundles compute the path differently
  },
  // ─── OVERDRIVE L3 limit patches (env-gated; inert unless opted in) ───
  {
    // Parallel-agent slot cap: Math.min(16,Math.max(2,H-2)). Inert unless
    // LLMGOD_MAX_CONCURRENCY is set (unset → |0||16 → original 16). Confirmed
    // against real cli.original.cjs (exactly 1 match, idempotent).
    name: 'Concurrency: parallel-agent slot cap',
    pattern: /Math\.min\(16,([^)]+)\)/g,
    replacer: (m, rest) => `Math.min((globalThis.process?.env?.LLMGOD_MAX_CONCURRENCY|0||16),${rest})`,
    sentinel: 'Math.min(16,',
    optional: true,
  },
  {
    // Client model-id allowlist: if($!=="claude-..."&&...)return!1. Appends an
    // env guard so the gate is bypassed ONLY when LLMGOD_ALLOW_ANY_MODEL is set
    // (limits.modelAllowlist). Confirmed against real cli.original.cjs.
    name: 'Model allowlist: strip client model-id gate',
    pattern: /if\((([\w$]+)!=="claude-(?:[\w.-]+)"(?:&&\2!=="claude-[\w.-]+")*)\)return!1;/g,
    replacer: (m, cond) => `if((${cond})&&!globalThis.process?.env?.LLMGOD_ALLOW_ANY_MODEL)return!1;`,
    sentinel: '!=="claude-opus-4-',
    optional: true,
  },
];

// ─── Main ─────────────────────────────────────────────────

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const verify = args.includes('--verify');
const revert = args.includes('--revert');

if (revert) {
  if (!existsSync(BACKUP)) { console.error('❌ No backup found'); process.exit(1); }
  copyFileSync(BACKUP, TARGET);
  console.log('✅ Reverted from backup');
  process.exit(0);
}

if (!existsSync(TARGET)) {
  console.error('❌ Target not found:', TARGET);
  process.exit(1);
}

let code = readFileSync(TARGET, 'utf8');
const origSize = code.length;

// Extract version
const verMatch = code.match(/Version:\s*([\d.]+)/);
const version = verMatch ? verMatch[1] : 'unknown';

console.log(`\n${'═'.repeat(55)}`);
console.log(`  Let's LLM (universal)`);
console.log(`  Target: cli.original.cjs (v${version})`);
console.log(`  Mode: ${dryRun ? 'DRY RUN' : verify ? 'VERIFY' : 'APPLY'}`);
console.log(`${'═'.repeat(55)}\n`);

let applied = 0, skipped = 0, failed = 0;

for (const p of patches) {
  const matches = [...code.matchAll(p.pattern)];
  let relevant = matches;

  // Filter by validation if provided
  if (p.validate) {
    relevant = matches.filter(m => p.validate(m[0], code));
  }

  // Select specific match index
  if (p.selectIndex !== undefined) {
    relevant = relevant.length > p.selectIndex ? [relevant[p.selectIndex]] : [];
  }

  // Uniqueness check — skip when 0 so the sentinel / already-applied
  // fallthrough can handle it; only fail on >1 (ambiguous).
  if (p.unique && relevant.length > 1) {
    console.log(`  ⚠️  ${p.name} — ${relevant.length} matches, skipping (need 1)`);
    failed++;
    continue;
  }

  if (relevant.length === 0) {
    if (p.optional) {
      console.log(`  ⏭  ${p.name} (not present in this version)`);
      skipped++;
      continue;
    }
    // If the patch declares a sentinel (a string that must NOT exist in a
    // fully-patched file), use it to tell "already applied" apart from
    // "regex is stale and silently missed the target".
    if (p.sentinel !== undefined) {
      const sentinels = Array.isArray(p.sentinel) ? p.sentinel : [p.sentinel];
      const stillPresent = sentinels.filter((s) => code.includes(s));
      if (stillPresent.length > 0) {
        console.log(`  ❌ ${p.name} — regex stale, sentinel still in source: ${stillPresent.map((s) => JSON.stringify(s)).join(', ')}`);
        failed++;
        continue;
      }
      console.log(`  ✅ ${p.name} (already applied, sentinel absent)`);
      applied++;
      continue;
    }
    console.log(`  ⚠️  ${p.name} (0 matches, no sentinel — cannot verify)`);
    skipped++;
    continue;
  }

  if (verify) {
    console.log(`  ⬚  ${p.name} — ${relevant.length} match(es), not yet applied`);
    skipped++;
    continue;
  }

  // Apply patch
  let count = 0;
  for (const m of relevant) {
    const replacement = p.replacer(m[0], ...m.slice(1));
    if (replacement !== m[0]) {
      if (!dryRun) {
        // Use function-form replace: String.prototype.replace with a string
        // replacement interprets $$ as literal $, $1/$& as backreferences.
        // Minified upstream identifiers like `a$$` would silently become `a$`
        // and break every caller referencing the original name. Function form
        // is opaque to the parser. (issue #86)
        code = code.replace(m[0], () => replacement);
      }
      count++;
    }
  }

  if (count > 0) {
    console.log(`  ✅ ${p.name} (${count} replacement${count > 1 ? 's' : ''})`);
    applied++;
  } else {
    console.log(`  ⏭  ${p.name} (no change needed)`);
    skipped++;
  }
}

console.log(`\n${'─'.repeat(55)}`);
console.log(`  Result: ${applied} applied, ${skipped} skipped, ${failed} failed`);

if (!dryRun && !verify && applied > 0) {
  if (!existsSync(BACKUP)) {
    copyFileSync(TARGET, BACKUP);
    console.log(`  📦 Backup: ${BACKUP}`);
  }
  writeFileSync(TARGET, code, 'utf8');
  const diff = code.length - origSize;
  console.log(`  📝 Written: cli.original.cjs (${diff >= 0 ? '+' : ''}${diff} bytes)`);
}

console.log(`${'═'.repeat(55)}\n`);
PATCHER_EOF
info "Patcher created (patch.mjs)"

# ─── Apply patches ─────────────────────────────────────

dim "Applying patches ..."
node "$LLMGOD_DIR/patch.mjs" 2>&1 | while IFS= read -r line; do echo "  $line"; done

# ─── Create default configs ───────────────────────────

if [ ! -f "$LLMGOD_DIR/features.json" ]; then
  cat > "$LLMGOD_DIR/features.json" << 'FEATURES_EOF'
{
  "tengu_harbor": true,
  "tengu_session_memory": true,
  "tengu_amber_flint": true,
  "tengu_auto_background_agents": true,
  "tengu_destructive_command_warning": true,
  "tengu_immediate_model_command": true,
  "tengu_desktop_upsell": false,
  "tengu_malort_pedway": {"enabled": true},
  "tengu_amber_quartz_disabled": false,
  "tengu_prompt_cache_1h_config": {"allowlist": ["*"]}
}
FEATURES_EOF
  info "Default features.json created"
fi

# ─── Sanity check: ensure user's Bun can actually load cli.original.cjs ──
# Anthropic builds the native binary with a bleeding-edge Bun build (e.g.
# 1.3.14 while stable still ships 1.3.13). Older Bun crashes loading the
# extracted cli.original.cjs with "Expected CommonJS module to have a
# function wrapper". Detect this BEFORE we install the launcher — better
# to fail loudly than to leave the user with a launcher that panics on
# first invocation.

dim "Verifying Bun can load patched cli.original.cjs ..."
sanity_out=$("$BUN_BIN" "$LLMGOD_DIR/cli.cjs" --version 2>&1 || true)
if echo "$sanity_out" | grep -q "Expected CommonJS module to have a function wrapper"; then
  echo ""
  warn "Bun $($BUN_BIN --version) cannot load Anthropic's cli.original.cjs."
  warn ""
  warn "  Anthropic builds with Bun's canary channel (currently ~1.3.14), while"
  warn "  bun.sh's main download is on stable (currently 1.3.13). The canary build"
  warn "  is NOT visible on bun.sh's download page — it lives on GitHub Releases"
  warn "  and is reachable only via 'bun upgrade --canary'."
  warn ""
  warn "  If your bun is from bun.sh:"
  warn "    bun upgrade --canary"
  warn ""
  warn "  If your bun is from a package manager (brew/apt/scoop) where the binary"
  warn "  is behind a shim and refuses to self-replace ('bun upgrade' silently"
  warn "  hangs or no-ops):"
  warn "    <pkg-manager> uninstall bun"
  warn "    curl -fsSL https://bun.sh/install | bash"
  warn "    bun upgrade --canary"
  warn ""
  warn "  Then re-run install.sh — this sanity check will pass."
  exit 1
fi
info "Bun loads cli.original.cjs"

# ─── Replace claude command ───────────────────────────

LAUNCHER_CONTENT="#!/bin/bash
# llmgod launcher
LLMGOD_CLI=\"$LLMGOD_DIR/cli.cjs\"
BUN_BIN=\"$BUN_BIN\"
if [ ! -f \"\$LLMGOD_CLI\" ]; then
  echo \"llmgod: installation at $LLMGOD_DIR is missing (cli.cjs not found)\" >&2
  echo \"llmgod: reinstall via  curl -fsSL https://github.com/syntharea/llmgod/releases/latest/download/install.sh | bash\" >&2
  echo \"llmgod: or remove this launcher:  rm \\\"\$0\\\"\" >&2
  exit 127
fi
if [ ! -x \"\$BUN_BIN\" ]; then
  if command -v bun >/dev/null 2>&1; then BUN_BIN=\"\$(command -v bun)\"; fi
fi
if [ ! -x \"\$BUN_BIN\" ]; then
  echo \"llmgod: bun runtime not found at \$BUN_BIN\" >&2
  echo \"llmgod: install bun  curl -fsSL https://bun.sh/install | bash\" >&2
  exit 127
fi
exec \"\$BUN_BIN\" \"\$LLMGOD_CLI\" \"\$@\""

# Detect where claude is actually installed (supports native, npm, pnpm, yarn).
# `command -v` is a POSIX builtin (works even on minimal images that no
# longer ship `which`); `|| true` keeps a clean miss from tripping
# `set -e` via the assignment's exit status under bash 5+.
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  # No claude in PATH — use default location
  CLAUDE_BIN="$BIN_DIR/claude"
  dim "No existing claude found, installing to $BIN_DIR"
fi
CLAUDE_DIR=$(dirname "$CLAUDE_BIN")

# Back up original claude (only once)
if [ ! -e "$CLAUDE_BIN.orig" ]; then
  if [ -L "$CLAUDE_BIN" ]; then
    # Symlink (native install) — preserve target
    NATIVE_BIN="$(readlink "$CLAUDE_BIN")"
    ln -sf "$NATIVE_BIN" "$CLAUDE_BIN.orig"
    info "Original claude backed up → claude.orig (→ $NATIVE_BIN)"
  elif [ -f "$CLAUDE_BIN" ] && file "$CLAUDE_BIN" 2>/dev/null | grep -q "Mach-O\|ELF\|script"; then
    # Binary or script (pnpm/npm global install)
    cp "$CLAUDE_BIN" "$CLAUDE_BIN.orig"
    info "Original claude backed up → claude.orig"
  else
    # Try versions dir as fallback
    VERSIONS_DIR="$HOME/.local/share/claude/versions"
    if [ -d "$VERSIONS_DIR" ]; then
      NATIVE_BIN="$(ls -t "$VERSIONS_DIR"/* 2>/dev/null | while read f; do
        file "$f" 2>/dev/null | grep -q "Mach-O\|ELF" && echo "$f" && break
      done)" || true
      if [ -n "$NATIVE_BIN" ]; then
        ln -sf "$NATIVE_BIN" "$CLAUDE_BIN.orig"
        info "Original claude backed up → claude.orig (→ $NATIVE_BIN)"
      fi
    fi
  fi
fi

# Write launcher to the SAME directory where claude was found.
# CRITICAL: `echo > $f` follows symlinks — if $CLAUDE_BIN is a symlink
# (e.g. official ~/.local/bin/claude → ~/.local/share/claude/versions/X)
# we'd write our launcher into the real binary and destroy it. Always
# remove the existing entry first so we write a fresh regular file.
write_launcher() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  rm -f "$target"
  printf '%s\n' "$LAUNCHER_CONTENT" > "$target"
  chmod +x "$target"
}

write_launcher "$CLAUDE_BIN"
info "Command 'claude' → patched ($CLAUDE_BIN)"

# Also install to ~/.local/bin if claude was elsewhere (ensures PATH consistency)
if [ "$CLAUDE_DIR" != "$BIN_DIR" ]; then
  write_launcher "$BIN_DIR/claude"
  dim "Also installed to $BIN_DIR/claude"
fi

# Always expose an unambiguous `llmgod` alias alongside the `claude` override.
# Useful when:
#  - Windows .exe overshadows our .cmd (llmgod has no .exe competitor)
#  - User wants explicit "patched" intent
#  - User restored claude.orig via uninstall but still wants the patched one
write_launcher "$BIN_DIR/llmgod"
info "Command 'llmgod' → patched ($BIN_DIR/llmgod)"

# ─── Check PATH ───────────────────────────────────────

if ! echo "$PATH" | grep -q "$CLAUDE_DIR" && ! echo "$PATH" | grep -q "$BIN_DIR"; then
  # Detect shell config file
  case "$(basename "$SHELL")" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac
  echo ""
  warn "$BIN_DIR is not in PATH. Run:"
  dim "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $SHELL_RC && source $SHELL_RC"
fi

# ─── Flush shell cache ────────────────────────────────

hash -r 2>/dev/null

# ─── Done ─────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}${GREEN}Let's LLM installed!${NC}"
echo ""
dim "  claude            — Start patched Claude Code (green logo)"
dim "  claude.orig       — Run original unpatched Claude Code"
echo ""
dim "  Updates: 'claude update' is patched to route through this installer."
dim "  Just run it as usual — pulls latest Anthropic release + re-patches"
dim "  in one step. To leave llmgod and use vanilla update:"
dim "    bash ~/.llmgod/install.sh --uninstall"
echo ""
warn "  If 'claude' still runs the old version, restart your terminal or run: hash -r"
echo ""
dim "  Config: ~/.llmgod/provider.json"
dim "  Flags:  ~/.llmgod/features.json"
echo ""
dim "  If 'claude' panics with 'Expected CommonJS module to have a function wrapper',"
dim "  your Bun lags Anthropic's embedded Bun. Upgrade with one of:"
dim "    bun upgrade --canary           (if installed via curl/install.sh)"
dim "    scoop update bun               (scoop — may lag stable)"
dim "    brew upgrade bun               (homebrew)"
echo ""
