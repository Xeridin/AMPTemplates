#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${1:-}"
ROOT_DIR="${2:-}"

if [[ -z "$BASE_DIR" ]]; then
  echo "Usage: install-dsp-nebula.sh <FullBaseDir> [FullRootDir]" >&2
  exit 64
fi

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
mkdir -p BepInEx/plugins

BEPINEX_URL="https://thunderstore.io/package/download/xiaoye97/BepInEx/5.4.17/"
NEBULA_API_URL="https://thunderstore.io/package/download/nebula/NebulaMultiplayerModApi/2.1.0/"
NEBULA_MOD_URL="https://thunderstore.io/package/download/nebula/NebulaMultiplayerMod/0.9.16/"

download() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$output" <<'PY'
import sys
import urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  else
    echo "No downloader found. Install curl, wget, or python3." >&2
    exit 127
  fi
}

extract_zip() {
  local zipfile="$1"
  local dest="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$zipfile" -d "$dest"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$zipfile" "$dest" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  else
    echo "No zip extractor found. Install unzip or python3." >&2
    exit 127
  fi
}

install_bepinex() {
  local tmp="$1/bepinex"
  mkdir -p "$tmp"
  download "$BEPINEX_URL" "$tmp/bepinex.zip"
  extract_zip "$tmp/bepinex.zip" "$tmp/extract"

  if [[ -d "$tmp/extract/BepInExPack" ]]; then
    cp -a "$tmp/extract/BepInExPack/." "$BASE_DIR/"
  else
    cp -a "$tmp/extract/." "$BASE_DIR/"
  fi
}

install_plugin_pack() {
  local name="$1"
  local url="$2"
  local tmp="$3/$name"
  mkdir -p "$tmp"

  download "$url" "$tmp/$name.zip"
  extract_zip "$tmp/$name.zip" "$tmp/extract"

  if [[ -d "$tmp/extract/plugins" ]]; then
    cp -a "$tmp/extract/plugins/." "$BASE_DIR/BepInEx/plugins/"
  elif [[ -d "$tmp/extract/BepInEx/plugins" ]]; then
    cp -a "$tmp/extract/BepInEx/plugins/." "$BASE_DIR/BepInEx/plugins/"
  else
    echo "Could not find plugins directory in $name package." >&2
    find "$tmp/extract" -maxdepth 3 -type d -print >&2 || true
    exit 65
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Installing BepInEx..."
install_bepinex "$TMP_DIR"

echo "Installing Nebula Multiplayer Mod API..."
install_plugin_pack "nebula-api" "$NEBULA_API_URL" "$TMP_DIR"

echo "Installing Nebula Multiplayer Mod..."
install_plugin_pack "nebula-mod" "$NEBULA_MOD_URL" "$TMP_DIR"

if [[ -n "$ROOT_DIR" ]]; then
  export WINEPREFIX="${ROOT_DIR}.wine"
  export WINEARCH="win64"
  export WINEDEBUG="-all"

  if command -v wineboot >/dev/null 2>&1; then
    echo "Initializing Wine prefix at $WINEPREFIX..."
    wineboot --init
  else
    echo "wineboot not found; skipping Wine prefix initialization. Use AMP's wine-stable container or install Wine on the host."
  fi
fi

echo "DSP Nebula install/update completed."
