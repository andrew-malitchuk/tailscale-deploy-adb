#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   # Pre-flight only:
#   deploy.sh --ip <ip> --port <port> --connect-only
#
#   # Full deploy:
#   deploy.sh --ip <ip> --port <port> \
#     --variant <Debug|Release> \
#     --app-id <com.example.app> \
#     --activity <com.example.app.MainActivity> \
#     --launch-app <true|false> \
#     --debug-launch \
#     --logcat-seconds <N>
#
# Exit codes:
#   0 — success
#   1 — adb connect failed after retries
#   2 — gradle build failed
#   3 — adb install failed

usage() {
  echo "Usage: $(basename "$0") --ip IP --port PORT [options]" >&2
  echo "  --connect-only      only connect and verify, skip build/install" >&2
  echo "  --variant V         Gradle build variant (default: Debug)" >&2
  echo "  --app-id PKG        application package name" >&2
  echo "  --activity CLASS    fully qualified main Activity class" >&2
  echo "  --launch-app BOOL   launch app after install (default: true)" >&2
  echo "  --debug-launch      launch in debug mode: app starts suspended, waiting for JDWP debugger" >&2
  echo "  --logcat-seconds N  tail logcat for N seconds (default: 10, 0=skip)" >&2
  exit 1
}

# ── Defaults ───────────────────────────────────────────────────────────────────
IP=""
PORT="5555"
CONNECT_ONLY=false
VARIANT="Debug"
APP_ID=""
ACTIVITY=""
LAUNCH_APP="true"
DEBUG_LAUNCH=false
LOGCAT_SECS="10"

# ── Arg parsing ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --ip)              IP="$2";            shift 2 ;;
    --port)            PORT="$2";          shift 2 ;;
    --connect-only)    CONNECT_ONLY=true;  shift   ;;
    --variant)         VARIANT="$2";       shift 2 ;;
    --app-id)          APP_ID="$2";        shift 2 ;;
    --activity)        ACTIVITY="$2";      shift 2 ;;
    --launch-app)      LAUNCH_APP="$2";    shift 2 ;;
    --debug-launch)    DEBUG_LAUNCH=true;  shift   ;;
    --logcat-seconds)  LOGCAT_SECS="$2";   shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -z "$IP" ] && { echo "Error: --ip is required" >&2; usage; }

SERIAL="${IP}:${PORT}"

