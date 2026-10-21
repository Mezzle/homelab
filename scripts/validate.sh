#!/usr/bin/env bash
###############################################################################
# validate.sh — everything CI checks, runnable locally before a push
#
#   1. docker compose config for every stack (using .env.example if no .env)
#   2. butane --strict for every coreos/*.bu, resolving os-configs/ references
#   3. every manifest.conf source exists and every file under os-configs that
#      looks deployable is listed
#   4. shellcheck on all shell scripts (skipped with a warning if not installed)
#   5. python byte-compile of the monitoring scripts
###############################################################################
set -uo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1
FAILED=0
fail() { echo "[validate] FAIL: $*"; FAILED=1; }
ok()   { echo "[validate] OK: $*"; }

# 1. compose
if "$REPO_DIR/scripts/validate-compose.sh"; then ok "compose"; else fail "compose"; fi

# 2. butane
if command -v butane >/dev/null; then
  BUTANE=(butane)
elif docker info >/dev/null 2>&1; then
  BUTANE=(docker run --rm -i -v "$REPO_DIR/coreos:/coreos:ro" -w /coreos quay.io/coreos/butane:release)
else
  BUTANE=()
fi
if ((${#BUTANE[@]})); then
  for bu in coreos/*.bu; do
    if (cd coreos && "${BUTANE[@]}" --strict -d . "$(basename "$bu")" > /dev/null); then
      ok "butane $bu"
    else
      fail "butane $bu"
    fi
  done
else
  echo "[validate] WARN: butane unavailable and Docker inaccessible, skipped"
fi

# 3. manifest
while read -r src dest mode action; do
  [[ -z "$src" || "$src" == \#* ]] && continue
  [[ -f "coreos/os-configs/$src" ]] || fail "manifest source missing: $src"
  [[ "$dest" == /* ]] || fail "manifest destination not absolute: $src -> $dest"
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || fail "manifest bad mode for $src: $mode"
  case "${action:-}" in ""|sysctl|docker|sshd|systemd|operator) ;; *) fail "manifest unknown action for $src: $action" ;; esac
done < coreos/os-configs/manifest.conf
while IFS= read -r f; do
  rel="${f#coreos/os-configs/}"
  [[ "$rel" == manifest.conf ]] && continue
  [[ "$rel" == legacy/* ]] && continue
  grep -qE "^${rel//./\\.}[[:space:]]" coreos/os-configs/manifest.conf || fail "os-configs file not in manifest: $rel"
done < <(find coreos/os-configs -type f | sort)
ok "manifest"

# 4. shellcheck
SCRIPTS=()
while IFS= read -r script; do
  [[ -L "$script" ]] || SCRIPTS+=("$script")
done < <(git ls-files '*.sh' | grep -v '^\.claude/')
if command -v shellcheck >/dev/null; then
  if shellcheck -S warning "${SCRIPTS[@]}"; then ok "shellcheck"; else fail "shellcheck"; fi
elif command -v docker >/dev/null; then
  if docker run --rm -v "$REPO_DIR:/mnt:ro" koalaman/shellcheck:stable -S warning "${SCRIPTS[@]}"; then ok "shellcheck (docker)"; else fail "shellcheck"; fi
else
  echo "[validate] WARN: shellcheck not available, skipped"
fi

# 5. python
if python3 -m py_compile docker/watch/monitoring/scripts/*.py; then ok "python"; else fail "python"; fi

if [[ $FAILED -ne 0 ]]; then echo "[validate] FAILED"; exit 1; fi
echo "[validate] all checks passed"
