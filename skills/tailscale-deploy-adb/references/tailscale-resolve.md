# Tailscale Device Resolution

## How it works

`resolve-device.sh` calls `tailscale status --json`, finds the peer whose `HostName` field matches `device_hostname` from config, checks `Online: true`, and returns `TailscaleIPs[0]`.

If the primary lookup fails, it falls back to `tailscale ip -4 <hostname>` — this works when MagicDNS is enabled and the device is reachable via its DNS name.

## Tailscale CLI on macOS

The Tailscale macOS app (App Store) does not automatically add the CLI to PATH. Fix once:

```bash
sudo ln -s /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale
```

Verify:
```bash
tailscale version
tailscale status
```

## MagicDNS

If your tailnet has MagicDNS enabled (Tailscale admin console → DNS → Enable MagicDNS), you can reach devices by hostname directly:

```bash
tailscale ping my-phone          # round-trip test
ping my-phone.tailnet-name.ts.net
```

This also means `adb connect my-phone.tailnet-name.ts.net 5555` works without an IP lookup — useful for manual debugging.

## Find your device hostname

```bash
tailscale status
```

The hostname appears in the first column. Example output:
```
100.64.1.5   my-phone            user@  android  -
```

Use `my-phone` as `device_hostname` in `.tailscale-deploy-adb.json`.

## Troubleshooting

### Peer not found (exit 1)
- Tailscale never connected from this device → open Tailscale app on phone and connect to tailnet
- Hostname changed after a factory reset or OS reinstall → re-check with `tailscale status`
- Device is on a different tailnet → check both devices are in the same tailnet

### Peer offline (exit 2)
Possible causes:
1. **Tailscale disabled on phone** → open Tailscale app → connect
2. **Phone screen off / deep sleep** → wake phone, unlock screen
3. **Wi-Fi and cellular both off** → phone needs any internet connection for Tailscale
4. **Tailscale background app kill** → Android may kill Tailscale; open app to reconnect

Quick check from Mac:
```bash
tailscale ping <device_hostname>   # if it replies, the device is reachable
```

### Tailscale not running on Mac (exit 3)
Open Tailscale from the menu bar or:
```bash
open -a Tailscale
```

Wait ~5s for it to connect, then retry the skill.