# ── Temp file cleanup ──────────────────────────────────────────────────────────
GRADLE_LOG=""
LOGCAT_TMP=""
cleanup() {
  [ -n "${GRADLE_LOG:-}" ] && rm -f "$GRADLE_LOG" 2>/dev/null || true
  [ -n "${LOGCAT_TMP:-}" ] && rm -f "$LOGCAT_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# ── Ensure ADB server is running (Android Studio uses the same daemon) ────────
adb start-server >/dev/null 2>&1 || true

# ── ADB connect with retries ───────────────────────────────────────────────────
echo "==> Connecting to ${SERIAL} ..."
ATTEMPT=0
CONNECTED=false
while [ $ATTEMPT -lt 3 ]; do
  CONNECT_OUT=$(adb connect "$SERIAL" 2>&1) || true
  if echo "$CONNECT_OUT" | grep -qE "(already )?connected to"; then
    CONNECTED=true
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  if [ $ATTEMPT -lt 3 ]; then
    echo "    attempt ${ATTEMPT} failed, retrying in 2s ..."
    sleep 2
  fi
done

if [ "$CONNECTED" = "false" ]; then
  echo "Error: adb connect ${SERIAL} failed after 3 attempts." >&2
  echo "Last output: ${CONNECT_OUT}" >&2
  exit 1
fi

# ── Verify device is in 'device' state (not offline/unauthorized) ──────────────
if ! adb devices | awk -v s="$SERIAL" '$1==s && $2=="device" {found=1} END{exit !found}'; then
  echo "Error: ${SERIAL} is not in 'device' state." >&2
  echo "Current adb devices output:" >&2
  adb devices >&2
  exit 1
fi

echo "    connected: ${SERIAL} [device]"

# ── Exit early if connect-only ─────────────────────────────────────────────────
if [ "$CONNECT_ONLY" = "true" ]; then
  exit 0
fi

# ── Validate required args for full deploy ─────────────────────────────────────
if [ -z "$APP_ID" ] || [ -z "$ACTIVITY" ]; then
  echo "Error: --app-id and --activity are required for full deploy" >&2
  usage
fi

# ── Gradle build + install ─────────────────────────────────────────────────────
echo "==> Building and installing: ./gradlew install${VARIANT} ..."
GRADLE_LOG=$(mktemp)

if ! ./gradlew "install${VARIANT}" > "$GRADLE_LOG" 2>&1; then
  echo "Error: Gradle build failed." >&2
  echo "--- Last 50 lines of build log ---" >&2
  tail -50 "$GRADLE_LOG" >&2
  echo "--- End of build log ---" >&2
  exit 2
fi

echo "    install: OK"

# Verify install actually succeeded (adb install can exit 0 on some errors)
if ! adb -s "$SERIAL" shell pm list packages 2>/dev/null | grep -qF "$APP_ID"; then
  echo "Error: APK install did not register package '${APP_ID}'." >&2
  echo "Run 'adb -s ${SERIAL} shell pm list packages' to check." >&2
  exit 3
fi

# ── Launch app ─────────────────────────────────────────────────────────────────
LAUNCHED="no"
if [ "$LAUNCH_APP" = "true" ]; then
  if [ "$DEBUG_LAUNCH" = "true" ]; then
    echo "==> Launching in DEBUG mode: ${APP_ID}/${ACTIVITY} ..."
    # -D flag: starts the app suspended, waiting for JDWP debugger attachment
    adb -s "$SERIAL" shell am start -D -n "${APP_ID}/${ACTIVITY}" >/dev/null 2>&1 || {
      echo "Warning: am start -D returned non-zero. App may still be waiting for debugger." >&2
    }
    LAUNCHED="debug"
    echo "    launched (suspended — waiting for debugger)"
    echo "DEBUG_ATTACH_HINT: Android Studio → Run → Attach Debugger to Android Process → ${APP_ID}"
  else
    echo "==> Launching: ${APP_ID}/${ACTIVITY} ..."
    adb -s "$SERIAL" shell am start -n "${APP_ID}/${ACTIVITY}" >/dev/null 2>&1 || {
      echo "Warning: am start returned non-zero. App may have launched anyway." >&2
    }
    LAUNCHED="yes"
    echo "    launched"
  fi
fi

# ── Logcat tail ────────────────────────────────────────────────────────────────
CRITICAL_COUNT=0
CRITICAL_LINES=""

if [ "$LOGCAT_SECS" -gt 0 ] && [ "$LAUNCHED" = "yes" ]; then
  echo "==> Tailing logcat for ${LOGCAT_SECS}s (PID of ${APP_ID}) ..."

  # Give the process time to start
  sleep 1
  APP_PID=$(adb -s "$SERIAL" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r') || APP_PID=""
  if [ -z "$APP_PID" ]; then
    sleep 1
    APP_PID=$(adb -s "$SERIAL" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r') || APP_PID=""
  fi

  if [ -z "$APP_PID" ]; then
    echo "Warning: could not get PID for '${APP_ID}' — app may have crashed on startup." >&2
  else
    LOGCAT_TMP=$(mktemp)
    # Stream logcat in background; kill after N seconds (macOS-compatible, no GNU timeout needed)
    adb -s "$SERIAL" logcat -T 1 "--pid=${APP_PID}" > "$LOGCAT_TMP" 2>/dev/null &
    LOGCAT_BG=$!
    sleep "$LOGCAT_SECS"
    kill "$LOGCAT_BG" 2>/dev/null || true
    wait "$LOGCAT_BG" 2>/dev/null || true

    CRITICAL_COUNT=$(grep -cE "^[EF]/|FATAL EXCEPTION" "$LOGCAT_TMP" 2>/dev/null || echo "0")
    if [ "$CRITICAL_COUNT" -gt 0 ]; then
      CRITICAL_LINES=$(grep -E "^[EF]/|FATAL EXCEPTION" "$LOGCAT_TMP" 2>/dev/null || true)
    fi
    echo "    logcat: ${CRITICAL_COUNT} critical line(s)"
  fi
fi

# ── Summary output (read by SKILL.md for Step 8 report) ───────────────────────
echo ""
echo "DEPLOY_STATUS: success"
echo "APP_ID: ${APP_ID}"
echo "VARIANT: ${VARIANT}"
echo "SERIAL: ${SERIAL}"
echo "LAUNCHED: ${LAUNCHED}"
echo "LOGCAT_CRITICAL: ${CRITICAL_COUNT}"
if [ -n "$CRITICAL_LINES" ]; then
  echo "---CRITICAL_LINES---"
  echo "$CRITICAL_LINES"
  echo "---END_CRITICAL_LINES---"
fi
