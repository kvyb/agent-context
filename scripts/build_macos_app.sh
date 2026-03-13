#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Agent Context"
APP_BUNDLE_PATH="${1:-/Applications/${APP_NAME}.app}"
EXECUTABLE_NAME="agent-context"
PRODUCT_BINARY="${PROJECT_ROOT}/.build/release/agent-context"
APP_PARENT_DIR="$(dirname "${APP_BUNDLE_PATH}")"

if [[ ! -d "${APP_PARENT_DIR}" ]]; then
  echo "error: destination parent does not exist: ${APP_PARENT_DIR}" >&2
  exit 1
fi

if [[ ! -w "${APP_PARENT_DIR}" ]]; then
  echo "error: no write permission for ${APP_PARENT_DIR}" >&2
  echo "rerun with sudo, for example:" >&2
  echo "  sudo ${0} \"${APP_BUNDLE_PATH}\"" >&2
  exit 1
fi

echo "Building release binary..."
cd "${PROJECT_ROOT}"
swift build -c release --product agent-context

if [[ ! -x "${PRODUCT_BINARY}" ]]; then
  echo "error: missing built binary at ${PRODUCT_BINARY}" >&2
  exit 1
fi

echo "Creating app bundle at ${APP_BUNDLE_PATH}"
rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${APP_BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${APP_BUNDLE_PATH}/Contents/Resources"

cp "${PRODUCT_BINARY}" "${APP_BUNDLE_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "${APP_BUNDLE_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"

if [[ -f "${PROJECT_ROOT}/scripts/mem0_ingest.py" ]]; then
  cp "${PROJECT_ROOT}/scripts/mem0_ingest.py" "${APP_BUNDLE_PATH}/Contents/Resources/mem0_ingest.py"
  chmod +x "${APP_BUNDLE_PATH}/Contents/Resources/mem0_ingest.py"
else
  echo "warning: scripts/mem0_ingest.py not found; Mem0 ingestion from app bundle will be disabled."
fi

if [[ -f "${PROJECT_ROOT}/scripts/mem0_search.py" ]]; then
  cp "${PROJECT_ROOT}/scripts/mem0_search.py" "${APP_BUNDLE_PATH}/Contents/Resources/mem0_search.py"
  chmod +x "${APP_BUNDLE_PATH}/Contents/Resources/mem0_search.py"
else
  echo "warning: scripts/mem0_search.py not found; Mem0 semantic search from app bundle will be disabled."
fi

cat > "${APP_BUNDLE_PATH}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Agent Context</string>
  <key>CFBundleExecutable</key>
  <string>agent-context</string>
  <key>CFBundleIdentifier</key>
  <string>com.kvyb.agent-context</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Agent Context</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${AGENT_CONTEXT_CODESIGN_IDENTITY:-}"
  if [[ -z "${SIGN_IDENTITY}" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development/ {print $2; exit}')"
  fi

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "Applying code signature with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE_PATH}" >/dev/null 2>&1 || true
  else
    echo "Applying ad-hoc code signature..."
    codesign --force --deep --sign - "${APP_BUNDLE_PATH}" >/dev/null 2>&1 || true
  fi
fi

echo ""
echo "Built: ${APP_BUNDLE_PATH}"
echo "Ready to launch from Applications."
