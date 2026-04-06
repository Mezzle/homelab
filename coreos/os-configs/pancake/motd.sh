#!/bin/bash
echo ""
echo "  uCore — $(rpm-ostree status --booted | grep -oP 'Version: \K\S+' || echo 'unknown')"
echo "  Host: pancake (i7-5700HQ / 16GB / GTX 970M)"
echo "  Tailscale: $(tailscale ip --4 || echo 'not connected')"
echo "  Cockpit:   https://localhost:9090"
echo "  Stacks:    /srv/docker/pancake/{arr,immich,music,infra}"
echo "  Commands:  /srv/docker/pancake/stacks.sh help"
echo ""
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null | sort | head -20
TOTAL=$(docker ps -q 2>/dev/null | wc -l)
[ "$TOTAL" -gt 20 ] && echo "  ... and $((TOTAL - 20)) more"
echo ""
