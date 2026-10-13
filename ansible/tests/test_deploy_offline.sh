#!/usr/bin/env bash
# Offline dry runs of deploy.yml's controller-side play against a static
# inventory (no SSH, no Proxmox). Checks that it:
#   - fails the count assert when the stage has fewer VMs than expected
#   - fails when a VM has no guest-agent IPv4
#   - fails when env_file is missing
#   - fails when the extracted image lacks the rollouts-demo binary
#   - passes the controller play with a complete artifact (deploy play is
#     then attempted against an unreachable host and must fail, not skip)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ansible_dir="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/inv.yml" <<'YAML'
tag_stage_dev:
  hosts:
    vm-dev:
      ansible_host: 192.0.2.10
tag_stage_qa:
  hosts:
    vm-qa: {}
YAML
printf 'COLOR=blue\nSEMVER=50-blue\nSTAGE=dev\nNAMESPACE=vm-dev\n' >"$tmp/rollouts-demo.env"
mkdir -p "$tmp/art-ok" "$tmp/art-nobin"
printf '#!/bin/sh\n' >"$tmp/art-ok/rollouts-demo"; chmod +x "$tmp/art-ok/rollouts-demo"
for f in index.html main.js style.css logo.png favicon.ico; do : >"$tmp/art-ok/$f"; : >"$tmp/art-nobin/$f"; done

play() {
  local stage="$1" count="$2" env_file="$3" art="$4"
  (cd "$ansible_dir" && ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_TIMEOUT=2 \
    ansible-playbook deploy.yml -i "$tmp/inv.yml" --limit "vm-${stage},localhost" \
    -e "{\"stage\": \"${stage}\", \"artifact\": \"ghcr.io/akuity/sedemo-monorepo-rollouts-app:50-blue\",
         \"app_version\": \"50-blue\", \"env_file\": \"${env_file}\", \"expected_count\": ${count},
         \"artifact_dir\": \"${art}\", \"wait_for_connection_timeout\": 2}" ) >"$tmp/out" 2>&1
}

fail=0
expect_fail() {
  local name="$1" pattern="$2"; shift 2
  if play "$@"; then echo "FAIL: ${name} passed"; fail=1
  elif grep -q -- "$pattern" "$tmp/out"; then echo "ok: ${name}"
  else echo "FAIL: ${name} failed for another reason:"; grep -E 'fatal|msg' "$tmp/out" | head -4; fail=1; fi
}

expect_fail "count assert" "Expected 2 VM(s) tagged stage-dev, found 1: vm-dev" dev 2 "$tmp/rollouts-demo.env" "$tmp/art-ok"
expect_fail "no guest-agent IPv4" "vm-qa has no guest-agent IPv4" qa 1 "$tmp/rollouts-demo.env" "$tmp/art-ok"
expect_fail "missing env_file" "env_file (existing file)" dev 1 "$tmp/missing.env" "$tmp/art-ok"
expect_fail "missing binary" "rollouts-demo binary" dev 1 "$tmp/rollouts-demo.env" "$tmp/art-nobin"
# Controller play passes; the deploy play reaches the (unreachable) VM and times out.
expect_fail "controller play passes" "Failed to connect to the host via ssh" dev 1 "$tmp/rollouts-demo.env" "$tmp/art-ok"
if grep -q 'Deploy rollouts-demo' "$tmp/out"; then echo "ok: deploy play started"; else echo "FAIL: deploy play not reached"; fail=1; fi

[ "$fail" -eq 0 ] && echo "PASS"
exit "$fail"
