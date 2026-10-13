#!/usr/bin/env bash
# Offline check of inventory/proxmox.yml's keyed_groups and compose against
# canned guest-agent data (RFC 5737 documentation addresses only):
#   - tag stage-dev becomes group tag_stage_dev
#   - ansible_host is the first non-loopback IPv4
#   - a VM whose agent has not reported an address gets no ansible_host,
#     and test_inventory.sh fails for it instead of passing vacuously.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/hosts.yml" <<'YAML'
all:
  hosts:
    vm-dev:
      proxmox_tags_parsed: [stage-dev, vm-demo]
      proxmox_agent_interfaces:
        - {name: lo, mac-address: "00:00:00:00:00:00", ip-addresses: [127.0.0.1/8, "::1/128"]}
        - {name: eth0, mac-address: "bc:24:11:d0:00:01", ip-addresses: ["fe80::1/64", 192.0.2.10/24]}
    vm-qa:
      proxmox_tags_parsed: [stage-qa, vm-demo]
      proxmox_agent_interfaces: []
    vm-sit:
      proxmox_tags_parsed: [stage-sit, vm-demo]
YAML

# Requires yq (mikefarah) and jq.
# Same keyed_groups/compose as the Proxmox inventory, via the constructed plugin.
yq '{"plugin": "ansible.builtin.constructed", "strict": false,
     "keyed_groups": .keyed_groups, "compose": .compose}' \
  "$here/../inventory/proxmox.yml" > "$tmp/inv.constructed.yml"

inv="$(ANSIBLE_INVENTORY_ENABLED=ansible.builtin.yaml,ansible.builtin.constructed \
  ansible-inventory -i "$tmp/hosts.yml" -i "$tmp/inv.constructed.yml" --list 2>/dev/null)"
printf '%s\n' "$inv" \
  | jq 'walk(if type == "object" and has("__ansible_unsafe") then .__ansible_unsafe else . end)' > "$tmp/inv.json"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

check "group tag_stage_dev" "$(jq -c '.tag_stage_dev.hosts' "$tmp/inv.json")" '["vm-dev"]'
check "group tag_vm_demo" "$(jq -c '.tag_vm_demo.hosts | sort' "$tmp/inv.json")" '["vm-dev","vm-qa","vm-sit"]'
check "vm-dev ansible_host" "$(jq -r '._meta.hostvars["vm-dev"].ansible_host // ""' "$tmp/inv.json")" "192.0.2.10"
check "vm-qa (no address yet) ansible_host" "$(jq -r '._meta.hostvars["vm-qa"].ansible_host // ""' "$tmp/inv.json")" ""
check "vm-sit (agent off) ansible_host" "$(jq -r '._meta.hostvars["vm-sit"].ansible_host // ""' "$tmp/inv.json")" ""

# test_inventory.sh must pass for dev and fail (not pass vacuously) for qa.
static="$tmp/static.yml"
jq '{all: {hosts: (._meta.hostvars)}, tag_stage_dev: {hosts: (.tag_stage_dev.hosts | map({(.): {}}) | add)},
     tag_stage_qa: {hosts: (.tag_stage_qa.hosts | map({(.): {}}) | add)}}' "$tmp/inv.json" > "$static"
if INVENTORY="$static" "$here/test_inventory.sh" dev >/dev/null 2>&1; then echo "ok: live test passes for dev"; else echo "FAIL: live test rejects dev"; fail=1; fi
if INVENTORY="$static" "$here/test_inventory.sh" qa >/dev/null 2>&1; then echo "FAIL: live test passes qa without an IP"; fail=1; else echo "ok: live test fails qa without an IP"; fi
if INVENTORY="$static" "$here/test_inventory.sh" uat >/dev/null 2>&1; then echo "FAIL: live test passes uat with no VMs"; fail=1; else echo "ok: live test fails uat with no VMs"; fi

[ "$fail" -eq 0 ] && echo "PASS"
exit "$fail"
