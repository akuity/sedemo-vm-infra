#!/usr/bin/env bash
# Live inventory check: once stage VMs exist, the Proxmox inventory must
# produce group tag_stage_<stage> whose hosts all have a guest-agent IPv4.
#
# Usage: tests/test_inventory.sh [stage]   (default: dev)
# Credentials: PROXMOX_URL/USER/TOKEN_ID/TOKEN_SECRET from the environment,
# or from pass (PASS_TOKEN_ENTRY, a "<user>!<token-id>=<secret>" API token).
# INVENTORY overrides the inventory source (offline fixtures).
set -euo pipefail

cd "$(dirname "$0")/.."
stage="${1:-dev}"
inventory="${INVENTORY:-inventory/proxmox.yml}"

if [ "$inventory" = "inventory/proxmox.yml" ]; then
  export PROXMOX_URL="${PROXMOX_URL:-https://pve01.annarchy.net:8006}"
  if [ -z "${PROXMOX_TOKEN_SECRET:-}" ]; then
    entry="${PASS_TOKEN_ENTRY:-annarchy.net/proxmox/vm-demo-api-token}"
    token="$(pass show "$entry" | head -n1)"
    # user@realm!tokenid=secret
    export PROXMOX_USER="${token%%!*}"
    rest="${token#*!}"
    export PROXMOX_TOKEN_ID="${rest%%=*}"
    export PROXMOX_TOKEN_SECRET="${rest#*=}"
  fi
fi

# ansible-inventory marks plugin-sourced strings as {"__ansible_unsafe": "..."}.
unwrap='walk(if type == "object" and has("__ansible_unsafe") then .__ansible_unsafe else . end)'
inv_json="$(ansible-inventory -i "$inventory" --list | jq "$unwrap")"

group="tag_stage_${stage}"
hosts="$(jq -r --arg g "$group" '.[$g].hosts // [] | .[]' <<<"$inv_json")"
if [ -z "$hosts" ]; then
  echo "FAIL: no group ${group} (or it has no hosts)"
  exit 1
fi

rc=0
for h in $hosts; do
  ip="$(jq -r --arg h "$h" '._meta.hostvars[$h].ansible_host // ""' <<<"$inv_json")"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ok: ${h} ${ip}"
  else
    echo "FAIL: ${h} has no guest-agent IPv4 (ansible_host='${ip}')"
    rc=1
  fi
done

for h in $(jq -r '._meta.hostvars | keys[]' <<<"$inv_json"); do
  tags="$(jq -r --arg h "$h" '._meta.hostvars[$h].proxmox_tags_parsed // [] | join(",")' <<<"$inv_json")"
  case ",${tags}," in
    *,base,*|*,seed,*) echo "FAIL: template ${h} leaked into inventory (${tags})"; rc=1 ;;
  esac
done

[ "$rc" -eq 0 ] && echo "PASS: ${group} has $(wc -w <<<"$hosts" | tr -d ' ') host(s)"
exit "$rc"
