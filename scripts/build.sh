#!/usr/bin/env bash
# Assemble build/MeetingScribe.app. Usage: scripts/build.sh [signing-identity]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
APP="build/MeetingScribe.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MeetingScribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingScribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# No --options runtime: hardened runtime blocks audio input without provisioned entitlements.
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [ "$IDENTITY" = "-" ]; then
    cat <<'MSG'

Ad-hoc signature changes every rebuild; if permissions misbehave, reset them:
  tccutil reset Microphone app.meetingscribe
  tccutil reset SpeechRecognition app.meetingscribe
  tccutil reset ScreenCapture app.meetingscribe
MSG
fi
