#!/usr/bin/env bash
# start-gitea.sh — use Gitea as a local, read-only viewer for git repos.
#
# Usage: start-gitea.sh [--install-hook] [REPO_PATH]
#
#   REPO_PATH       path to a git repo (default: current directory)
#   --install-hook  also install a post-commit hook in that repo that re-runs
#                   this script after every commit (pushes in the background)
#
# What it does:
#   1. On first run: generates custom/conf/app.ini and a hidden admin account.
#   2. Starts Gitea in the background if it isn't already running.
#   3. Pushes all branches and tags of REPO_PATH to Gitea (creating the repo on
#      first push), sets its default branch, and prints the URL.
#
# Repos are public and browsable without login; registration is disabled, so
# nobody but this script can change anything.

set -euo pipefail

GITEA_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SELF="$GITEA_DIR/$(basename "${BASH_SOURCE[0]}")"
BIN="$GITEA_DIR/gitea"
CONF="$GITEA_DIR/custom/conf/app.ini"
PWFILE="$GITEA_DIR/.admin-password"
LOGFILE="$GITEA_DIR/log/start-gitea.log"
PORT=3000
LOCAL_URL="http://127.0.0.1:$PORT"
OWNER="local"   # Gitea account that owns all repos ("admin" is reserved)
HOOK_MARKER="# installed by start-gitea.sh"

die() { echo "start-gitea: $*" >&2; exit 1; }
log() { echo "start-gitea: $*"; }

gitea() { "$BIN" --work-path "$GITEA_DIR" --config "$CONF" "$@"; }

# ---------------------------------------------------------------- arguments
INSTALL_HOOK=0
REPO_ARG=""
for arg in "$@"; do
  case "$arg" in
    --install-hook) INSTALL_HOOK=1 ;;
    -h|--help) sed -n '2,18p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$REPO_ARG" ]] || die "only one repo path allowed"; REPO_ARG="$arg" ;;
  esac
done
REPO_ARG="${REPO_ARG:-.}"

REPO_PATH="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not a git repository: $REPO_ARG"
REPO_NAME="$(basename "$REPO_PATH" | tr -c 'A-Za-z0-9._\n-' '-')"

[[ -x "$BIN" ]] || die "Gitea binary not found at $BIN
  Download the linux-amd64 binary from https://dl.gitea.com/gitea/ ,
  save it as $BIN and run: chmod +x $BIN"
command -v curl >/dev/null || die "curl is required"
command -v flock >/dev/null || die "flock is required (util-linux)"

mkdir -p "$GITEA_DIR/log"

# Serialize runs (e.g. several quick commits firing the hook at once).
exec 9>"$GITEA_DIR/.start-gitea.lock"
flock 9

# ---------------------------------------------------------------- config
if [[ ! -f "$CONF" ]]; then
  log "creating $CONF"
  mkdir -p "$(dirname "$CONF")"
  vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat >"$CONF" <<EOF
APP_NAME = Repo Viewer
RUN_USER = $(id -un)
RUN_MODE = prod
WORK_PATH = $GITEA_DIR

[server]
HTTP_ADDR = 0.0.0.0
HTTP_PORT = $PORT
ROOT_URL = http://${vm_ip:-localhost}:$PORT/
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = true
LANDING_PAGE = explore

[database]
DB_TYPE = sqlite3
PATH = $GITEA_DIR/data/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = $("$BIN" generate secret SECRET_KEY)
INTERNAL_TOKEN = $("$BIN" generate secret INTERNAL_TOKEN)

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false
SHOW_REGISTRATION_BUTTON = false

[repository]
ENABLE_PUSH_CREATE_USER = true
DEFAULT_PUSH_CREATE_PRIVATE = false
DISABLED_REPO_UNITS = repo.issues, repo.ext_issues, repo.pulls, repo.wiki, repo.ext_wiki, repo.projects, repo.packages, repo.actions

[oauth2]
ENABLED = false

[openid]
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[mailer]
ENABLED = false

[cron.update_checker]
ENABLED = false

[log]
MODE = file
LEVEL = Warn
EOF
  chmod 600 "$CONF"
fi

# ---------------------------------------------------------------- admin user
if ! gitea admin user list --admin 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$OWNER"; then
  log "initialising database and creating account '$OWNER'"
  gitea migrate >/dev/null
  ( umask 077; openssl rand -hex 24 >"$PWFILE" 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$PWFILE" )
  gitea admin user create --admin --username "$OWNER" --email "$OWNER@localhost.local" \
    --password "$(cat "$PWFILE")" --must-change-password=false >/dev/null
fi
PASSWORD="$(cat "$PWFILE")"
AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$OWNER" "$PASSWORD" | base64 -w0)"

# ---------------------------------------------------------------- start server
if ! curl -sf "$LOCAL_URL/api/healthz" >/dev/null; then
  log "starting Gitea (log: $GITEA_DIR/log/)"
  # 9>&- so the background server doesn't hold the lock forever
  nohup "$BIN" --work-path "$GITEA_DIR" --config "$CONF" web \
    >>"$GITEA_DIR/log/stdout.log" 2>&1 9>&- &
  for _ in $(seq 60); do
    curl -sf "$LOCAL_URL/api/healthz" >/dev/null && break
    sleep 0.5
  done
  curl -sf "$LOCAL_URL/api/healthz" >/dev/null \
    || die "Gitea did not come up; see $GITEA_DIR/log/"
fi

# ---------------------------------------------------------------- push repo
log "pushing $REPO_PATH -> $OWNER/$REPO_NAME"
git -C "$REPO_PATH" -c http.extraHeader="$AUTH_HEADER" push --quiet --force --prune \
  "$LOCAL_URL/$OWNER/$REPO_NAME.git" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
  || die "push failed"

# Make Gitea's default branch match the repo's current branch.
if branch="$(git -C "$REPO_PATH" symbolic-ref --quiet --short HEAD)"; then
  curl -sf -X PATCH -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d "{\"default_branch\":\"$branch\"}" \
    "$LOCAL_URL/api/v1/repos/$OWNER/$REPO_NAME" >/dev/null \
    || log "warning: could not set default branch to $branch"
fi

# ---------------------------------------------------------------- hook
if (( INSTALL_HOOK )); then
  hooks_dir="$(cd "$REPO_PATH" && git rev-parse --path-format=absolute --git-path hooks)"
  hook="$hooks_dir/post-commit"
  if [[ -e "$hook" ]] && ! grep -qF "$HOOK_MARKER" "$hook"; then
    log "warning: $hook already exists and wasn't made by this script; not touching it"
  else
    mkdir -p "$hooks_dir"
    cat >"$hook" <<EOF
#!/bin/sh
$HOOK_MARKER — pushes each commit to the local Gitea viewer.
# Delete this file to stop.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
"$SELF" "\$(git rev-parse --show-toplevel)" >>"$LOGFILE" 2>&1 &
EOF
    chmod +x "$hook"
    log "installed post-commit hook: $hook"
  fi
fi

ROOT_URL="$(sed -n 's/^ROOT_URL *= *//p' "$CONF")"
log "ready: ${ROOT_URL%/}/$OWNER/$REPO_NAME"
