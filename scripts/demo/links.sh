#!/usr/bin/env bash
# Print each stage's app links and what it runs, straight from the source:
# the VM's current IP (Proxmox guest agent, over SSH to the node, so it works
# without the API token) and the release reported by the app's /env, next to
# the Freight Kargo says the stage holds. IPs come from DHCP and change when a
# base-image promotion replaces VMs, so re-run this after one.
#
# Usage: scripts/demo/links.sh            (needs ssh root@pve01, kargo, jq, curl)
# Env:   PVE_NODE (root@pve01.annarchy.net)
set -euo pipefail
# shellcheck source=scripts/demo/lib.sh
source "$(dirname "$0")/lib.sh"

PVE_NODE="${PVE_NODE:-root@pve01.annarchy.net}"
# Mirrors terraform/stage-vms locals.vms.
declare -A VMS=([dev]="7101" [qa]="7102" [sit]="7103" [uat]="7104" [prod]="7105 7106")

vm_ip() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$PVE_NODE" "qm guest cmd $1 network-get-interfaces" 2>/dev/null \
    | jq -r '[.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"][0] // empty'
}

vm_name() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$PVE_NODE" "qm config $1" 2>/dev/null | awk '/^name:/ {print $2}'
}

printf '%-5s %-10s %-26s %-10s %s\n' STAGE VM LINK RUNNING "KARGO (app / base)"
for s in "${STAGES[@]}"; do
  app="$(stage_freight "$s" app)"; base="$(stage_freight "$s" base-image)"
  kargo_col="$( [[ -n "$app" ]] && freight_tag "$app" || echo -) / $(freight_json | jq -r --arg n "$base" '.items[] | select(.metadata.name == $n) | .alias' 2>/dev/null)"
  for id in ${VMS[$s]}; do
    ip="$(vm_ip "$id")"
    if [[ -z "$ip" ]]; then
      printf '%-5s %-10s %-26s %-10s %s\n' "$s" "$(vm_name "$id")" "(no IP yet)" - "$kargo_col"
      continue
    fi
    running="$(curl -s -m 3 "http://$ip:8080/env" | jq -r '.semver // empty' 2>/dev/null || true)"
    printf '%-5s %-10s %-26s %-10s %s\n' "$s" "$(vm_name "$id")" "http://$ip:8080/" "${running:-down}" "$kargo_col"
  done
done
