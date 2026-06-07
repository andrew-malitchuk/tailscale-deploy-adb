---
name: tailscale-deploy-adb
description: Deploy Android debug build to a physical device over Tailscale + Wireless ADB. Use when user wants to install a fresh APK on their phone remotely (from gym, cafe, anywhere outside home Wi-Fi). Triggers: "tailscale deploy", "deploy adb", "install on phone", "deploy to phone", "deploy debug build", "push apk to device", "wireless deploy".
allowed-tools: Bash, Read, Write, AskUserQuestion
model: claude-haiku-4-5-20251001
---

Deploys an Android debug build to a physical device via Tailscale + Wireless ADB. Reads per-project config from `.tailscale-deploy-adb.json` in the project root (current working directory).

Reference files (load on demand):
- `references/tailscale-resolve.md` — Tailscale peer resolution, MagicDNS, troubleshooting offline peers
- `references/adb-troubleshoot.md` — Wireless ADB port fixation, common `adb connect` failures, cheat-list
- `references/config-schema.md` — full config schema, examples, how to find `application_id` and `main_activity`

---

## Step 0 — Check Tailscale

Before anything else, verify Tailscale is running on the Mac:

```bash
tailscale status >/dev/null 2>&1 && echo "running" || echo "stopped"
```

- **running** → proceed to Determine mode.
- **stopped** → **Stop immediately.** Tell user:
  > ❌ Tailscale is not running on this Mac.
  > Open the Tailscale app in the menu bar (or run `open -a Tailscale`), connect, then retry.

---

## Determine mode

Inspect the user's message for these keywords:

| Keyword | Mode |
|---|---|
| `dry-run`, `test connection`, `check connection`, `connection only` | `dry-run` |
| `debug`, `attach debugger`, `debug mode`, `deploy with debugger`, `debug deploy` | `debug` |
| Everything else | `deploy` |

**dry-run**: execute Steps 1–4 only. Skip Step 5. Jump to Step 8 (connection report).
**debug**: same as `deploy` but passes `--debug-launch` to deploy.sh — app launches suspended, waiting for JDWP debugger from Android Studio.
**deploy**: execute all Steps 1–8 with normal launch.

---

## Step 1 — Validate environment

Run:
```bash
for cmd in tailscale adb jq; do
  command -v "$cmd" >/dev/null 2>&1 && echo "OK: $cmd" || echo "MISSING: $cmd"
done
[ -f ./gradlew ] && echo "OK: gradlew" || echo "MISSING: ./gradlew"
```

If any line starts with `MISSING:`, stop and tell the user (all at once):
- `MISSING: tailscale` → not in PATH. macOS fix: `sudo ln -s /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale`
- `MISSING: adb` → install platform-tools: `brew install --cask android-platform-tools`
- `MISSING: jq` → `brew install jq`
- `MISSING: ./gradlew` → "Run this skill from the Android project root (where `gradlew` lives)"

Do not proceed until all tools are available.

---

## Step 1.5 — Enable ADB TCP mode via USB

Android's Wireless Debugging (Developer Options) only works over WiFi. To deploy over **any** network — including cellular — the ADB daemon must be switched to TCP mode via USB. This must be done once per device boot.

Run:
```bash
adb devices
```

**If the output shows a USB-connected device** (state = `device`):
1. Automatically run:
   ```bash
   adb tcpip 5555
   ```
2. Tell user:
   > ✅ ADB TCP mode enabled on port 5555. Disconnect the USB cable now and proceed.
3. Proceed to Step 2.

**If no USB device is found** (empty list, or only wireless/offline entries):

Display this mandatory notice and ask for confirmation via **AskUserQuestion** (single question):

> ⚠️ **USB prerequisite required**
>
> Wireless ADB without WiFi requires TCP mode to be enabled first. This is a one-time step per device boot.
>
> **Steps (do this now):**
> 1. Connect your phone to this Mac via USB cable
> 2. Confirm "Allow USB debugging" on the phone if prompted
> 3. Run in terminal: `adb tcpip 5555`
> 4. Disconnect USB — ADB now listens on port 5555 over any network
>
> **After phone reboot**: this step must be repeated before deploying.

Question options:
- label `Done — ran adb tcpip 5555 via USB`, description `ready to continue`
- label `Skip — I'm on WiFi right now`, description `will use Wireless Debugging instead (WiFi only)`
- label `Cancel`, description `stop here`

If user selects **Done**: proceed to Step 2.
If user selects **Skip**: proceed to Step 2 (WiFi path — Wireless Debugging in Developer Options must be ON).
If user selects **Cancel**: stop gracefully with message: `Deploy cancelled. Run the skill again when ready.`

---

## Step 2 — Load or create config

Use the **Read tool** to read `.tailscale-deploy-adb.json` from the current directory.

**If the file exists**, extract these fields:

| Field | Type | Default |
|---|---|---|
| `device_hostname` | string | required |
| `application_id` | string | required |
| `main_activity` | string | required |
| `variant` | string | `"Debug"` |
| `adb_port` | integer | `5555` |
| `launch_after_install` | boolean | `true` |
| `logcat_seconds` | integer | `10` |

