#!/usr/bin/env bash
set -euo pipefail

operator=homelab-operator

if ! id "$operator" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$operator"
fi

install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/homelab-operator <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: homelab-operator <command> [argument]
  summary                 system, disk, failed-unit and container summary
  logs <unit>             last hour of a named systemd unit
  status <unit>           status of a named systemd unit
  containers              Docker container status
  gitops-status           status and recent output of GitOps sync
  restart <unit>          restart an approved service after human approval
  gitops                  run GitOps sync after human approval
  reboot                  reboot this host after human approval
USAGE
}

unit_ok() {
  [[ "$1" =~ ^[A-Za-z0-9@_.-]+\.(service|timer|socket)$ ]]
}

restart_ok() {
  [[ "$1" =~ ^(arr-stack|immich-stack|music-stack|infra-stack|home-stack|monitoring-stack|gitops-sync|docker|tailscaled)\.service$ ]]
}

case "${1:-}" in
  summary)
    hostnamectl
    printf '\nFailed units:\n'
    systemctl --failed --no-pager || true
    printf '\nDisk:\n'
    df -hT
    printf '\nContainers:\n'
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  logs)
    unit="${2:-}"; unit_ok "$unit" || { usage >&2; exit 2; }
    journalctl --no-pager --since '-1 hour' -u "$unit"
    ;;
  status)
    unit="${2:-}"; unit_ok "$unit" || { usage >&2; exit 2; }
    systemctl status --no-pager "$unit"
    ;;
  containers)
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  gitops-status)
    systemctl status --no-pager gitops-sync.timer gitops-sync.service
    journalctl --no-pager -u gitops-sync.service -n 100
    ;;
  restart)
    unit="${2:-}"; restart_ok "$unit" || { usage >&2; exit 2; }
    systemctl restart "$unit"
    systemctl status --no-pager "$unit"
    ;;
  gitops)
    systemctl start gitops-sync.service
    systemctl status --no-pager gitops-sync.service
    ;;
  reboot)
    systemctl reboot
    ;;
  *) usage >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/sbin/homelab-operator

cat > /etc/sudoers.d/homelab-operator <<'EOF'
homelab-operator ALL=(root) NOPASSWD: /usr/local/sbin/homelab-operator
EOF
chmod 0440 /etc/sudoers.d/homelab-operator
visudo -cf /etc/sudoers.d/homelab-operator
