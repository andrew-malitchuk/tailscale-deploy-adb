#!/usr/bin/env bash
set -euo pipefail

# Usage: resolve-device.sh <hostname>
# Output: Tailscale IP address on stdout
# Exit codes:
#   0 — success, IP printed to stdout
#   1 — peer not found in Tailscale
#   2 — peer found but offline
#   3 — tailscale CLI unavailable or not running

usage() {
  echo "Usage: $(basename "$0") <hostname>" >&2
  echo "  hostname: Tailscale device HostName (from 'tailscale status')" >&2
  exit 1
}

[ $# -lt 1 ] && usage
HOSTNAME_ARG="$1"

# ── Validate tailscale CLI ─────────────────────────────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
  echo "Error: 'tailscale' not found in PATH." >&2
  echo "macOS fix: sudo ln -s /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale" >&2
  exit 3
fi

# ── Fetch Tailscale status JSON ────────────────────────────────────────────────
STATUS_JSON=$(tailscale status --json 2>&1) || {
  echo "Error: 'tailscale status' failed. Is Tailscale running? Try: open -a Tailscale" >&2
  exit 3
}

# ── Look up peer by HostName ───────────────────────────────────────────────────
# Extract "online<TAB>ip" for the matching peer (first match if duplicates)
PEER_RESULT=$(echo "$STATUS_JSON" | jq -r --arg h "$HOSTNAME_ARG" \
  '(.Peer // {}) | to_entries[] | .value
   | select(.HostName == $h)
   | "\(.Online)\t\(.TailscaleIPs[0])"' 2>/dev/null | head -1) || PEER_RESULT=""

if [ -z "$PEER_RESULT" ]; then
  # ── MagicDNS fallback ──────────────────────────────────────────────────────
  MAGIC_IP=$(tailscale ip -4 "$HOSTNAME_ARG" 2>/dev/null || true)
  if [ -n "$MAGIC_IP" ]; then
    echo "$MAGIC_IP"
    exit 0
  fi
  echo "Error: Peer '$HOSTNAME_ARG' not found in Tailscale." >&2
  echo "Run 'tailscale status' to see available peers and verify the hostname." >&2
  exit 1
fi

# ── Parse online status and IP ─────────────────────────────────────────────────
ONLINE=$(echo "$PEER_RESULT" | cut -f1)
DEVICE_IP=$(echo "$PEER_RESULT" | cut -f2)

if [ "$ONLINE" != "true" ]; then
  echo "Error: Device '$HOSTNAME_ARG' is offline in Tailscale." >&2
  echo "Check: Tailscale active on phone? Phone not sleeping?" >&2
  exit 2
fi

if [ -z "$DEVICE_IP" ] || [ "$DEVICE_IP" = "null" ]; then
  echo "Error: Peer '$HOSTNAME_ARG' found but has no IP address assigned." >&2
  exit 1
fi

echo "$DEVICE_IP"
