#!/bin/bash
# Sonar for iPhone: generates the Xcode project and builds it. Usage: Scripts/ios.sh mac|build|install|device|log
# mac = Catalyst build for off-screen checks, build = signed iPhone build, install = copy the last build to the connected iPhone,
# device = both, log = pull the last recorded session (raw audio and poses) from the phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-mac}"
DERIVED="$ROOT/.build/ios"
APP="$DERIVED/Build/Products/Release-iphoneos/Sonar.app"
cd "$ROOT/iOS"
xcodegen generate --quiet

find_phone() {
  local list
  list="$(mktemp)"
  xcrun devicectl list devices --json-output "$list" >/dev/null 2>&1 || true
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1]))['result']['devices']; print(next((x['hardwareProperties']['udid'] for x in d if x.get('hardwareProperties',{}).get('deviceType')=='iPhone' and x.get('connectionProperties',{}).get('pairingState')=='paired'), ''))" "$list" 2>/dev/null || true
  rm -f "$list"
}

build_phone() {
  local team
  team="$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/{print $2}')"
  nice -n 10 xcodebuild -project Sonar.xcodeproj -scheme Sonar -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-list --count HEAD)" -jobs 2 -quiet build
  echo "$APP"
}

install_phone() {
  local udid
  udid="$(find_phone)"
  if [ -z "$udid" ]; then echo "No connected iPhone: plug it in, unlock it and trust this Mac" >&2; exit 1; fi
  xcrun devicectl device install app --device "$udid" "$APP"
  echo "installed on $udid"
}

case "$MODE" in
  mac)
    nice -n 10 xcodebuild -project Sonar.xcodeproj -scheme Sonar -configuration Release \
      -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
      DEVELOPMENT_TEAM= -jobs 2 -quiet build
    echo "$DERIVED/Build/Products/Release-maccatalyst/Sonar.app"
    ;;
  build) build_phone ;;
  install) install_phone ;;
  device) build_phone; install_phone ;;
  log)
    UDID="$(find_phone)"
    if [ -z "$UDID" ]; then echo "No connected iPhone: unlock it on the same Wi-Fi or plug it in" >&2; exit 1; fi
    mkdir -p "$ROOT/Niepotrzebne/logs"
    files() {
      xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier fun.gzowo.sonar.ios \
        --subdirectory Documents 2>/dev/null | awk '/^(scan-|last\.)/{print $1}'
    }
    for NAME in $(files); do
      OUT="$ROOT/Niepotrzebne/logs/$NAME"
      case "$NAME" in *.sonarlog) [ -s "$OUT" ] && continue ;; esac
      for TRY in 1 2 3; do
        xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier fun.gzowo.sonar.ios \
          --source "Documents/$NAME" --destination "$OUT" --timeout 240 >/dev/null 2>&1 || true
        [ -s "$OUT" ] && break
        rm -f "$OUT"
      done
      [ -s "$OUT" ] && echo "$OUT"
    done
    ;;
  *) echo "Usage: Scripts/ios.sh mac|build|install|device|log" >&2; exit 1 ;;
esac
