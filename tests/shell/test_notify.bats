#!/usr/bin/env bats
#
# Tests for scripts/notify.sh
#
# Verifies colour mapping, silent no-op when unconfigured, and that
# the JSON payload is always valid regardless of input content.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/notify.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # Fake curl — writes the -d payload to disk for inspection
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/curl" << 'EOF'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  [[ "$prev" == "-d" ]] && printf '%s' "$arg" > "$BATS_TMPDIR/payload.json"
  prev="$arg"
done
exit 0
EOF
  chmod +x "$TEST_TMP/bin/curl"
  export PATH="$TEST_TMP/bin:$PATH"

  export DISCORD_WEBHOOK_URL="https://discord.example.com/api/webhooks/test"
  export BATS_TMPDIR="$TEST_TMP"

  source "$SCRIPT"
}

teardown() {
  rm -rf "$TEST_TMP"
}

read_payload() { cat "$TEST_TMP/payload.json" 2>/dev/null || echo ""; }
payload_is_valid_json() { python3 -c "import json,sys; json.loads(open('$TEST_TMP/payload.json').read())" 2>/dev/null; }

# ── No-op behaviour ───────────────────────────────────────────────────────────

@test "notify: exits cleanly with no output when webhook is unset" {
  unset DISCORD_WEBHOOK_URL
  run notify critical "Test Title" "Test message"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "notify: exits cleanly when DISCORD_WEBHOOK_URL is empty string" {
  DISCORD_WEBHOOK_URL=""
  run notify critical "Test Title" "Test message"
  [[ "$status" -eq 0 ]]
}

# ── Colour mapping ────────────────────────────────────────────────────────────

@test "notify: critical maps to red (16711680)" {
  notify critical "Title" "Message"
  payload_is_valid_json
  python3 -c "
import json, sys
p = json.loads(open('$TEST_TMP/payload.json').read())
assert p['embeds'][0]['color'] == 16711680, f'got {p[\"embeds\"][0][\"color\"]}'
"
}

@test "notify: warning maps to yellow (16776960)" {
  notify warning "Title" "Message"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
assert p['embeds'][0]['color'] == 16776960
"
}

@test "notify: success maps to green (65280)" {
  notify success "Title" "Message"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
assert p['embeds'][0]['color'] == 65280
"
}

@test "notify: info maps to blue (3447003)" {
  notify info "Title" "Message"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
assert p['embeds'][0]['color'] == 3447003
"
}

@test "notify: unknown level maps to grey (8421504)" {
  notify other "Title" "Message"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
assert p['embeds'][0]['color'] == 8421504
"
}

# ── JSON safety ───────────────────────────────────────────────────────────────

@test "notify: title with double quotes produces valid JSON" {
  notify info 'Stack "arr" updated' "Normal message"
  payload_is_valid_json
}

@test "notify: message with double quotes produces valid JSON" {
  notify critical "Deployment failed" 'docker compose: "arr" exited with code=1'
  payload_is_valid_json
}

@test "notify: message with backslashes produces valid JSON" {
  notify warning "Path error" 'File not found: C:\Users\test'
  payload_is_valid_json
}

@test "notify: message with newlines produces valid JSON" {
  notify info "Multi-line" "$(printf 'line1\nline2\nline3')"
  payload_is_valid_json
}

@test "notify: empty message produces valid JSON" {
  notify success "Done" ""
  payload_is_valid_json
}

# ── Payload structure ─────────────────────────────────────────────────────────

@test "notify: payload includes title and description" {
  notify info "My Title" "My description"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
e = p['embeds'][0]
assert e['title'] == 'My Title'
assert e['description'] == 'My description'
"
}

@test "notify: payload includes footer with hostname" {
  notify info "Title" "Message"
  python3 -c "
import json
p = json.loads(open('$TEST_TMP/payload.json').read())
assert 'footer' in p['embeds'][0]
assert 'text' in p['embeds'][0]['footer']
"
}
