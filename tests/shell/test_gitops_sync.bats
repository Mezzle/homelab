#!/usr/bin/env bats
#
# Tests for scripts/gitops-sync.sh
#
# Covers two critical logic areas:
#   1. Stack detection — which stacks get redeployed given a set of changed files
#   2. OS config host routing — per-server files only applied to the right host

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/gitops-sync.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # Extract apply_os_file from the live script
  eval "$(awk '/^apply_os_file\(\) \{/,/^\}$/' "$SCRIPT")"

  # Stub log so extracted functions don't produce noise
  log() { :; }

  # Stub sudo so apply_os_file runs without elevation in tests
  sudo() { command "$@"; }
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Stack detection ───────────────────────────────────────────────────────────
#
# The grep pattern used in gitops-sync.sh to decide which stacks to update:
#   echo "$CHANGED_FILES" | grep -q "^$rel_path/"
#
# The trailing slash is critical — it prevents "arr" from matching "arr-new".

stack_changed() {
  local changed_files="$1" rel_path="$2"
  echo "$changed_files" | grep -q "^${rel_path}/"
}

@test "stack detection: file inside stack triggers update" {
  stack_changed "docker/pancake/arr/docker-compose.yml" "docker/pancake/arr"
}

@test "stack detection: nested file inside stack triggers update" {
  stack_changed "docker/pancake/arr/config/recyclarr/recyclarr.yml" "docker/pancake/arr"
}

@test "stack detection: file in different stack does not trigger update" {
  ! stack_changed "docker/pancake/immich/docker-compose.yml" "docker/pancake/arr"
}

@test "stack detection: stack with name as prefix of another is not matched" {
  # 'arr-new' must not trigger 'arr' stack update
  ! stack_changed "docker/pancake/arr-new/docker-compose.yml" "docker/pancake/arr"
}

@test "stack detection: no changed files triggers nothing" {
  ! stack_changed "" "docker/pancake/arr"
}

@test "stack detection: multiple changed files, only matching stack triggers" {
  local changed
  changed="$(printf '%s\n' \
    'docker/pancake/immich/docker-compose.yml' \
    'docker/pancake/arr/docker-compose.yml' \
    'scripts/gitops-sync.sh')"

  stack_changed "$changed" "docker/pancake/arr"
  ! stack_changed "$changed" "docker/pancake/music"
}

@test "stack detection: scripts/ changes do not trigger any docker stack" {
  ! stack_changed "scripts/gitops-sync.sh" "docker/pancake/arr"
  ! stack_changed "scripts/sync-secrets.sh" "docker/powder/monitoring"
}

# ── OS config host routing ────────────────────────────────────────────────────
#
# Logic from gitops-sync.sh:
#   src_dir=$(dirname "$src")
#   if [[ "$src_dir" != "." ]]; then
#     [[ "$src_dir" != "$HOSTNAME" ]] && continue   # skip — wrong host
#   fi
#
# Shared files (src_dir == ".") apply to all hosts.
# Per-host files (e.g. pancake/motd.sh) apply only to the named host.

os_config_applies_to_host() {
  local src="$1" hostname="$2"
  local src_dir
  src_dir=$(dirname "$src")
  if [[ "$src_dir" != "." ]]; then
    [[ "$src_dir" != "$hostname" ]] && return 1
  fi
  return 0
}

@test "os config routing: shared file (no dir prefix) applies to all hosts" {
  os_config_applies_to_host "docker-daemon.json"       "pancake"
  os_config_applies_to_host "docker-daemon.json"       "powder"
  os_config_applies_to_host "sshd-50-hardening.conf"   "charm"
}

@test "os config routing: per-host file applies to matching host" {
  os_config_applies_to_host "pancake/motd.sh" "pancake"
  os_config_applies_to_host "charm/motd.sh"   "charm"
  os_config_applies_to_host "powder/motd.sh"  "powder"
}

@test "os config routing: per-host file is skipped on other hosts" {
  ! os_config_applies_to_host "pancake/motd.sh" "powder"
  ! os_config_applies_to_host "pancake/motd.sh" "charm"
  ! os_config_applies_to_host "charm/motd.sh"   "pancake"
}

# ── apply_os_file ─────────────────────────────────────────────────────────────

@test "apply_os_file: returns 1 when source file does not exist" {
  ! apply_os_file "$TEST_TMP/nonexistent.conf" "/tmp/dest.conf"
}

@test "apply_os_file: returns 1 when source and dest are identical" {
  echo "same content" > "$TEST_TMP/src.conf"
  echo "same content" > "$TEST_TMP/dest.conf"
  ! apply_os_file "$TEST_TMP/src.conf" "$TEST_TMP/dest.conf"
}

@test "apply_os_file: installs file when content differs" {
  echo "new content" > "$TEST_TMP/src.conf"
  echo "old content" > "$TEST_TMP/dest.conf"
  apply_os_file "$TEST_TMP/src.conf" "$TEST_TMP/dest.conf"
  [[ "$(cat "$TEST_TMP/dest.conf")" == "new content" ]]
}

@test "apply_os_file: installs file when dest does not exist" {
  echo "new content" > "$TEST_TMP/src.conf"
  apply_os_file "$TEST_TMP/src.conf" "$TEST_TMP/dest.conf"
  [[ "$(cat "$TEST_TMP/dest.conf")" == "new content" ]]
}
