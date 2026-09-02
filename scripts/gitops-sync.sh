#!/usr/bin/env bash
###############################################################################
# gitops-sync.sh — Pull from git and apply changes automatically
#
# Called by gitops-sync.timer every 5 minutes. GITOPS_SERVER_DIR (set in the
# unit, docker/<hostname>) selects which server's stacks to manage.
#
# What it does:
#   1. git pull the repo
#   2. Sync secrets from 1Password → .env files
#   3. For each stack that changed → docker compose up -d
#   4. If OS config files changed → install + reload (coreos/os-configs/manifest.conf)
#   5. Notify Discord on failure, once per failure streak, and once on recovery
#
# gitops-sync.sh --apply-os-configs
#   Skip the pull and treat every manifest entry as changed. For a host that
#   predates a unit or when the manifest itself was restructured; bootstrap.sh
#   runs it on a fresh host. Enabling new units is still a manual step.
###############################################################################
set -euo pipefail

REPO_DIR="/srv"
LOCK_FILE="/tmp/gitops-sync.lock"
FAIL_FLAG="/tmp/gitops-sync.failed"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="/etc/1password-service-account.env"
VAULT="Homelab"
OP_ITEM="gitops"

log() { echo "[gitops-sync] $*"; }

APPLY_ALL=0
[[ "${1:-}" == "--apply-os-configs" ]] && APPLY_ALL=1

