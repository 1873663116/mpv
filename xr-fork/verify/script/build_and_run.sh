#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RealityKitVerifyApp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${VERIFY_DIR}/../.." && pwd)"
MPV_BUILD="${REPO_ROOT}/build-libmpv"
DIST_DIR="${VERIFY_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"
MODE="immersive"
ACTION="run"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only)
            ACTION="build-only"
            ;;
        --verify)
            ACTION="verify"
            ;;
        --window)
            MODE="window"
            ;;
        --immersive)
            MODE="immersive"
            ;;
        *)
            echo "usage: $0 [--build-only] [--verify] [--window|--immersive]" >&2
            exit 2
            ;;
    esac
    shift
done

cd "${REPO_ROOT}"

if [[ ! -f "${MPV_BUILD}/build.ninja" ]]; then
    meson setup "${MPV_BUILD}" \
        -Dcplayer=true -Dlibmpv=true -Dtests=false \
        -Dlua=disabled -Djavascript=disabled \
        -Dvulkan=enabled -Dvideotoolbox-pl=disabled \
        -Dcocoa=enabled -Dgl=enabled
else
    meson setup --reconfigure "${MPV_BUILD}" \
        -Dcplayer=true -Dlibmpv=true -Dtests=false \
        -Dlua=disabled -Djavascript=disabled \
        -Dvulkan=enabled -Dvideotoolbox-pl=disabled \
        -Dcocoa=enabled -Dgl=enabled
fi

meson compile -C "${MPV_BUILD}"

cd "${VERIFY_DIR}"
swift build

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${FRAMEWORKS_DIR}"
cp ".build/debug/${APP_NAME}" "${APP_BINARY}"
cp "${MPV_BUILD}/libmpv.2.dylib" "${FRAMEWORKS_DIR}/"
ln -sf "libmpv.2.dylib" "${FRAMEWORKS_DIR}/libmpv.dylib"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>dev.enchron.RealityKitVerifyApp</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    pkill -x "${APP_NAME}" || true
fi

if [[ "${ACTION}" == "build-only" ]]; then
    exit 0
fi

/usr/bin/open -n "${APP_BUNDLE}" --args --mode "${MODE}"

if [[ "${ACTION}" == "verify" ]]; then
    for _ in {1..20}; do
        if pgrep -x "${APP_NAME}" >/dev/null; then
            exit 0
        fi
        sleep 0.5
    done
    exit 1
fi
