#!/usr/bin/env bash
# Runs Chat On Steroids with a temporary Cloudflare quick tunnel (*.trycloudflare.com),
# instead of walking through Connection settings by hand every time.
#
# What it does:
#   1. Points the app's config at tunnel.kind=cloudflared and ui.autoConnect=true
#      (the original config is backed up and restored on `stop`).
#   2. Launches the app in dev mode (electron-vite dev) in the background.
#   3. Waits for the app to spawn cloudflared and report a public URL, which the
#      app writes to a status file because CLF_TUNNEL_URL_FILE is set (opt-in hook
#      in src/main/tunnel/index.ts, off unless this env var is set).
#   4. Prints the URL (and copies it to the clipboard on macOS) so you can paste it
#      as the MCP server URL when creating the custom connector in ChatGPT.
#
# The hostname is random and changes every run — that's inherent to Cloudflare quick
# tunnels, not something this script can fix. Re-run `start` each session.
#
# Usage:
#   scripts/quick-cloudflare-tunnel.sh start
#   scripts/quick-cloudflare-tunnel.sh status
#   scripts/quick-cloudflare-tunnel.sh stop
#
# This script is specific to this repo (it patches this app's own config and
# launches its own dev server) — unlike a generic tunnel helper, it isn't meant to
# be copied to other projects.
#
# Electron only allows one running copy of this app per user-data dir, so if a copy
# is already running (started by hand, by an IDE task, or by a previous run of this
# script), a second one launched here would immediately quit. `start` checks for
# that first — scripts/cleanup-chat-on-steroids.sh lists/stops running copies of
# THIS app specifically; it never touches an unrelated app.
#
# Port 5173 (the dev-mode Vite server) is separate from that: electron-vite already
# picks the next free port on its own if 5173 is taken, without killing anything.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${CLF_QUICK_TUNNEL_STATE:-$HOME/.chat-on-steroids-quick-tunnel}"
PID_FILE="$STATE_DIR/dev.pid"
LOG_FILE="$STATE_DIR/dev.log"
URL_FILE="$STATE_DIR/tunnel-url.txt"
CONFIG_BACKUP="$STATE_DIR/config.json.bak"

case "$(uname -s)" in
  Darwin) APP_CONFIG_DIR="$HOME/Library/Application Support/chat-on-steroids" ;;
  Linux) APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/chat-on-steroids" ;;
  *) echo "Unsupported OS for this script: $(uname -s). Set APP_CONFIG_DIR yourself and re-run." >&2; exit 1 ;;
esac
APP_CONFIG_DIR="${CLF_APP_CONFIG_DIR:-$APP_CONFIG_DIR}"
CONFIG_FILE="$APP_CONFIG_DIR/config.json"

# Same patterns as cleanup-chat-on-steroids.sh: only ever matches this app's own
# binaries (this repo's path, or the packaged app's product name/appId), never a
# generic term that could catch some other app.
APP_PATTERNS=(
  "$REPO_DIR/node_modules/.*/electron/dist/Electron.app"
  "$REPO_DIR/node_modules/.*electron-vite/bin/electron-vite.js"
  "Chat On Steroids\.app/Contents/MacOS/Chat On Steroids"
)

other_instance_pids() {
  local all=""
  for pattern in "${APP_PATTERNS[@]}"; do
    all="$all $(pgrep -f "$pattern" 2>/dev/null || true)"
  done
  echo "$all" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un || true
}

usage() {
  cat <<'EOF'
quick-cloudflare-tunnel.sh — run Chat On Steroids behind a temporary Cloudflare tunnel

Commands:
  start    Patch config for cloudflared+autoConnect, launch the app, wait for the URL
  status   Show whether it's running and the last known public URL
  stop     Stop the app and restore your previous connection settings
  help     Show this message

Environment:
  CLF_QUICK_TUNNEL_STATE   State dir for pid/log/url files (default: ~/.chat-on-steroids-quick-tunnel)
  CLF_APP_CONFIG_DIR       Override the app's config directory (auto-detected per OS otherwise)
EOF
}

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

patch_config() {
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const cfg = JSON.parse(fs.readFileSync(path, "utf8"));
    cfg.tunnel = cfg.tunnel || {};
    cfg.tunnel.kind = "cloudflared";
    cfg.ui = cfg.ui || {};
    cfg.ui.autoConnect = true;
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n", "utf8");
  ' "$CONFIG_FILE"
}

