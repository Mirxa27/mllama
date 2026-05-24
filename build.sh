#!/usr/bin/env bash
# Build script for Mllama macOS app.
#
# Compiles all .swift sources in src/ and src/Views/ into a single Mach-O
# binary, then installs it into Mllama.app/Contents/MacOS/Mllama. Resources
# (llama-server, whisper-cli, sd-server, ffmpeg) are expected to already be
# present under Mllama.app/Contents/Resources/.
#
# Usage:
#   ./build.sh                  # debug build (faster compile, larger binary)
#   ./build.sh release          # optimized release build
#   ./build.sh release --run    # build and launch
#
# Requirements:
#   - Xcode 15+ command line tools (Swift 5.9 or newer)
#   - macOS 13+ SDK
set -euo pipefail

cd "$(dirname "$0")"

# ----- config -----
APP_NAME="Mllama"
APP_BUNDLE="${APP_NAME}.app"
APP_BIN="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
SRC_DIR="src"
DEPLOYMENT_TARGET="13.0"

# ----- args -----
MODE="${1:-debug}"
shift || true
RUN=0
for a in "$@"; do
  case "$a" in
    --run) RUN=1 ;;
  esac
done

# ----- gather sources -----
if [ ! -d "${SRC_DIR}" ]; then
  echo "error: ${SRC_DIR}/ not found. Run from the directory containing Mllama.app and src/." >&2
  exit 1
fi

# Compile every .swift file except the icongen helper (which has its own @main).
SWIFT_FILES=$(find "${SRC_DIR}" -name "*.swift" -not -name "icongen.swift" | sort)

if [ -z "${SWIFT_FILES}" ]; then
  echo "error: no .swift files found under ${SRC_DIR}/" >&2
  exit 1
fi

echo "Compiling $(echo "${SWIFT_FILES}" | wc -l | tr -d ' ') Swift files into ${APP_BIN}…"

# ----- swiftc flags -----
COMMON_FLAGS=(
  -target "arm64-apple-macos${DEPLOYMENT_TARGET}"
  -sdk "$(xcrun --show-sdk-path --sdk macosx)"
  -framework SwiftUI
  -framework AppKit
  -framework AVFoundation
  -framework AVKit
  -framework Speech
  -framework CoreImage
  -framework UniformTypeIdentifiers
  -framework Foundation
  -parse-as-library
  -module-name "${APP_NAME}"
)

case "${MODE}" in
  release)
    OPT_FLAGS=(-O -whole-module-optimization)
    ;;
  debug|*)
    OPT_FLAGS=(-Onone -g)
    ;;
esac

# Ensure destination directory exists.
mkdir -p "${APP_BUNDLE}/Contents/MacOS"

# Build into a temp file first so a failed compile doesn't trash the running app.
TMP_OUT="$(mktemp -t Mllama.XXXXXX)"
trap 'rm -f "${TMP_OUT}"' EXIT

# shellcheck disable=SC2086
xcrun swiftc "${COMMON_FLAGS[@]}" "${OPT_FLAGS[@]}" \
  -o "${TMP_OUT}" \
  ${SWIFT_FILES}

# Stamp the binary with rpath so embedded dylibs (libllama, etc.) load.
xcrun install_name_tool -add_rpath "@executable_path/../Resources/bin" "${TMP_OUT}" 2>/dev/null || true

# Ad-hoc sign (required on Apple Silicon to satisfy the runtime).
xcrun codesign --force --sign - "${TMP_OUT}" >/dev/null

mv "${TMP_OUT}" "${APP_BIN}"
chmod +x "${APP_BIN}"
trap - EXIT

# Print resulting binary size.
SIZE=$(stat -f%z "${APP_BIN}" 2>/dev/null || stat -c%s "${APP_BIN}" 2>/dev/null || echo "?")
echo "✓ Built ${APP_BIN} (${SIZE} bytes, mode=${MODE})"

# Quick sanity check on bundled binaries.
echo ""
echo "Bundled resources:"
for path in \
  "${APP_BUNDLE}/Contents/Resources/bin/llama-server" \
  "${APP_BUNDLE}/Contents/Resources/whisper/whisper-cli" \
  "${APP_BUNDLE}/Contents/Resources/bin/sd-server" \
  "${APP_BUNDLE}/Contents/Resources/bin/sd-cli" \
  "${APP_BUNDLE}/Contents/Resources/bin/ffmpeg"
do
  if [ -x "${path}" ]; then
    echo "  ✓ $(basename "${path}")"
  else
    echo "  · missing: ${path#${APP_BUNDLE}/Contents/Resources/}"
  fi
done

echo ""
echo "Optional next steps if missing resources:"
echo "  • sd-server / sd-cli — build from https://github.com/leejet/stable-diffusion.cpp"
echo "      git clone --recursive https://github.com/leejet/stable-diffusion.cpp"
echo "      cd stable-diffusion.cpp && mkdir build && cd build"
echo "      cmake .. -DSD_METAL=ON -DSD_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release"
echo "      cmake --build . --config Release -j"
echo "      cp bin/sd-server bin/sd-cli ../../${APP_BUNDLE}/Contents/Resources/bin/"
echo "  • ffmpeg — \`brew install ffmpeg\` (sd-cli wrapper will find it automatically on PATH)"

if [ "${RUN}" = "1" ]; then
  echo ""
  echo "Launching app…"
  open "${APP_BUNDLE}"
fi
