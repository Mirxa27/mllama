#!/usr/bin/env bash
# Package Mllama.app into a distributable DMG.
#
# Output: dist/Mllama-<version>-arm64.dmg
#
# Usage:
#   ./package.sh                # production: builds release, strips, codesigns, makes DMG
#   ./package.sh --skip-build   # use existing Mllama.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mllama"
APP_BUNDLE="${APP_NAME}.app"
DIST_DIR="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || echo '2.4.0')"
ARCH="$(uname -m)"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
STAGE_DIR="${DIST_DIR}/stage"

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
  esac
done

# ---------- 1. Build ----------
if [ $SKIP_BUILD -eq 0 ]; then
  echo "==> Release build"
  ./build.sh release
fi

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "error: ${APP_BUNDLE} not found" >&2
  exit 1
fi

# ---------- 2. Strip + codesign ----------
echo "==> Stripping symbols"
xcrun strip -rSTx "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "==> Ad-hoc codesign"
# The bundled tools (llama-server, whisper-cli, dylibs) need to be signed
# too, in dependency order: dylibs first, then executables.
find "${APP_BUNDLE}/Contents/Resources" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 \
  | xargs -0 -n1 codesign --force --sign - --timestamp=none 2>/dev/null || true
find "${APP_BUNDLE}/Contents/Resources/bin" -type f -perm +111 2>/dev/null \
  | while read f; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true; done
find "${APP_BUNDLE}/Contents/Resources/whisper" -type f -perm +111 2>/dev/null \
  | while read f; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true; done
codesign --force --deep --sign - --timestamp=none "${APP_BUNDLE}"

# ---------- 3. Stage DMG layout ----------
echo "==> Staging DMG contents"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
ditto "${APP_BUNDLE}" "${STAGE_DIR}/${APP_BUNDLE}"
ln -sf /Applications "${STAGE_DIR}/Applications"

# Bundle a README and sample Claude Desktop config.
cat > "${STAGE_DIR}/README.txt" <<EOF
Mllama ${VERSION}

A local AI studio: chat with LLMs, generate images and videos with
stable-diffusion.cpp, search and download from HuggingFace, and expose all of
that to other AI agents over the Model Context Protocol.

INSTALL
  Drag Mllama.app into the Applications folder shortcut.

FIRST RUN
  1. Open Mllama from Applications.
  2. Follow the welcome wizard.
  3. (Optional) Install ffmpeg via Homebrew when prompted.
  4. (Optional) Build stable-diffusion.cpp when prompted — binaries land in
     ~/.mllama/bin/ and are auto-discovered.
  5. (Optional) Download a small starter model from the "For Your Mac" panel
     in the Models tab.

QUICK KEYS
  ⌘1 .. ⌘5   Switch workspaces
  ⌘K         Model picker
  ⌘N         New chat
  ⌘⇧R        Restart LLM server
  ⌘⌥R        Restart image server

EXPOSE MLLAMA AS AN MCP SERVER (to Claude Desktop, Cursor, etc.)
  Settings → MCP Server → "Expose Mllama as MCP server"
  Then copy the snippet under "Connect from Claude Desktop / Cursor" and
  paste it into ~/Library/Application Support/Claude/claude_desktop_config.json.

  Example Claude Desktop snippet (via the mcp-remote bridge):

    {
      "mcpServers": {
        "mllama": {
          "command": "npx",
          "args": ["-y", "mcp-remote", "http://127.0.0.1:3737/mcp"]
        }
      }
    }

  Now Claude Desktop can call:
    - generate_image      (returns the rendered PNG inline)
    - edit_image
    - generate_video
    - search_hf_models
    - list_media
    - get_media_file
    - server_info

CURL SMOKE TEST (with MCP server running)
  curl -s http://127.0.0.1:3737/health
  curl -s http://127.0.0.1:3737/mcp -H 'Content-Type: application/json' \\
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
         "params":{"protocolVersion":"2024-11-05","capabilities":{},
                   "clientInfo":{"name":"curl","version":"1"}}}'

DATA LOCATIONS
  ~/.mllama/hf/        HuggingFace model cache (your downloads)
  ~/.mllama/bin/       sd-server / sd-cli (after Quick Setup builds them)
  ~/.mllama/media/     generated images and videos
  ~/.mllama/library.json   gallery index
  ~/.mllama/prompts.json   saved prompts

UNINSTALL
  Drag Mllama.app to the Trash. Remove ~/.mllama if you want to reclaim disk.

REQUIREMENTS
  macOS 13.0 (Ventura) or newer
  Apple Silicon recommended (Intel may work but is untested)
  16 GB RAM recommended; 8 GB works for small models

OPEN SOURCE
  Mllama wraps llama.cpp (MIT) and stable-diffusion.cpp (MIT). Each generates
  its own subprocess; no third-party network calls are made except to
  huggingface.co for model downloads.
EOF

# Sample Claude Desktop snippet — easy copy-paste
cat > "${STAGE_DIR}/claude_desktop_mllama.json" <<EOF
{
  "mcpServers": {
    "mllama": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:3737/mcp"]
    }
  }
}
EOF

# ---------- 4. Build DMG ----------
echo "==> Building DMG"
mkdir -p "${DIST_DIR}"
rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DIST_DIR}/${DMG_NAME}" \
  >/dev/null

# ---------- 5. Report ----------
SIZE=$(stat -f%z "${DIST_DIR}/${DMG_NAME}" 2>/dev/null || stat -c%s "${DIST_DIR}/${DMG_NAME}")
HUMAN=$(printf "%.1f MB" "$(echo "$SIZE / 1024 / 1024" | bc -l)")
SHA=$(shasum -a 256 "${DIST_DIR}/${DMG_NAME}" | awk '{print $1}')

echo ""
echo "✓ ${DIST_DIR}/${DMG_NAME}"
echo "  size:  ${HUMAN}"
echo "  sha256: ${SHA}"
echo ""
echo "Test the DMG: open ${DIST_DIR}/${DMG_NAME}"

rm -rf "${STAGE_DIR}"