cmd_start() {
  if is_running; then
    echo "Already running (pid $(cat "$PID_FILE")). Run 'stop' first, or 'status' to see the URL."
    exit 1
  fi

  running_elsewhere="$(other_instance_pids)"
  if [ -n "$running_elsewhere" ]; then
    echo "Chat On Steroids is already running (started outside this script), so a second"
    echo "copy would immediately quit — it only allows one instance at a time. Process(es):"
    for pid in $running_elsewhere; do
      ps -p "$pid" -o pid=,etime=,command= 2>/dev/null | sed 's/^/  /' || true
    done
    echo ""
    echo "Stop it first: scripts/cleanup-chat-on-steroids.sh"
    exit 1
  fi

  mkdir -p "$STATE_DIR"
  rm -f "$URL_FILE"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config found at $CONFIG_FILE yet."
    echo "Open the app once (npm run dev), approve a project folder, then re-run this script."
    exit 1
  fi

  cp "$CONFIG_FILE" "$CONFIG_BACKUP"
  patch_config
  echo "Config patched: tunnel.kind=cloudflared, ui.autoConnect=true"
  echo "(original saved at $CONFIG_BACKUP, restored on 'stop')"

  echo "Starting Chat On Steroids…"
  ( cd "$REPO_DIR" && CLF_TUNNEL_URL_FILE="$URL_FILE" nohup npm run dev > "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE" )

  echo -n "Waiting for the quick tunnel URL"
  url=""
  for _ in $(seq 1 90); do
    if [ -s "$URL_FILE" ]; then
      url="$(tr -d '[:space:]' < "$URL_FILE")"
      break
    fi
    if ! is_running; then
      echo ""
      echo "The app process exited before a tunnel came up. Log tail:"
      tail -n 40 "$LOG_FILE" || true
      cp "$CONFIG_BACKUP" "$CONFIG_FILE"
      exit 1
    fi
    echo -n "."
    sleep 1
  done
  echo ""

  if [ -z "$url" ]; then
    echo "No URL after 90s. Log tail:"
    tail -n 40 "$LOG_FILE" || true
    echo "The app window may still be waiting on a permission dialog — check it, then run 'status'."
    exit 1
  fi

  echo ""
  echo "========================================================================"
  echo " Public MCP URL (paste into ChatGPT's custom connector):"
  echo ""
  echo " $url"
  echo ""
  echo " Log:  $LOG_FILE"
  echo " Stop: scripts/quick-cloudflare-tunnel.sh stop"
  echo ""
  echo " This hostname is random and changes every run."
  echo "========================================================================"

  if command -v pbcopy > /dev/null 2>&1; then
    printf '%s' "$url" | pbcopy
    echo "(copied to clipboard)"
  fi
}

cmd_status() {
  if is_running; then
    echo "Process: running (pid $(cat "$PID_FILE"))"
  else
    echo "Process: not running"
  fi

  if [ -s "$URL_FILE" ]; then
    url="$(tr -d '[:space:]' < "$URL_FILE")"
    echo "URL: $url"
    if curl -s -m 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -q '^[23]'; then
      echo "Reachability: OK"
    else
      echo "Reachability: not responding (it may need a valid MCP request, not a bare GET — this is only a rough check)"
    fi
  else
    echo "URL: none saved. Start with: scripts/quick-cloudflare-tunnel.sh start"
  fi
}

cmd_stop() {
  stopped=0
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE")"
    if kill "$pid" 2>/dev/null; then
      stopped=1
    fi
    rm -f "$PID_FILE"
  fi
  # electron-vite dev spawns Electron as a child; the app's own shutdown path handles
  # tearing down cloudflared, but make sure nothing from this repo is left running.
  pkill -f "$REPO_DIR/node_modules/.*/electron/dist/Electron.app" 2>/dev/null && stopped=1 || true
  pkill -f "$REPO_DIR/node_modules/.*electron-vite/bin/electron-vite.js dev" 2>/dev/null && stopped=1 || true

  if [ -f "$CONFIG_BACKUP" ]; then
    cp "$CONFIG_BACKUP" "$CONFIG_FILE"
    echo "Restored previous connection settings."
  fi
  rm -f "$URL_FILE"

  if [ "$stopped" = "1" ]; then
    echo "Stopped."
  else
    echo "Nothing was running."
  fi
}

main() {
  cmd="${1:-start}"
  case "$cmd" in
    start) cmd_start ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
    help|-h|--help) usage ;;
    *)
      echo "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
