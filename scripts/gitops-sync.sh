#!/usr/bin/env bash
###############################################################################
# gitops-sync.sh — Pull from git and apply changes automatically
#
# Called by the gitops-sync.timer systemd unit every 5 minutes.
# Requires GITOPS_SERVER_DIR to be set (in the systemd unit) to identify
# which server's stacks to manage.
#
# What it does:
#   1. git pull the repo
#   2. Sync secrets from 1Password → .env files
#   3. For each stack changed since the last applied commit → docker compose up -d
#   4. If OS config files changed → apply + reload
#   5. Logs everything to journald
#
# The last fully applied commit is kept in refs/gitops-sync/applied and only
# advances when every step succeeded, so a failed run retries on the next tick.
###############################################################################
set -euo pipefail

REPO_DIR="/srv"
LOCK_FILE="/tmp/gitops-sync.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="/etc/1password-service-account.env"
VAULT="Homelab"
OP_ITEM="gitops"

log() { echo "[gitops-sync] $*"; }
indent() { sed 's/^/  /'; }

# Load Discord notification helper if available
if [[ -f "$SCRIPT_DIR/notify.sh" ]]; then
  source "$SCRIPT_DIR/notify.sh"
else
  notify() { :; }  # no-op if helper not available
fi

# Prevent concurrent runs. Use flock's command mode with --close so long-lived
# child processes, such as `op daemon`, cannot inherit and retain the lock.
if [[ "${GITOPS_SYNC_LOCKED:-}" != "1" ]]; then
  status=0
  flock -n -E 75 --close "$LOCK_FILE" env GITOPS_SYNC_LOCKED=1 /bin/bash "$0" "$@" || status=$?
  if [[ "$status" -eq 75 ]]; then
    log "Another sync is already running, skipping"
    exit 0
  fi
  exit "$status"
fi

###############################################################################
# Failure reporting
###############################################################################
# Runs repeat every 5 minutes, so notify once per distinct failure. Any other
# non-zero exit, such as a set -e abort or a config error, gets a generic alert
# from the EXIT trap. A successful run clears the marker.
FAILURE_MARKER="/tmp/gitops-sync.failed"
FAILURE_REPORTED=0
SSH_KEY_FILE=""

notify_failure() {
  local key="$1" title="$2" message="$3"
  FAILURE_REPORTED=1
  if [[ "$(cat "$FAILURE_MARKER" 2>/dev/null)" != "$key" ]]; then
    notify critical "$title" "$message"
    echo "$key" > "$FAILURE_MARKER"
  fi
}

# shellcheck disable=SC2329  # called from the EXIT trap
on_exit() {
  local status=$?
  [[ -n "$SSH_KEY_FILE" ]] && rm -f "$SSH_KEY_FILE"
  if [[ "$status" -eq 0 ]]; then
    rm -f "$FAILURE_MARKER"
  elif [[ "$FAILURE_REPORTED" -eq 0 ]]; then
    notify_failure "unexpected" "GitOps sync failed" "gitops-sync.sh exited $status. Check: journalctl -u gitops-sync.service"
  fi
}
trap on_exit EXIT

cd "$REPO_DIR"

if [[ ! -d .git ]]; then
  log "ERROR: $REPO_DIR is not a git repository"
  exit 1
fi

###############################################################################
# Determine which server this is
###############################################################################
# Every host must set GITOPS_SERVER_DIR in its gitops-sync.service unit.
if [[ -z "${GITOPS_SERVER_DIR:-}" ]]; then
  log "ERROR: GITOPS_SERVER_DIR is not set. Configure it in the gitops-sync.service systemd unit."
  exit 1
fi
SERVER_DIR="$GITOPS_SERVER_DIR"

if [[ ! -d "$REPO_DIR/$SERVER_DIR" ]]; then
  log "ERROR: Server directory $REPO_DIR/$SERVER_DIR does not exist"
  exit 1
fi

log "Server: $SERVER_DIR (host: $(hostname -s))"

