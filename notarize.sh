#!/usr/bin/env bash
# Sign with Developer ID, notarize, staple, rebuild DMG, and re-staple.
# Requires:
#   - A "Developer ID Application" cert in the login keychain
#   - A stored notary profile named "mllama-notary"
#     (created with: xcrun notarytool store-credentials)
#
# Usage:
#   ./notarize.sh                # full pipeline
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mllama"
APP_BUNDLE="${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist")"
ARCH="$(uname -m)"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
DIST_DIR="dist"
STAGE_DIR="${DIST_DIR}/stage"

# Developer ID Application identity (auto-detected; override with $SIGN_IDENTITY)
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Abdullah Mirza Hamid mehmood (48P296BWWP)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-mllama-notary}"

echo "==> Building release"
./build.sh release >/dev/null

echo "==> Writing entitlements (hardened runtime requires this)"
ENTITLEMENTS="$(mktemp -t mllama-entitlements).plist"
cat > "${ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Allow JIT compilation (llama.cpp uses runtime code paths that
         Apple has historically allowed under JIT) and unsigned executable
         memory for the same reason. -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <!-- Allow Mllama to invoke /bin/zsh, sd-cli, ffmpeg, etc. -->
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
    <!-- Mllama runs local HTTP servers (llama-server, sd-server, MCP host)
         and downloads weights from huggingface.co. -->
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- Microphone for voice input (whisper transcription). -->
    <key>com.apple.security.device.microphone</key>
    <true/>
    <!-- User-selected file read/write so the file pickers / Reveal in Finder work. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- ScriptedTool runs sub-processes via /bin/zsh — needs library
         validation off because /bin/zsh is system-signed not Apple-signed
         from this team. -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Signing nested binaries (dylibs first, then executables, then bundle)"
# Sign every dylib in dependency order.
find "${APP_BUNDLE}/Contents/Resources" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 \
  | xargs -0 -n1 codesign --force --options runtime --timestamp \
      --sign "${SIGN_IDENTITY}" 2>&1 | grep -v "^$" || true

# Sign every executable under bin/ and whisper/
find "${APP_BUNDLE}/Contents/Resources/bin" "${APP_BUNDLE}/Contents/Resources/whisper" \
     -type f -perm +111 2>/dev/null \
  | while read f; do
      codesign --force --options runtime --timestamp \
               --sign "${SIGN_IDENTITY}" "$f" 2>&1 | grep -v "^$" || true
    done

# Finally sign the app bundle itself with entitlements.
codesign --force --deep --options runtime --timestamp \
         --entitlements "${ENTITLEMENTS}" \
         --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | tail -3
spctl --assess --type execute --verbose=2 "${APP_BUNDLE}" 2>&1 | tail -2 || true

echo "==> Submitting to Apple notary service (this can take 2–10 min)"
# Zip the .app for submission — DMG submission also works but app-bundle
# zip is faster because notary doesn't have to disassemble the DMG.
SUBMIT_ZIP="$(mktemp -t mllama-submit).zip"
ditto -c -k --keepParent "${APP_BUNDLE}" "${SUBMIT_ZIP}"
xcrun notarytool submit "${SUBMIT_ZIP}" \
  --keychain-profile "${KEYCHAIN_PROFILE}" \
  --wait \
  --timeout 30m
rm -f "${SUBMIT_ZIP}"

echo "==> Stapling notarization ticket to the .app"
xcrun stapler staple -v "${APP_BUNDLE}"
xcrun stapler validate -v "${APP_BUNDLE}"

echo "==> Rebuilding DMG with the stapled .app"
# CRITICAL: do NOT call package.sh from here. package.sh runs `xcrun strip`
# on the binary and re-signs with ad-hoc, which would wipe the Developer
# ID signature we just applied and cause the DMG to be rejected by Apple
# notary with: "The binary is not signed with a valid Developer ID
# certificate." All the DMG layout (README, Applications symlink, Claude
# config) is built inline below.
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
ditto "${APP_BUNDLE}" "${STAGE_DIR}/${APP_BUNDLE}"
ln -sf /Applications "${STAGE_DIR}/Applications"

cat > "${STAGE_DIR}/README.txt" <<EOF
Mllama ${VERSION} — notarized build

This .app is signed with Apple Developer ID and notarized by Apple. macOS
should open it on the first try without a Gatekeeper warning.

Drag Mllama.app into the Applications folder shortcut.

If you do see a warning (very rare for notarized builds — usually means the
quarantine attribute wasn't stripped during download), run:
    xattr -dr com.apple.quarantine /Applications/Mllama.app

Source code: https://github.com/Mirxa27/mllama
Release:     https://github.com/Mirxa27/mllama/releases/tag/v${VERSION}
EOF

cat > "${STAGE_DIR}/claude_desktop_mllama.json" <<'EOF'
{
  "mcpServers": {
    "mllama": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:3737/mcp"]
    }
  }
}
EOF

DMG_OUT="${DIST_DIR}/${DMG_NAME}"
rm -f "${DMG_OUT}"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${STAGE_DIR}" \
  -ov -format UDZO \
  "${DMG_OUT}" >/dev/null

echo "==> Signing the DMG itself (best practice for distribution)"
codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_OUT}"

echo "==> Notarizing the DMG"
xcrun notarytool submit "${DMG_OUT}" \
  --keychain-profile "${KEYCHAIN_PROFILE}" \
  --wait \
  --timeout 30m

echo "==> Stapling DMG"
xcrun stapler staple -v "${DMG_OUT}"
xcrun stapler validate -v "${DMG_OUT}"

rm -rf "${STAGE_DIR}" "${ENTITLEMENTS}"

SIZE=$(stat -f%z "${DMG_OUT}")
HUMAN=$(printf "%.1f MB" "$(echo "$SIZE / 1024 / 1024" | bc -l)")
SHA=$(shasum -a 256 "${DMG_OUT}" | awk '{print $1}')

echo ""
echo "==========================================="
echo "  Notarized DMG ready"
echo "==========================================="
echo "  ${DMG_OUT}"
echo "  ${HUMAN}"
echo "  sha256: ${SHA}"
echo "  signed by: ${SIGN_IDENTITY}"
echo "  notarized + stapled — no Gatekeeper warning"
echo "==========================================="