**If the file does not exist**, follow Steps 2a → 2b → 2c below.

### Step 2a — Auto-detect values from the project

Run all three commands (suppress errors — detection may find nothing):

```bash
# Android peers in Tailscale (hostname|online-status)
tailscale status --json 2>/dev/null \
  | jq -r '(.Peer // {}) | to_entries[] | .value | select(.OS == "android") | "\(.HostName)|\(if .Online then "online" else "offline" end)"' \
  2>/dev/null || true
```

```bash
# Application IDs from Gradle build files
grep -rh "applicationId" --include="*.gradle" --include="*.gradle.kts" . 2>/dev/null \
  | grep -v "//\|test\|Test" \
  | grep -oE '"[a-z][a-zA-Z0-9._]+"' \
  | tr -d '"' | sort -u | head -4 || true
```

```bash
# Launcher Activity from AndroidManifest
grep -rh "android:name" --include="AndroidManifest.xml" . 2>/dev/null \
  | sed 's/.*android:name="\([^"]*\)".*/\1/' \
  | grep -v "^\." | grep -iE "Activity|activity" | head -3 || true
```

### Step 2b — Present choices via AskUserQuestion

Call **AskUserQuestion** with exactly 4 questions in a single invocation:

**Q1 — Device hostname** (`header: "Device"`)
Build options from command 1 output. Each detected peer becomes one option (label = hostname, description = "online" or "offline in Tailscale"). If no peers detected: use label `my-phone`, description `enter your Tailscale hostname`. Always 2–4 options max (the tool appends "Other" for free-text input automatically).

**Q2 — Application ID** (`header: "App ID"`)
Build options from command 2 output. For each detected base ID: add it as one option (description = "from build.gradle"). If it does not already end in `.debug`, also add `<base-id>.debug` as a second option (description = "debug variant via applicationIdSuffix"). If nothing detected: use label `com.example.myapp.debug`, description `enter your debug package name`.

**Q3 — Main Activity** (`header: "Activity"`)
Build options from command 3 output. Each detected class becomes one option (description = "from AndroidManifest.xml"). If nothing detected: use label `com.example.myapp.MainActivity`, description `enter your launcher Activity class`.

**Q4 — ADB port** (`header: "ADB Port"`)
- label `5555`, description `default after running adb tcpip 5555 via USB (Recommended)`
- label `Custom`, description `enter your port — visible in Developer Options → Wireless Debugging on the device`

If user selects "Custom" or types "Other", ask them to provide the exact port number.

Always ask this question explicitly — Android randomizes the port after each pairing session unless fixed via `adb tcpip 5555`. See `references/adb-troubleshoot.md`.

### Step 2c — Handle optional settings

After the 4-question call, use these defaults for remaining fields:
`variant="Debug"`, `launch_after_install=true`, `logcat_seconds=10`

To change these later: edit `.tailscale-deploy-adb.json` directly, or delete the file and re-run the skill.

### Step 2d — Write config file

Write `.tailscale-deploy-adb.json` via **Write tool** (pretty-printed, 2-space indent) with all collected values. Tell user:
> ✅ Config saved: `.tailscale-deploy-adb.json`

---

## Step 3 — Resolve device IP via Tailscale

Run (replace `DEVICE_HOSTNAME` with the value from config):
```bash
bash ~/.claude/skills/tailscale-deploy-adb/scripts/resolve-device.sh "DEVICE_HOSTNAME"
```

Interpret exit codes:
- **0** → capture stdout as `DEVICE_IP`. Proceed.
- **1** → peer not found. **Stop.** Tell user: verify hostname with `tailscale status`. Load `references/tailscale-resolve.md`.
- **2** → peer offline. **Stop.** Tell user:
  > ❌ Device `DEVICE_HOSTNAME` is offline in Tailscale.
  > Check: Is Tailscale active on the phone? Is the screen on?
  > Details: `references/tailscale-resolve.md`
- **3** → Tailscale not running on Mac. **Stop.** Tell user to open Tailscale app.

---

## Step 4 — Verify ADB connectivity (pre-flight)

Run (replace placeholders with actual values):
```bash
bash ~/.claude/skills/tailscale-deploy-adb/scripts/deploy.sh \
  --ip "DEVICE_IP" \
  --port "ADB_PORT" \
  --connect-only
```

Interpret exit codes:
- **0** → ADB connected. The device is now also visible in Android Studio's device selector (both tools share the same ADB server). In `dry-run` mode → jump to Step 8. In `deploy` mode → proceed to Step 5.
- **1** → **Stop.** Tell user:
  > ❌ `adb connect DEVICE_IP:ADB_PORT` failed after 3 attempts.
  > Most likely cause: ADB TCP mode not enabled. Connect phone via USB and run `adb tcpip 5555`, then retry.
  > Also check: Is Tailscale active on the phone? Is the screen on?
  > Full checklist: `references/adb-troubleshoot.md`

