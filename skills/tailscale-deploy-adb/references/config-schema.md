# Config Schema: `.tailscale-deploy-adb.json`

Place this file in the Android project root (same directory as `gradlew`).

## Full schema

```json
{
  "device_hostname": "<string, required>",
  "application_id":  "<string, required>",
  "main_activity":   "<string, required>",
  "variant":         "<string, default: 'Debug'>",
  "adb_port":        "<integer, default: 5555>",
  "launch_after_install": "<boolean, default: true>",
  "logcat_seconds":  "<integer, default: 10>"
}
```

## Field reference

### `device_hostname` (required)
Tailscale hostname of the target Android device. Find it with:
```bash
tailscale status
# e.g.: 100.64.1.5   my-phone   user@   android   -
```
Use `my-phone` (first column, the short name — not the full MagicDNS FQDN).

### `application_id` (required)
The package name of the installed APK. For a debug build this is often different from the `applicationId` in `build.gradle` because `applicationIdSuffix ".debug"` is common.

Ways to find the actual debug package name:

**Option A** — from build output metadata (after at least one local build):
```bash
cat app/build/outputs/apk/debug/output-metadata.json | grep applicationId
```

**Option B** — from installed packages on device (device must be connected):
```bash
adb shell pm list packages | grep your-app-name
```

**Option C** — read `app/build.gradle` or `app/build.gradle.kts`:
```kotlin
android {
    defaultConfig {
        applicationId = "com.example.myapp"   // base ID
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".debug"    // → com.example.myapp.debug
        }
    }
}
```

### `main_activity` (required)
Fully qualified class name of the launcher Activity. Find it in `app/src/main/AndroidManifest.xml`:
```xml
<activity android:name=".MainActivity">
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>
</activity>
```
If `android:name` is relative (`.MainActivity`), prepend the `package` attribute from the `<manifest>` tag:
`com.example.myapp.MainActivity`

Always use the fully qualified name — `am start -n` accepts both forms but the full name is unambiguous.

### `variant`
Gradle build variant name, capitalized. Examples: `Debug`, `Release`, `Staging`.
The skill runs `./gradlew install<variant>` — so `Debug` → `./gradlew installDebug`.

### `adb_port`
TCP port for Wireless ADB. Default is `5555` after running `adb tcpip 5555`.
See `adb-troubleshoot.md` for how to fix this port permanently (until next reboot).

### `launch_after_install`
If `true`, the skill runs `adb shell am start -n <application_id>/<main_activity>` after install.
Set to `false` if you only want to install without auto-launching (e.g., the app auto-starts via a service or you want to launch manually).

### `logcat_seconds`
Number of seconds to tail logcat after launch (filtered by app PID).
- `0` → skip logcat entirely
- `10` → default, enough to catch startup crashes
- `30` → useful when testing flows that take a few seconds to complete

## Example configs

**Standard debug with `.debug` suffix:**
```json
{
  "device_hostname": "my-phone",
  "application_id": "com.example.foobar.debug",
  "main_activity": "com.example.foobar.MainActivity",
  "variant": "Debug",
  "adb_port": 5555,
  "launch_after_install": true,
  "logcat_seconds": 10
}
```

**App without `applicationIdSuffix` (same ID for all variants):**
```json
{
  "device_hostname": "my-phone",
  "application_id": "com.example.foobar",
  "main_activity": "com.example.foobar.ui.MainActivity",
  "variant": "Debug",
  "adb_port": 5555,
  "launch_after_install": true,
  "logcat_seconds": 15
}
```

**Install-only, no auto-launch, no logcat:**
```json
{
  "device_hostname": "my-phone",
  "application_id": "com.example.foobar.debug",
  "main_activity": "com.example.foobar.MainActivity",
  "variant": "Debug",
  "adb_port": 5555,
  "launch_after_install": false,
  "logcat_seconds": 0
}
```
