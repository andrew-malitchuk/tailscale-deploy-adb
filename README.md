# tailscale-deploy-adb

A Claude Code skill that deploys an Android debug build to a physical device over [Tailscale](https://tailscale.com) + Wireless ADB — no USB cable, no shared Wi-Fi required.


## Motivation

The standard Android debug workflow ties you to a USB cable or forces your phone and laptop onto the same Wi-Fi network. Neither works when you are at a coffee shop, commuting, or at the gym with your development machine back home.

Tailscale creates a secure peer-to-peer overlay network (a *tailnet*) between your devices. Once your phone and laptop are on the same tailnet, ADB can connect over any internet connection — cellular, a public hotspot, or a home router NAT — as if they were on the same LAN.

This skill automates the entire deploy loop inside Claude Code:

1. Verify Tailscale is running and the device is online
2. Resolve the device's Tailscale IP by its hostname
3. Establish a Wireless ADB connection
4. Run `./gradlew install<Variant>` to build and install the APK
5. Launch the app and tail logcat for startup errors

Instead of typing six shell commands and debugging why `adb connect` failed, you tell Claude Code "deploy debug build to my phone" and it handles everything — including diagnosing failures and pointing you to the right fix.


## What it does

- **Tailscale-aware device resolution** — looks up your device by its Tailscale hostname (`tailscale status --json` + `jq`), with a MagicDNS fallback
- **Wireless ADB connect with retries** — connects with 3 retries; verifies the device reaches `device` state (not `offline` or `unauthorized`)
- **Three modes**: `deploy` (build + install + launch), `dry-run` (connection check only), `debug` (launch suspended, waiting for JDWP debugger from Android Studio)
- **Gradle install** — runs `./gradlew install<Variant>` and captures the last 50 build-log lines on failure
- **Logcat tail** — streams logcat filtered by the app PID for N seconds and counts critical lines (`E/` and `FATAL EXCEPTION`)
- **Auto-detect config** — on first run, scans `build.gradle` and `AndroidManifest.xml` to suggest your app ID and activity; saves config to `.tailscale-deploy-adb.json`


## Prerequisites

### Host machine (macOS or Linux)

| Tool | Install |
|---|---|
| [Tailscale CLI](https://tailscale.com/download) | App Store (macOS) or package manager |
| `adb` (Android Platform Tools) | `brew install --cask android-platform-tools` |
| `jq` | `brew install jq` |
| [Claude Code](https://claude.ai/code) | with `/plugin` support |

**macOS note**: the Tailscale App Store build does not add the CLI to PATH automatically. Fix it once:
```bash
sudo ln -s /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale
```

### Android device

1. **Developer Options enabled** — Settings → About phone → tap *Build number* 7 times
2. **USB debugging ON** — Settings → Developer Options → USB debugging
3. **Wireless Debugging ON** — Settings → Developer Options → Wireless Debugging
4. **Tailscale app installed** — available on [Google Play](https://play.google.com/store/apps/details?id=com.tailscale.ipn); sign in to the same tailnet as your laptop
5. **ADB TCP mode set to port 5555** — connect USB once per device boot and run:
   ```bash
   adb tcpip 5555
   ```
   After this you can disconnect the cable. ADB listens on port 5555 over any network until the next reboot.

#### First-time wireless pairing (Android 11+)

If your device has never been connected wirelessly from this machine:

1. On the phone: Settings → Developer Options → Wireless Debugging → *Pair device with pairing code*
2. On the laptop:
   ```bash
   adb pair <phone-ip>:<pairing-port>   # IP and port shown on phone screen
   ```
3. Enter the 6-digit code shown on the phone
4. Pairing is permanent; you will not need to repeat this step

## Installation

### Option A — Plugin marketplace (recommended)

Inside Claude Code:
```
/plugin marketplace add andrew-malitchuk/tailscale-deploy-adb
/plugin install tailscale-deploy-adb@tailscale-deploy-adb
```

The skill will be available immediately. Trigger it by saying things like:
> "deploy debug build to my phone"
> "tailscale deploy"
> "dry-run adb connection"

To update later:
```
/plugin marketplace update
```

### Option B — Manual install

```bash
git clone https://github.com/andrew-malitchuk/tailscale-deploy-adb.git ~/src/tailscale-deploy-adb
cp -r ~/src/tailscale-deploy-adb/skills/tailscale-deploy-adb ~/.claude/skills/
```

Or as a live symlink (auto-updates when you `git pull`):
```bash
ln -s ~/src/tailscale-deploy-adb/skills/tailscale-deploy-adb ~/.claude/skills/tailscale-deploy-adb
```

### Option C — curl one-liner (no git required)

Downloads and extracts only the skill folder from the GitHub release archive. **No script is executed** — `tar` just unpacks files:

```bash
mkdir -p ~/.claude/skills && \
curl -fsSL https://github.com/andrew-malitchuk/tailscale-deploy-adb/archive/refs/heads/main.tar.gz \
  | tar -xz -C ~/.claude/skills --strip-components=2 \
    tailscale-deploy-adb-main/skills/tailscale-deploy-adb && \
chmod +x ~/.claude/skills/tailscale-deploy-adb/scripts/*.sh
```

To update: re-run the same command (it overwrites the existing files).

## Configuration

The skill reads `.tailscale-deploy-adb.json` from your Android project root (the same directory as `gradlew`). On the first run it auto-detects values from your build files and saves the config — you rarely need to create it manually.

**Example config:**
```json
{
  "device_hostname": "my-phone",
  "application_id": "com.example.myapp.debug",
  "main_activity": "com.example.myapp.MainActivity",
  "variant": "Debug",
  "adb_port": 5555,
  "launch_after_install": true,
  "logcat_seconds": 10
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `device_hostname` | string | **required** | Tailscale hostname from `tailscale status` |
| `application_id` | string | **required** | Package name of the installed APK (often has `.debug` suffix) |
| `main_activity` | string | **required** | Fully qualified launcher Activity class |
| `variant` | string | `"Debug"` | Gradle build variant, capitalized (`Debug`, `Staging`, …) |
| `adb_port` | integer | `5555` | ADB TCP port (matches `adb tcpip <port>`) |
| `launch_after_install` | boolean | `true` | Launch app after install |
| `logcat_seconds` | integer | `10` | Seconds to tail logcat after launch (`0` = skip) |

See [`skills/tailscale-deploy-adb/references/config-schema.md`](skills/tailscale-deploy-adb/references/config-schema.md) for the full field reference and more examples.

## Usage

Run the skill by typing any of these in Claude Code (from your Android project root):

| Prompt | Mode | What happens |
|---|---|---|
| `"deploy debug build to my phone"` | `deploy` | Build → install → launch → logcat |
| `"tailscale deploy staging"` | `deploy` | Same with `Staging` variant |
| `"dry-run adb connection"` | `dry-run` | Resolve IP + ADB connect only; no build |
| `"test connection to my phone"` | `dry-run` | Same |
| `"debug deploy"` | `debug` | Build → install → launch suspended (waits for JDWP debugger) |
| `"deploy with debugger"` | `debug` | Same |

**Example output (deploy success):**
```
✅ Deploy complete
────────────────────────────────────────
Device:    my-phone (100.x.x.x:5555)
APK:       Debug › com.example.myapp.debug
Launched:  yes
Logcat:    0 critical line(s) (E/ FATAL)
────────────────────────────────────────
```

**Android Studio integration**: after `adb connect` succeeds, the device appears automatically in Android Studio's device selector — both tools share the same ADB server daemon.

## Project structure

```
tailscale-deploy-adb/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest (name, version, license)
│   └── marketplace.json         # Single-plugin marketplace listing
├── skills/
│   └── tailscale-deploy-adb/
│       ├── SKILL.md             # Claude Code skill instructions
│       ├── references/
│       │   ├── adb-troubleshoot.md   # Wireless ADB cheat-list
│       │   ├── config-schema.md      # Full config field reference
│       │   └── tailscale-resolve.md  # Tailscale peer resolution guide
│       └── scripts/
│           ├── deploy.sh             # ADB connect + Gradle install + launch + logcat
│           └── resolve-device.sh     # Tailscale hostname → IP lookup
├── .gitignore
├── LICENSE                      # Apache 2.0
└── README.md
```

## Troubleshooting

- **`adb connect` fails repeatedly** → see [`references/adb-troubleshoot.md`](skills/tailscale-deploy-adb/references/adb-troubleshoot.md): port mismatch, stale ADB server, phone sleeping, Wireless Debugging toggle
- **Peer not found / offline** → see [`references/tailscale-resolve.md`](skills/tailscale-deploy-adb/references/tailscale-resolve.md): hostname lookup, MagicDNS, Tailscale app state on phone
- **Gradle build fails** → the skill prints the last 50 lines of the build log; fix the compile error and retry
- **Wrong package name** → run `adb shell pm list packages | grep <your-app>` to confirm the installed package name; update `application_id` in `.tailscale-deploy-adb.json`


## Security & privacy

**What the skill touches on your machine:**

- Calls `tailscale status --json` (read-only, local CLI)
- Calls `adb connect`, `adb devices`, `adb shell` — standard Android debug tooling
- Runs `./gradlew install<Variant>` in your project directory
- Reads and writes `.tailscale-deploy-adb.json` in your project root

**What leaves your machine:**

- ADB traffic and Tailscale peer traffic travel through your tailnet — encrypted end-to-end by WireGuard. No traffic goes through any server in this skill.
- Nothing is sent to any external service by this skill itself.

**Config file privacy:**

Your `.tailscale-deploy-adb.json` contains your device's Tailscale hostname and may implicitly reveal your tailnet topology. Do not commit it to version control. Add it to your project's `.gitignore`:

```bash
echo '.tailscale-deploy-adb.json' >> .gitignore
```

The `.gitignore` in **this** repository already excludes `.tailscale-deploy-adb.json` to prevent accidental commits when the repo is used as a skill source.

**Skill code:**

All example values in the skill files are placeholders (`my-phone`, `com.example.myapp`, `tailnet-name.ts.net`, `100.64.1.5`). The skill contains no real hostnames, IPs, email addresses, or credentials.


## License

Apache 2.0 License

```
Copyright (c) [2026] [Andrew Malitchuk]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
