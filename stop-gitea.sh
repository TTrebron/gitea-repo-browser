#!/usr/bin/env bash
# stop-gitea.sh — stop the Gitea server started by start-gitea.sh.
# Can be run from any directory.

set -euo pipefail

GITEA_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="$GITEA_DIR/gitea"

# Match only the server for this directory (as launched by start-gitea.sh).
pattern="^$BIN --work-path $GITEA_DIR .* web"

pids="$(pgrep -f -- "$pattern" || true)"
if [[ -z "$pids" ]]; then
  echo "stop-gitea: Gitea is not running"
  exit 0
fi

echo "stop-gitea: stopping Gitea (pid $(echo $pids))"
kill $pids

# Gitea shuts down gracefully on SIGTERM; give it up to 15s.
for _ in $(seq 30); do
  pgrep -f -- "$pattern" >/dev/null || { echo "stop-gitea: stopped"; exit 0; }
  sleep 0.5
done

echo "stop-gitea: still running after 15s, forcing"
pkill -KILL -f -- "$pattern" || true
echo "stop-gitea: stopped"
