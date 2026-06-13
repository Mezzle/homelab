#!/usr/bin/env bats
#
# Tests for scripts/sync-secrets.sh
#
# Focused on set_env_value — the function that writes secrets into .env files.
# A bug here silently corrupts secrets for all stacks with no runtime error.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/sync-secrets.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # Extract set_env_value from the live script so tests always reflect
  # the current implementation.
  eval "$(awk '/^set_env_value\(\) \{/,/^\}$/' "$SCRIPT")"
}

teardown() {
  rm -rf "$TEST_TMP"
}

make_env() { printf '%s\n' "$@" > "$TEST_TMP/test.env"; }
read_env()  { cat "$TEST_TMP/test.env"; }

# ── set_env_value ─────────────────────────────────────────────────────────────

@test "set_env_value: replaces an existing key" {
  make_env "FOO=old"
  set_env_value "$TEST_TMP/test.env" FOO newvalue
  [[ "$(read_env)" == "FOO=newvalue" ]]
}

@test "set_env_value: appends a new key when not present" {
  make_env "FOO=bar"
  set_env_value "$TEST_TMP/test.env" BAR baz
  grep -q "^FOO=bar$" "$TEST_TMP/test.env"
  grep -q "^BAR=baz$" "$TEST_TMP/test.env"
}

@test "set_env_value: does not match key that is a prefix of another" {
  make_env "FOO=original" "FOOBAR=other"
  set_env_value "$TEST_TMP/test.env" FOO replaced
  grep -q "^FOO=replaced$"  "$TEST_TMP/test.env"
  grep -q "^FOOBAR=other$"  "$TEST_TMP/test.env"
}

@test "set_env_value: handles values that contain equals signs (e.g. base64)" {
  make_env "KEY=plain"
  set_env_value "$TEST_TMP/test.env" KEY "dGVzdA==base64=="
  grep -q "^KEY=dGVzdA==base64==$" "$TEST_TMP/test.env"
}

@test "set_env_value: handles empty value" {
  make_env "KEY=old"
  set_env_value "$TEST_TMP/test.env" KEY ""
  grep -q "^KEY=$" "$TEST_TMP/test.env"
}

@test "set_env_value: appends to empty file" {
  touch "$TEST_TMP/test.env"
  set_env_value "$TEST_TMP/test.env" NEW_KEY some_value
  grep -q "^NEW_KEY=some_value$" "$TEST_TMP/test.env"
}

@test "set_env_value: preserves all other keys when replacing one" {
  make_env "A=1" "B=2" "C=3"
  set_env_value "$TEST_TMP/test.env" B updated
  grep -q "^A=1$"       "$TEST_TMP/test.env"
  grep -q "^B=updated$" "$TEST_TMP/test.env"
  grep -q "^C=3$"       "$TEST_TMP/test.env"
}

@test "set_env_value: handles values with spaces" {
  make_env "MSG=hello"
  set_env_value "$TEST_TMP/test.env" MSG "hello world"
  grep -q "^MSG=hello world$" "$TEST_TMP/test.env"
}

# ── Token file format validation ──────────────────────────────────────────────

@test "token file: valid format accepted" {
  local token_file="$TEST_TMP/token.env"
  echo "OP_SERVICE_ACCOUNT_TOKEN=ops_abc123-XYZ_456" > "$token_file"
  grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$token_file"
}

@test "token file: rejects file with extra whitespace" {
  local token_file="$TEST_TMP/token.env"
  echo "OP_SERVICE_ACCOUNT_TOKEN=ops_abc123 extra" > "$token_file"
  ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$token_file"
}

@test "token file: rejects file with wrong key name" {
  local token_file="$TEST_TMP/token.env"
  echo "WRONG_KEY=ops_abc123" > "$token_file"
  ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$token_file"
}

@test "token file: rejects empty token value" {
  local token_file="$TEST_TMP/token.env"
  echo "OP_SERVICE_ACCOUNT_TOKEN=" > "$token_file"
  ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$token_file"
}