###############################################################################
# SSH identity from 1Password
###############################################################################
# Fallback for hosts whose system SSH config can't fetch: load the deploy key
# from 1Password so git can authenticate. Returns 1 if no key could be loaded.
# The key lives in a tmpfile that is cleaned up on exit.
setup_git_ssh() {
  # Load 1Password service account token
  if [[ -f "$TOKEN_FILE" ]]; then
    if ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$TOKEN_FILE"; then
      log "ERROR: $TOKEN_FILE has unexpected format"
      return 1
    fi
    source "$TOKEN_FILE"
    export OP_SERVICE_ACCOUNT_TOKEN
  elif [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    log "WARNING: No 1Password token — no deploy key available"
    return 1
  fi

  if ! command -v op &>/dev/null; then
    log "WARNING: 1Password CLI (op) not found — no deploy key available"
    return 1
  fi

  SSH_KEY_FILE=$(mktemp /tmp/gitops-ssh-XXXXXX)
  chmod 600 "$SSH_KEY_FILE"

  if ! op read "op://$VAULT/$OP_ITEM/SSH_DEPLOY_KEY" > "$SSH_KEY_FILE" 2>/dev/null; then
    rm -f "$SSH_KEY_FILE"
    SSH_KEY_FILE=""
    log "WARNING: Could not read deploy key from 1Password ($VAULT/$OP_ITEM/SSH_DEPLOY_KEY)"
    return 1
  fi

  export GIT_SSH_COMMAND="ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  log "Using SSH deploy key from 1Password"
}

###############################################################################
# Step 1: Pull changes
###############################################################################
# Try the system SSH config first, so a host where it works never spends a
# 1Password request on the deploy key. A failure may just be a network blip, so
# only alert once it has lasted FETCH_ALERT_AFTER runs in a row (about 15 min).
FETCH_FAILURES_FILE="/tmp/gitops-sync.fetch-failures"
FETCH_ALERT_AFTER=3

export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
if ! FETCH_OUTPUT=$(git fetch --quiet origin 2>&1); then
  log "git fetch failed with the system SSH config, trying the deploy key"
  if ! setup_git_ssh || ! FETCH_OUTPUT=$(git fetch --quiet origin 2>&1); then
    log "ERROR: git fetch failed:"
    indent <<< "$FETCH_OUTPUT"
    FETCH_FAILURES=$(( $(cat "$FETCH_FAILURES_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$FETCH_FAILURES" > "$FETCH_FAILURES_FILE"
    FAILURE_REPORTED=1
    if [[ "$FETCH_FAILURES" -ge "$FETCH_ALERT_AFTER" ]]; then
      notify_failure "fetch" "GitOps sync blocked" "git fetch keeps failing, so nothing is deploying to this host. Check: journalctl -u gitops-sync.service"
    fi
    exit 1
  fi
fi
rm -f "$FETCH_FAILURES_FILE"

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse '@{u}')

# The last commit that fully applied. On the first run after this was added,
# start from the current HEAD rather than redeploying every stack.
APPLIED_REF="refs/gitops-sync/applied"
if ! APPLIED=$(git rev-parse --quiet --verify "$APPLIED_REF^{commit}"); then
  log "No applied commit recorded, starting from $LOCAL"
  git update-ref "$APPLIED_REF" "$LOCAL"
  APPLIED=$LOCAL
fi

if [[ "$LOCAL" != "$REMOTE" ]]; then
  log "Changes detected: $LOCAL → $REMOTE"

  # A dirty tree or host-local commit makes the fast-forward fail. Without this
  # check set -e killed the script here, before any notify call, and the host
  # stopped deploying silently. Notify once per target commit, not every run.
  if ! PULL_OUTPUT=$(git merge --quiet --ff-only '@{u}' 2>&1); then
    log "ERROR: git pull failed — $REPO_DIR needs manual reconciliation:"
    indent <<< "$PULL_OUTPUT"
    notify_failure "pull $REMOTE" "GitOps sync blocked" "git pull failed, so nothing is deploying to this host. Check: journalctl -u gitops-sync.service"
    exit 1
  fi
fi

AFTER=$(git rev-parse HEAD)
if [[ "$APPLIED" == "$AFTER" ]]; then
  log "Already up to date ($AFTER)"
  exit 0
fi

log "Applying $APPLIED → $AFTER"
CHANGED_FILES=$(git diff --name-only "$APPLIED" "$AFTER")
log "Changed files:"
indent <<< "$CHANGED_FILES"

###############################################################################
# Step 2: Sync secrets from 1Password
###############################################################################
# Pull latest secrets into .env files before restarting stacks, so new
# env vars added in the pull are populated before docker compose reads them.
# A retry for a failed stack must not re-read every key from 1Password every 5
# minutes, so remember the commit the secrets last synced for.
SECRETS_REF="refs/gitops-sync/secrets-synced"
SECRETS_FAILED=0
if [[ -f "$SCRIPT_DIR/sync-secrets.sh" ]]; then
  if [[ "$(git rev-parse --quiet --verify "$SECRETS_REF" || true)" == "$AFTER" ]]; then
    log "Secrets already synced for $AFTER"
  else
    log "Syncing secrets from 1Password..."
    if "$SCRIPT_DIR/sync-secrets.sh" 2>&1; then
      git update-ref "$SECRETS_REF" "$AFTER"
    else
      log "ERROR: Secret sync failed — continuing with existing .env files"
      SECRETS_FAILED=1
    fi
  fi
else
  log "WARNING: sync-secrets.sh not found — skipping secret sync"
fi

###############################################################################
# Step 3: Apply Docker stack changes
###############################################################################
# Find all stacks for this server that have changes
STACKS_TO_UPDATE=()

for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
  [[ -f "$stack_dir/docker-compose.yml" ]] || continue
  stack_name=$(basename "$stack_dir")
  rel_path="$SERVER_DIR/$stack_name"

  # Check if any files in this stack changed
  if grep -q "^$rel_path/" <<< "$CHANGED_FILES"; then
    STACKS_TO_UPDATE+=("$stack_dir")
    log "Stack changed: $stack_name"
  fi
done

# Print the .env.example keys that have no value in the stack's .env.
missing_env_keys() {
  local stack_dir="$1" key
  [[ -f "$stack_dir/.env.example" ]] || return 0
  while IFS= read -r key; do
    grep -q "^$key=." "$stack_dir/.env" 2>/dev/null || echo "$key"
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$stack_dir/.env.example")
}

FAILED_STACKS=()
for stack_dir in "${STACKS_TO_UPDATE[@]}"; do
  stack_name=$(basename "$stack_dir")

  # Unset keys are normal after a good sync (optional values), but after a
  # failed one they may just be secrets that never arrived.
  if [[ "$SECRETS_FAILED" -eq 1 ]]; then
    missing=$(missing_env_keys "$stack_dir")
    if [[ -n "$missing" ]]; then
      log "ERROR: Not starting $stack_name, secret sync failed and .env has no value for: ${missing//$'\n'/ }"
      FAILED_STACKS+=("$stack_name")
      continue
    fi
  fi

  log "Updating stack: $stack_name"
  # set -e is ignored inside an if condition, so chain each step explicitly.
  if (
    cd "$stack_dir" &&
    docker compose config --quiet &&
    { docker compose pull --quiet --ignore-buildable 2>&1 | grep -v "up to date" || true; } &&
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

###############################################################################
# Step 4: Apply OS config changes
#
# Reads coreos/os-configs/manifest.conf for file mappings.
# Shared files (no directory prefix) apply to all servers.
# Per-server files (e.g. pancake/motd.sh) apply only to that host.
###############################################################################
HOSTNAME=$(hostname -s)
MANIFEST="$REPO_DIR/coreos/os-configs/manifest.conf"
OS_CONFIGS_DIR="$REPO_DIR/coreos/os-configs"
# A file installed by a run whose reload failed compares as unchanged on the
# retry, so failed reloads are carried over here.
PENDING_RELOADS="$REPO_DIR/.git/gitops-sync-pending-reloads"
declare -A RELOAD_ACTIONS
FAILED_OS_FILES=()
FAILED_RELOADS=()

# Returns 0 if installed, 1 if there was nothing to do, 2 if the install failed.
apply_os_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || return 1
  if [[ -f "$dest" ]] && diff -q "$src" "$dest" >/dev/null 2>&1; then
    return 1
  fi
  log "Updating OS config: $dest"
  sudo install -D -m "$mode" "$src" "$dest" || return 2
}

run_reload() {
  local action="$1"; shift
  [[ -n "${RELOAD_ACTIONS[$action]:-}" ]] || return 0
  log "Running $action reload..."
  if "$@"; then
    log "  $action OK"
  else
    log "  ERROR: $action reload failed"
    FAILED_RELOADS+=("$action")
  fi
}

if [[ -f "$MANIFEST" ]] && grep -q "^coreos/os-configs/" <<< "$CHANGED_FILES"; then
  if [[ -f "$PENDING_RELOADS" ]]; then
    while read -r action; do
      RELOAD_ACTIONS["$action"]=1
    done < "$PENDING_RELOADS"
  fi

  while read -r src dest mode action; do
    # Skip comments and blank lines
    [[ -z "$src" || "$src" == \#* ]] && continue

    # Per-server files: only apply if the prefix matches this hostname
    src_dir=$(dirname "$src")
    if [[ "$src_dir" != "." ]]; then
      [[ "$src_dir" != "$HOSTNAME" ]] && continue
    fi

    # Only process files that actually changed
    if ! grep -q "^coreos/os-configs/$src$" <<< "$CHANGED_FILES"; then
      continue
    fi

    rc=0
    apply_os_file "$OS_CONFIGS_DIR/$src" "$dest" "${mode:-0644}" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      [[ -n "${action:-}" ]] && RELOAD_ACTIONS["$action"]=1
    elif [[ "$rc" -eq 2 ]]; then
      log "ERROR: Could not install $dest"
      FAILED_OS_FILES+=("$dest")
    fi
  done < "$MANIFEST"

  # Run reload actions
  run_reload sysctl sudo sysctl --system --quiet
  run_reload docker sudo systemctl reload docker
  run_reload sshd sudo systemctl reload sshd
  run_reload operator sudo /usr/local/sbin/homelab-operator-install.sh

  if [[ ${#FAILED_RELOADS[@]} -gt 0 ]]; then
    printf '%s\n' "${FAILED_RELOADS[@]}" > "$PENDING_RELOADS"
  else
    rm -f "$PENDING_RELOADS"
  fi
fi

# Notify on failure only — successful syncs are silent. Leaving the applied
# commit where it is makes the next run retry all of this.
FAILURES=()
[[ "$SECRETS_FAILED" -eq 1 ]] && FAILURES+=("secret sync")
[[ ${#FAILED_STACKS[@]} -gt 0 ]] && FAILURES+=("stacks ${FAILED_STACKS[*]}")
[[ ${#FAILED_OS_FILES[@]} -gt 0 ]] && FAILURES+=("OS files ${FAILED_OS_FILES[*]}")
[[ ${#FAILED_RELOADS[@]} -gt 0 ]] && FAILURES+=("reloads ${FAILED_RELOADS[*]}")

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "ERROR: Sync incomplete, will retry: ${FAILURES[*]}"
  notify_failure "deploy $AFTER ${FAILURES[*]}" "GitOps sync failed" "Failed: ${FAILURES[*]}. Retrying every run. Check: journalctl -u gitops-sync.service"
  exit 1
fi

git update-ref "$APPLIED_REF" "$AFTER"
log "Sync complete: $APPLIED → $AFTER"
exit 0
