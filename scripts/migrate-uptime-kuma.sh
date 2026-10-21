#!/usr/bin/env bash
set -euo pipefail

SOURCE_HOST="${SOURCE_HOST:-powder}"
TARGET_HOST="${TARGET_HOST:-watch}"
SOURCE_DATA="${SOURCE_DATA:-/srv/docker/powder/monitoring/appdata/uptime-kuma}"
TARGET_DATA="${TARGET_DATA:-/srv/docker/watch/monitoring/appdata/uptime-kuma}"

if [[ "${1:-}" != "--confirm" ]]; then
  cat <<EOF
This performs the final Uptime Kuma cutover:
  source: $SOURCE_HOST:$SOURCE_DATA
  target: $TARGET_HOST:$TARGET_DATA

It stops Uptime Kuma on powder, copies its data, fixes ownership on watch,
and starts the monitoring-stack service on watch. The source data is retained.

Run again with --confirm when watch is provisioned and reachable over SSH.
EOF
  exit 0
fi

archive=""
cutover_complete=0
source_stopped=0
cleanup() {
  status=$?
  [[ -n "$archive" ]] && rm -f "$archive"
  if [[ "$status" -ne 0 && "$source_stopped" -eq 1 && "$cutover_complete" -eq 0 ]]; then
    echo "Cutover failed. Attempting to restart Uptime Kuma on $SOURCE_HOST." >&2
    ssh "$SOURCE_HOST" 'docker start uptime-kuma' >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

for host in "$SOURCE_HOST" "$TARGET_HOST"; do
  ssh -o BatchMode=yes "$host" true
done

echo "Stopping the source container"
ssh "$SOURCE_HOST" 'docker stop uptime-kuma'
source_stopped=1

archive="$(mktemp -t uptime-kuma.XXXXXX.tar.gz)"

echo "Downloading Kuma data from $SOURCE_HOST"
ssh "$SOURCE_HOST" "sudo tar -C '$(dirname "$SOURCE_DATA")' -czf - '$(basename "$SOURCE_DATA")'" > "$archive"

echo "Restoring Kuma data to $TARGET_HOST"
ssh "$TARGET_HOST" "sudo install -d -m 0755 '$(dirname "$TARGET_DATA")' && sudo tar -C '$(dirname "$TARGET_DATA")' -xzf -" < "$archive"
ssh "$TARGET_HOST" "sudo systemctl restart monitoring-stack.service"

echo "Checking the target"
ssh "$TARGET_HOST" 'curl -fsS http://127.0.0.1:3001/ >/dev/null'
cutover_complete=1
echo "Cutover complete. The old data remains on powder and the old container is stopped."
