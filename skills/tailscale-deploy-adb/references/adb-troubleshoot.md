# ADB Wireless Debugging — Troubleshooting

## Fix the Wireless ADB port (do this once per device)

By default Android randomizes the ADB port after every pairing. Fix it to 5555 via USB:

```bash
# 1. Connect phone via USB, confirm USB debugging is authorized
adb devices                  # should show device in 'device' state

# 2. Switch to TCP/IP mode on port 5555
adb tcpip 5555

# 3. Disconnect USB — ADB now listens on port 5555
# 4. Connect wirelessly (replace IP with actual device IP on your LAN)
adb connect 192.168.x.x:5555
```

**After phone reboot**: ADB TCP port resets. Reconnect USB and repeat step 2 before using the skill again.

**With Tailscale**: replace the LAN IP with the Tailscale IP from `tailscale status`.

## adb connect failure cheat-list

If `adb connect <ip>:5555` fails or returns `failed to connect`, check these in order:

1. **Wireless Debugging enabled?**
   Settings → Developer Options → Wireless Debugging → must be ON.
   Note: this toggle can turn off automatically after some Android updates.

2. **Tailscale active on phone?**
   Open Tailscale app on phone. Check it shows "Connected". If the VPN toggle is off, the Tailscale IP is not reachable.

3. **Phone not sleeping?**
   ADB drops when the device screen turns off on some devices. Wake the phone and try again.
   Workaround: Settings → Display → Screen timeout → set to max while testing.

4. **First connection — pairing dialog**
   The first time you connect wirelessly from a new Mac, Android shows a "Allow USB debugging?" dialog on screen. Tap Allow. This only happens once per authorized host.

5. **Stale ADB server**
   If `adb devices` shows the device as `offline` or `unauthorized`:
   ```bash
   adb kill-server
   adb start-server
   adb connect <ip>:5555
   ```
   Then confirm the authorization dialog on the phone.

6. **Port mismatch**
   If you forgot to run `adb tcpip 5555`, the port is random. Check the current port:
   ```bash
   # With phone connected via USB:
   adb shell getprop service.adb.tcp.port
   ```
   Update `adb_port` in `.tailscale-deploy-adb.json` to match, or re-run `adb tcpip 5555`.

7. **Firewall / network isolation**
   Tailscale normally bypasses this, but if you use a custom exit node or ACLs, ensure the Mac can reach the device on port 5555.
   Quick test: `nc -zv <tailscale-ip> 5555`

## adb devices states

| State | Meaning |
|---|---|
| `device` | Connected and authorized — ready for commands |
| `offline` | Device is not responding — wake it or restart ADB server |
| `unauthorized` | Debugging authorization not granted — tap Allow on phone |
| `(no devices)` | No connection attempt succeeded |

The skill's pre-flight check (Step 4) verifies the device is in `device` state before building.

## Verify connection manually

```bash
adb -s <ip>:5555 shell echo "ok"    # should print "ok"
adb -s <ip>:5555 shell getprop ro.product.model
```
