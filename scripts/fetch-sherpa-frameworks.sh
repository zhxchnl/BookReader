#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/SherpaOnnx/Frameworks"
VERSION="1.13.2"
BASE="https://github.com/willwade/sherpa-onnx-spm/releases/download/${VERSION}"

mkdir -p "$DEST"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

download_and_extract() {
  local name="$1"
  local zip="$tmpdir/${name}.zip"
  echo "Downloading ${name}.xcframework..."
  curl -L --fail -o "$zip" "${BASE}/${name}.xcframework.zip"
  rm -rf "$DEST/${name}.xcframework"
  unzip -q "$zip" -d "$DEST"
}

download_and_extract "onnxruntime"
download_and_extract "sherpa-onnx"

echo "SherpaOnnx frameworks installed at: $DEST"
