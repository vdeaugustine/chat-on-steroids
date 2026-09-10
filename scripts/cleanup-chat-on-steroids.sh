#!/usr/bin/env bash
# Finds and stops every running copy of THIS app — dev mode (electron-vite, launched
# from this repo's node_modules) and any packaged "Chat On Steroids.app" build,
# wherever it's installed — plus any cloudflared/tunnel-client child process it left
# behind. Useful when a stray instance is holding the single-instance lock and a
# fresh `npm run dev` or scripts/quick-cloudflare-tunnel.sh refuses to start.
#
# Every pattern below is specific to this app's own binaries (its repo path or its
# product name "Chat On Steroids" / appId com.chatonsteroids.app). It never matches
# on generic terms like "electron" or "cloudflared" alone, so it cannot catch some
# other app's Electron process or some other project's tunnel.
#
# Usage:
#   scripts/cleanup-chat-on-steroids.sh          # list matches, ask before killing
#   scripts/cleanup-chat-on-steroids.sh --yes    # kill without asking
#   scripts/cleanup-chat-on-steroids.sh --list   # only list, never kill

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# One pattern per line, each anchored to something unique to this app.
PATTERNS=(
  "$REPO_DIR/node_modules/.*/electron/dist/Electron.app"          # dev-mode Electron
  "$REPO_DIR/node_modules/.*electron-vite/bin/electron-vite.js"   # dev-mode vite/main build
  "$REPO_DIR/resources/tunnel/cloudflared"                        # dev-mode quick tunnel
  "$REPO_DIR/resources/tunnel/tunnel-client"                      # dev-mode OpenAI tunnel
  "Chat On Steroids\.app/Contents/MacOS/Chat On Steroids"          # packaged app, any location
  "Chat On Steroids\.app/Contents/Resources.*cloudflared"          # packaged quick tunnel
  "Chat On Steroids\.app/Contents/Resources.*tunnel-client"        # packaged OpenAI tunnel
)

mode="${1:-}"

collect_pids() {
  local all=""
  for pattern in "${PATTERNS[@]}"; do
    all="$all $(pgrep -f "$pattern" 2>/dev/null || true)"
  done
  # De-duplicate, drop blanks.
  echo "$all" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un || true
}

pids="$(collect_pids)"

if [ -z "$pids" ]; then
  echo "No running copy of Chat On Steroids found."
  exit 0
fi

echo "Found running Chat On Steroids process(es):"
for pid in $pids; do
  # ps may race a process that exits between pgrep and here; ignore that quietly.
  ps -p "$pid" -o pid=,etime=,command= 2>/dev/null | sed 's/^/  /' || true
done

if [ "$mode" = "--list" ]; then
  exit 0
fi

if [ "$mode" != "--yes" ] && [ "$mode" != "-y" ]; then
  read -r -p "Stop these? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Left running."; exit 0 ;;
  esac
fi

for pid in $pids; do
  kill "$pid" 2>/dev/null || true
done
sleep 2

remaining="$(collect_pids)"
if [ -n "$remaining" ]; then
  echo "Some processes ignored SIGTERM, forcing:"
  for pid in $remaining; do
    ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/  /' || true
    kill -9 "$pid" 2>/dev/null || true
  done
fi

echo "Done."
