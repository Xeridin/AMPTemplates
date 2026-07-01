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

THUNDERSTORE_API="https://thunderstore.io/c/dyson-sphere-program/api/v1/package/"
ROOT_PACKAGE_NAMESPACE="nebula"
ROOT_PACKAGE_NAME="NebulaMultiplayerMod"

declare -A INSTALLED_PACKAGES

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

find_package_in_index() {
  local index_file="$1"
  local namespace="$2"
  local package="$3"
  local output_file="$4"
  python3 - "$index_file" "$namespace" "$package" "$output_file" <<'PY'
import json
import sys

index_file, namespace, package, output_file = sys.argv[1:5]
with open(index_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

match = None
for item in data:
    if item.get('owner') == namespace and item.get('name') == package:
        match = item
        break

if match is None:
    raise SystemExit(f'Package not found in Thunderstore index: {namespace}/{package}')

versions = match.get('versions') or []
if not versions:
    raise SystemExit(f'Package has no versions: {namespace}/{package}')

version = versions[0]
with open(output_file, 'w', encoding='utf-8') as out:
    print('download_url=' + version['download_url'], file=out)
    print('version_number=' + version.get('version_number', ''), file=out)
    for dep in version.get('dependencies') or []:
        print('dependency=' + dep, file=out)
PY
}

split_dependency() {
  local dep="$1"
  python3 - "$dep" <<'PY'
import sys
s = sys.argv[1]
parts = s.rsplit('-', 1)
if len(parts) != 2:
    raise SystemExit(f'Invalid dependency string: {s}')
left, version = parts
parts2 = left.split('-', 1)
if len(parts2) != 2:
    raise SystemExit(f'Invalid dependency string: {s}')
print(parts2[0])
print(parts2[1])
print(version)
PY
}

copy_package_payload() {
  local extract_dir="$1"
  local package_label="$2"

  if [[ -d "$extract_dir/BepInExPack" ]]; then
    echo "Installing BepInEx pack from $package_label"
    cp -a "$extract_dir/BepInExPack/." "$BASE_DIR/"
    return
  fi

  if [[ -d "$extract_dir/BepInEx/plugins" ]]; then
    echo "Installing BepInEx plugins from $package_label"
    cp -a "$extract_dir/BepInEx/plugins/." "$BASE_DIR/BepInEx/plugins/"
  elif [[ -d "$extract_dir/plugins" ]]; then
    echo "Installing plugins from $package_label"
    cp -a "$extract_dir/plugins/." "$BASE_DIR/BepInEx/plugins/"
  else
    mapfile -t payload_files < <(find "$extract_dir" -type f \
      ! -iname 'manifest.json' \
      ! -iname 'icon.png' \
      ! -iname 'README.md' \
      ! -iname 'CHANGELOG.md' \
      ! -iname '*.txt' \
      ! -iname '*.md')

    if (( ${#payload_files[@]} > 0 )); then
      echo "No plugins directory found in $package_label; copying payload files directly into BepInEx/plugins."
      for file in "${payload_files[@]}"; do
        cp -a "$file" "$BASE_DIR/BepInEx/plugins/"
      done
    fi
  fi

  if [[ -d "$extract_dir/BepInEx/config" ]]; then
    mkdir -p "$BASE_DIR/BepInEx/config"
    cp -a "$extract_dir/BepInEx/config/." "$BASE_DIR/BepInEx/config/"
  fi

  if [[ -d "$extract_dir/patchers" ]]; then
    mkdir -p "$BASE_DIR/BepInEx/patchers"
    cp -a "$extract_dir/patchers/." "$BASE_DIR/BepInEx/patchers/"
  fi

  if [[ -d "$extract_dir/BepInEx/patchers" ]]; then
    mkdir -p "$BASE_DIR/BepInEx/patchers"
    cp -a "$extract_dir/BepInEx/patchers/." "$BASE_DIR/BepInEx/patchers/"
  fi
}

install_package_latest() {
  local namespace="$1"
  local package="$2"
  local key="$namespace-$package"

  if [[ -n "${INSTALLED_PACKAGES[$key]:-}" ]]; then
    return
  fi
  INSTALLED_PACKAGES[$key]=1

  local pkg_tmp="$TMP_DIR/$key"
  mkdir -p "$pkg_tmp"

  echo "Resolving Thunderstore package $namespace/$package..."
  find_package_in_index "$PACKAGE_INDEX" "$namespace" "$package" "$pkg_tmp/package.env"

  local download_url=""
  local version_number=""
  mapfile -t dependencies < <(awk -F= '/^dependency=/{print $2}' "$pkg_tmp/package.env")
  download_url="$(awk -F= '/^download_url=/{print $2; exit}' "$pkg_tmp/package.env")"
  version_number="$(awk -F= '/^version_number=/{print $2; exit}' "$pkg_tmp/package.env")"

  for dep in "${dependencies[@]}"; do
    mapfile -t dep_parts < <(split_dependency "$dep")
    local dep_namespace="${dep_parts[0]}"
    local dep_package="${dep_parts[1]}"
    install_package_latest "$dep_namespace" "$dep_package"
  done

  echo "Installing $namespace/$package $version_number..."
  download "$download_url" "$pkg_tmp/package.zip"
  extract_zip "$pkg_tmp/package.zip" "$pkg_tmp/extract"
  copy_package_payload "$pkg_tmp/extract" "$namespace/$package $version_number"
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for Thunderstore API parsing." >&2
  exit 127
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PACKAGE_INDEX="$TMP_DIR/thunderstore-packages.json"
echo "Downloading Thunderstore Dyson Sphere Program package index..."
download "$THUNDERSTORE_API" "$PACKAGE_INDEX"

echo "Installing latest Nebula Multiplayer Mod and dependencies from Thunderstore..."
install_package_latest "$ROOT_PACKAGE_NAMESPACE" "$ROOT_PACKAGE_NAME"

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
