#!/bin/bash
echo ""
echo "  uCore — $(rpm-ostree status --booted | grep -oP 'Version: \K\S+' || echo 'unknown')"
echo "  Host: powder (Ampere A1 / Oracle Cloud)"
echo "  Tailscale: $(tailscale ip --4 || echo 'not connected')"
echo "  Cockpit:   https://localhost:9090"
echo "  Stacks:    /srv/docker/powder/{infra,monitoring}"
echo "  Commands:  /srv/docker/powder/stacks.sh help"
echo ""
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null | sort | head -20
TOTAL=$(docker ps -q 2>/dev/null | wc -l)
[ "$TOTAL" -gt 20 ] && echo "  ... and $((TOTAL - 20)) more"
echo ""