# Load Discord notification helper if available
if [[ -f "$SCRIPT_DIR/notify.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/notify.sh"
else
  notify() { :; }  # no-op if helper not available
fi

# Prevent concurrent runs. Use flock's command mode with --close so long-lived
# child processes, such as `op daemon`, cannot inherit and retain the lock.
if [[ "${GITOPS_SYNC_LOCKED:-}" != "1" ]]; then
  if flock -n -E 75 --close "$LOCK_FILE" env GITOPS_SYNC_LOCKED=1 /bin/bash "$0" "$@"; then
    exit 0
  fi

  status=$?
  if [[ "$status" -eq 75 ]]; then
    log "Another sync is already running, skipping"
    exit 0
  fi
  exit "$status"
fi

###############################################################################
# Failure notification
#
# Anything that trips `set -e` (a pull that can't fast-forward, a missing
# `op`, a bad manifest) used to exit silently: the unit failed before it
# reached its own notify call, and powder sat four months behind main that
# way. The ERR trap fires once per failure streak; the flag is cleared and a
# recovery message sent the next time a run completes.
###############################################################################
on_error() {
  local rc=$1 line=$2
  log "ERROR: exit $rc at line $line"
  if [[ ! -f "$FAIL_FLAG" ]]; then
    notify critical "GitOps sync failed" \
      "gitops-sync.sh exited $rc at line $line. Check: journalctl -u gitops-sync.service"
    touch "$FAIL_FLAG"
  fi
  exit "$rc"
}
trap 'on_error $? $LINENO' ERR

mark_ok() {
  if [[ -f "$FAIL_FLAG" ]]; then
    rm -f "$FAIL_FLAG"
    notify success "GitOps sync recovered" "Sync completed normally again"
  fi
}

cd "$REPO_DIR"

if [[ ! -d .git ]]; then
  log "ERROR: $REPO_DIR is not a git repository"
  exit 1
fi

###############################################################################
# Determine which server this is
###############################################################################
HOSTNAME=$(hostname -s)
SERVER_DIR="${GITOPS_SERVER_DIR:-docker/$HOSTNAME}"

if [[ ! -d "$REPO_DIR/$SERVER_DIR" ]]; then
  log "ERROR: Server directory $REPO_DIR/$SERVER_DIR does not exist"
  exit 1
fi

log "Server: $SERVER_DIR (host: $HOSTNAME)"

###############################################################################
# SSH identity from 1Password
###############################################################################
# Fetch the deploy key from 1Password so git pull can authenticate.
# The key lives in a tmpfile that is cleaned up on exit.
SSH_KEY_FILE=""
cleanup() { [[ -n "$SSH_KEY_FILE" ]] && rm -f "$SSH_KEY_FILE"; }
trap cleanup EXIT

setup_git_ssh() {
  # Load 1Password service account token
  if [[ -f "$TOKEN_FILE" ]]; then
    if ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$TOKEN_FILE"; then
      log "ERROR: $TOKEN_FILE has unexpected format"
      return 1
    fi
    # shellcheck disable=SC1090
    source "$TOKEN_FILE"
    export OP_SERVICE_ACCOUNT_TOKEN
  elif [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    log "WARNING: No 1Password token — using system SSH config for git"
    return 0
  fi

  if ! command -v op &>/dev/null; then
    log "WARNING: 1Password CLI (op) not found — using system SSH config for git"
    return 0
  fi

  SSH_KEY_FILE=$(mktemp /tmp/gitops-ssh-XXXXXX)
  chmod 600 "$SSH_KEY_FILE"

  if ! op read "op://$VAULT/$OP_ITEM/SSH_DEPLOY_KEY" > "$SSH_KEY_FILE" 2>/dev/null; then
    rm -f "$SSH_KEY_FILE"
    SSH_KEY_FILE=""
    log "WARNING: Could not read deploy key from 1Password ($VAULT/$OP_ITEM/SSH_DEPLOY_KEY) — using system SSH config"
    return 0
  fi

  export GIT_SSH_COMMAND="ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  log "Using SSH deploy key from 1Password"
}

FAILED_STACKS=()
if [[ $APPLY_ALL -eq 1 ]]; then
  BEFORE=$(git rev-parse HEAD)
  AFTER=$BEFORE
  CHANGED_FILES=$(git ls-files coreos/os-configs)
  log "Applying every OS config in the manifest (--apply-os-configs)"
else

setup_git_ssh

###############################################################################
# Step 1: Pull changes
###############################################################################
BEFORE=$(git rev-parse HEAD)

git fetch --quiet origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse '@{u}')

if [[ "$LOCAL" == "$REMOTE" ]]; then
  log "Already up to date ($LOCAL)"
  mark_ok
  exit 0
fi

log "Changes detected: $LOCAL → $REMOTE"
git pull --quiet --ff-only origin

AFTER=$(git rev-parse HEAD)
CHANGED_FILES=$(git diff --name-only "$BEFORE" "$AFTER")
log "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'

###############################################################################
# Step 2: Sync secrets from 1Password
###############################################################################
# Pull latest secrets into .env files before restarting stacks, so new
# env vars added in the pull are populated before docker compose reads them.
if [[ -f "$SCRIPT_DIR/sync-secrets.sh" ]]; then
  log "Syncing secrets from 1Password..."
  if ! "$SCRIPT_DIR/sync-secrets.sh" 2>&1; then
    log "WARNING: Secret sync failed — continuing with existing .env files"
  fi
else
  log "WARNING: sync-secrets.sh not found — skipping secret sync"
fi

###############################################################################
# Step 3: Apply Docker stack changes
###############################################################################
STACKS_TO_UPDATE=()

for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
  [[ -f "$stack_dir/docker-compose.yml" ]] || continue
  stack_name=$(basename "$stack_dir")
  rel_path="$SERVER_DIR/$stack_name"

  if echo "$CHANGED_FILES" | grep -q "^$rel_path/"; then
    STACKS_TO_UPDATE+=("$stack_dir")
    log "Stack changed: $stack_name"
  fi
done

# A failing subshell used to trip `set -e` before the failure was recorded,
# so the "N stacks failed" notification below was unreachable. Test it inline.
for stack_dir in "${STACKS_TO_UPDATE[@]}"; do
  stack_name=$(basename "$stack_dir")
  log "Updating stack: $stack_name"
  if (
    cd "$stack_dir"
    docker compose config --quiet
    docker compose pull --quiet --ignore-buildable 2>&1 | grep -v "up to date" || true
    docker compose up -d --build --remove-orphans 2>&1
  ); then
    log "Stack updated: $stack_name"
  else
    log "ERROR: Stack failed: $stack_name"
    FAILED_STACKS+=("$stack_name")
  fi
done

if [[ ${#FAILED_STACKS[@]} -gt 0 ]]; then
  log "WARNING: ${#FAILED_STACKS[@]} stack(s) failed to update: ${FAILED_STACKS[*]}"
fi

if [[ ${#STACKS_TO_UPDATE[@]} -eq 0 ]]; then
  log "No stack changes for $SERVER_DIR"
fi

fi  # APPLY_ALL

###############################################################################
# Step 4: Apply OS config changes
#
# Reads coreos/os-configs/manifest.conf for file mappings. Scope is the
# first path component of the source: none or common/ applies everywhere,
# <hostname>/ applies only to that host.
###############################################################################
MANIFEST="$REPO_DIR/coreos/os-configs/manifest.conf"
OS_CONFIGS_DIR="$REPO_DIR/coreos/os-configs"
declare -A RELOAD_ACTIONS
CHANGED_TIMERS=()

apply_os_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || { log "WARNING: manifest source missing: $src"; return 1; }
  if [[ -f "$dest" ]] && diff -q "$src" "$dest" >/dev/null 2>&1; then
    return 1
  fi
  log "Updating OS config: $dest"
  sudo install -D -m "$mode" "$src" "$dest"
}

if [[ -f "$MANIFEST" ]] && echo "$CHANGED_FILES" | grep -q "^coreos/os-configs/"; then
  while read -r src dest mode action; do
    [[ -z "$src" || "$src" == \#* ]] && continue

    if [[ "$src" == */* ]]; then
      scope="${src%%/*}"
      [[ "$scope" == "common" || "$scope" == "$HOSTNAME" ]] || continue
    fi

    if ! echo "$CHANGED_FILES" | grep -qx "coreos/os-configs/$src"; then
      continue
    fi

    if apply_os_file "$OS_CONFIGS_DIR/$src" "$dest" "${mode:-0644}"; then
      [[ -n "${action:-}" ]] && RELOAD_ACTIONS["$action"]=1
      [[ "$dest" == *.timer ]] && CHANGED_TIMERS+=("$(basename "$dest")")
    fi
  done < "$MANIFEST"

  reload() {
    local name="$1"; shift
    log "Reloading $name..."
    if "$@"; then log "  $name OK"; else log "  ERROR: $name reload failed"; fi
  }
  [[ -n "${RELOAD_ACTIONS[sysctl]:-}" ]]  && reload sysctl sudo sysctl --system --quiet
  [[ -n "${RELOAD_ACTIONS[docker]:-}" ]]  && reload docker sudo systemctl reload docker
  [[ -n "${RELOAD_ACTIONS[sshd]:-}" ]]    && reload sshd sudo systemctl reload sshd
  if [[ -n "${RELOAD_ACTIONS[systemd]:-}" ]]; then
    reload systemd sudo systemctl daemon-reload
    # A changed timer only picks up a new schedule when restarted. Services
    # pick up changes on their next run. try-restart is a no-op for timers
    # that are not enabled, so new units still need a one-off enable.
    for t in "${CHANGED_TIMERS[@]}"; do
      reload "$t" sudo systemctl try-restart "$t"
    done
  fi
fi

log "Sync complete: $BEFORE → $AFTER"

# Notify on failure only — successful syncs are silent
if [[ ${#FAILED_STACKS[@]} -gt 0 ]]; then
  notify critical "GitOps sync failed" "${#FAILED_STACKS[@]} stack(s) failed: ${FAILED_STACKS[*]}. Check: journalctl -u gitops-sync.service"
  exit 1
fi
mark_ok
exit 0