---

## Step 5 — Build, install, launch, and logcat

*(Skip in `dry-run` mode)*

Construct the command from config values (replace all uppercase placeholders; set `LAUNCH_AFTER_INSTALL` to the string `"true"` or `"false"`).

**deploy mode:**
```bash
bash ~/.claude/skills/tailscale-deploy-adb/scripts/deploy.sh \
  --ip "DEVICE_IP" \
  --port "ADB_PORT" \
  --variant "VARIANT" \
  --app-id "APPLICATION_ID" \
  --activity "MAIN_ACTIVITY" \
  --launch-app "LAUNCH_AFTER_INSTALL" \
  --logcat-seconds "LOGCAT_SECONDS"
```

**debug mode** — add `--debug-launch` flag (starts app suspended, waiting for JDWP debugger):
```bash
bash ~/.claude/skills/tailscale-deploy-adb/scripts/deploy.sh \
  --ip "DEVICE_IP" \
  --port "ADB_PORT" \
  --variant "VARIANT" \
  --app-id "APPLICATION_ID" \
  --activity "MAIN_ACTIVITY" \
  --launch-app "true" \
  --debug-launch \
  --logcat-seconds "LOGCAT_SECONDS"
```

Capture all output. Interpret exit codes:
- **0** → success. Proceed to Step 8.
- **1** → ADB dropped during install (phone may have slept). **Stop.** Tell user to wake phone and retry.
- **2** → Gradle build failed. Script printed last 50 build-log lines to stderr. **Stop.** Show those lines to the user.
- **3** → APK install failed. **Stop.** Tell user to run `adb devices` and check for `unauthorized` state.

---

## Step 6 — Launch app

Handled internally by `deploy.sh` when `--launch-app true` is passed. No separate action needed.

---

## Step 7 — Logcat tail

Handled internally by `deploy.sh` when `--logcat-seconds N > 0` is passed. No separate action needed.

---

## Step 8 — Final report

**dry-run success:**

> ✅ Connection successful
> ────────────────────────────────────────
> Device:    `DEVICE_HOSTNAME` → `DEVICE_IP:ADB_PORT`
> Tailscale: online ✓
> ADB state: `device` ✓
> ────────────────────────────────────────
> Ready to deploy. Run without `dry-run` to build and install the APK.

**deploy success** (parse deploy.sh stdout for summary values):

> ✅ Deploy complete
> ────────────────────────────────────────
> Device:    `DEVICE_HOSTNAME` (`DEVICE_IP:ADB_PORT`)
> APK:       `VARIANT` › `APPLICATION_ID`
> Launched:  yes / no
> Logcat:    N critical line(s) (E/ FATAL)
> ────────────────────────────────────────

If there were critical logcat lines, show them below the summary box.

**debug success** — app is suspended, waiting for debugger:

> 🐛 Deploy complete — app waiting for debugger
> ────────────────────────────────────────
> Device:    `DEVICE_HOSTNAME` (`DEVICE_IP:ADB_PORT`)
> APK:       `VARIANT` › `APPLICATION_ID`
> State:     suspended (waiting for JDWP debugger)
> ────────────────────────────────────────
> **How to attach in Android Studio:**
> 1. Run → Attach Debugger to Android Process
> 2. Select process `APPLICATION_ID`
> 3. Click OK — app will resume

---

## Error handling

- **Tailscale offline**: stop at Step 3, tell user what to check. Never retry automatically — device state is external.
- **adb connect failure**: 3 retries are inside `deploy.sh`. If all fail → show `references/adb-troubleshoot.md` cheat-list.
- **Gradle build failure**: show last 50 build log lines immediately. Never attempt launch.
- **pidof race**: `deploy.sh` retries once after 1s. If pidof still returns empty (app may have crashed), logcat is skipped with a warning.
- **jq missing**: caught in Step 1. Scripts never execute without `jq`.

---

## Notes

- Always invoke from the Android project root (where `gradlew` and `.tailscale-deploy-adb.json` live).
- **Android Studio**: after `adb connect` succeeds, the device appears automatically in AS's device selector — both tools share the same ADB server daemon. `deploy.sh` calls `adb start-server` before connecting to ensure the daemon is alive.
- **Wireless Debugging prerequisite**: must be enabled on the device before connecting. Settings → Developer Options → Wireless Debugging → ON. This toggle can reset after OS updates.
- **Wireless ADB port**: Android randomizes the port after each pairing session. Fix it permanently (until reboot) with `adb tcpip 5555` over USB. If you use a non-5555 port, record it in `adb_port` in the config. Details in `references/adb-troubleshoot.md`.
- ADB serial for wireless is `<ip>:<port>`. All `adb -s` calls in scripts include the port.
- `application_id` for debug builds often has a `.debug` suffix (`applicationIdSuffix` in `build.gradle`). Confirm via `build/outputs/apk/debug/output-metadata.json` or `adb shell pm list packages | grep your-app`.
