#!/bin/bash
# Route br-speedtest and br-arr traffic via the 2.5G USB NIC (enp0s20u5).
# Idempotent — safe to re-run on a timer to self-heal after docker restarts.
set -eu

USB_IF=enp0s20u5
TABLE_ID=100
TABLE_NAME=usb
FWMARK=100
BRIDGES=(br-speedtest br-arr)

# Ensure the named routing table exists
grep -q "^${TABLE_ID} ${TABLE_NAME}\$" /etc/iproute2/rt_tables \
  || echo "${TABLE_ID} ${TABLE_NAME}" >> /etc/iproute2/rt_tables

# Point the usb table's default route at the USB NIC's gateway.
# Prefer the default via USB_IF if one exists; else fall back to any default gw.
GW=$(ip route show default dev "${USB_IF}" | awk 'NR==1{print $3}')
if [ -z "${GW}" ]; then
  GW=$(ip route show default | awk 'NR==1{print $3}')
fi
if [ -n "${GW}" ]; then
  ip route replace default via "${GW}" dev "${USB_IF}" table "${TABLE_NAME}"
fi

# Policy rule: marked packets use the usb table
ip rule del fwmark "${FWMARK}" table "${TABLE_NAME}" 2>/dev/null || true
ip rule add fwmark "${FWMARK}" table "${TABLE_NAME}" priority 100

# Mark packets ingressing from each bridge (only if the bridge exists)
for br in "${BRIDGES[@]}"; do
  ip link show "${br}" >/dev/null 2>&1 || continue
  iptables -t mangle -D PREROUTING -i "${br}" -j MARK --set-mark "${FWMARK}" 2>/dev/null || true
  iptables -t mangle -A PREROUTING -i "${br}" -j MARK --set-mark "${FWMARK}"
done
