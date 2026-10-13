#!/usr/bin/env bash
# Offline test of converge.sh with stubbed terraform, crane, ansible-inventory
# and ansible-playbook. Checks:
#   - the image is extracted with `crane export <artifact> -` into ansible/artifact
#   - deploy.yml gets env_file=<platform>/rollouts-demo.env and the right extra vars
#   - prod deploys vm-prod-1 then vm-prod-2, and stops after a vm-prod-1 failure
#   - a platform checkout without rollouts-demo.env is rejected
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/plat" "$tmp/img"
calls="$tmp/calls"

# Fake image filesystem: binary plus assets at /.
printf '#!/bin/sh\n' >"$tmp/img/rollouts-demo"
chmod +x "$tmp/img/rollouts-demo"
printf '<html></html>\n' >"$tmp/img/index.html"
printf '' >"$tmp/img/main.js"
tar -C "$tmp/img" -cf "$tmp/image.tar" rollouts-demo index.html main.js

cat >"$tmp/bin/terraform" <<STUB
#!/usr/bin/env bash
echo "terraform \$*" >>"$calls"
for a in "\$@"; do [ "\$a" = list ] && printf '%s\n' 'terraform_data.template["vm-prod-1"]' 'proxmox_virtual_environment_vm.vm["vm-prod-1"]' 'terraform_data.template["vm-prod-2"]' 'proxmox_virtual_environment_vm.vm["vm-prod-2"]'; done
exit 0
STUB
cat >"$tmp/bin/crane" <<STUB
#!/usr/bin/env bash
echo "crane \$*" >>"$calls"
[ "\$1" = export ] && [ "\$3" = "-" ] && cat "$tmp/image.tar"
STUB
cat >"$tmp/bin/ansible-inventory" <<'STUB'
#!/usr/bin/env bash
echo '{"ansible_host": {"__ansible_unsafe": "192.0.2.5"}}'
STUB
cat >"$tmp/bin/ansible-playbook" <<STUB
#!/usr/bin/env bash
echo "ansible-playbook \$*" >>"$calls"
[ -x "$root/ansible/artifact/rollouts-demo" ] || { echo "artifact not extracted" >>"$calls"; exit 3; }
[ -n "\${FAIL_ON:-}" ] && [[ "\$*" == *"--limit \${FAIL_ON},"* ]] && exit 2
exit 0
STUB
chmod +x "$tmp/bin/"*

cat >"$tmp/plat/deploy.yaml" <<'YAML'
app_version: 50-blue
artifact: ghcr.io/akuity/sedemo-monorepo-rollouts-app:50-blue
base_vmid: 9101
base_template: ubuntu-2404-base-202610120000
vm_count: 2
YAML
printf 'COLOR=blue\nSEMVER=50-blue\nSTAGE=prod\nNAMESPACE=vm-prod\n' >"$tmp/plat/rollouts-demo.env"

run() { PATH="$tmp/bin:$PATH" GITHUB_STEP_SUMMARY="$tmp/summary.md" "$root/scripts/converge.sh" "$@" >"$tmp/out" 2>&1; }

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
expect_not() { local name="$1"; shift; if "$@"; then bad "$name"; else ok "$name"; fi; }

# 1. Happy path, prod.
: >"$calls"
if run prod "$tmp/plat"; then ok "prod converge succeeds"; else bad "prod converge failed: $(tail -3 "$tmp/out")"; fi
expect "crane export of the pinned artifact" grep -qx "crane export ghcr.io/akuity/sedemo-monorepo-rollouts-app:50-blue -" "$calls"
expect "env_file passed" grep -q '"env_file":"'"$tmp"'/plat/rollouts-demo.env"' "$calls"
expect_not "no config_file" grep -q 'config_file' "$calls"
expect "prod expected_count 2" grep -q '"expected_count":2' "$calls"
expect "prod healthz gate" grep -q '"healthz_gate":true' "$calls"
order="$(grep -o -- '--limit [^ ]*' "$calls" | xargs || true)"
expect "rolling order (${order})" test "$order" = "--limit vm-prod-1,localhost --limit vm-prod-2,localhost"
expect_not "no oras" grep -q 'oras' "$calls"

# 2. Rolling halt: vm-prod-1 fails, vm-prod-2 never deployed.
: >"$calls"
if FAIL_ON=vm-prod-1 run prod "$tmp/plat"; then bad "converge passed despite vm-prod-1 failure"; else ok "converge fails on vm-prod-1"; fi
expect_not "vm-prod-2 untouched" grep -q -- '--limit vm-prod-2' "$calls"
expect "summary records failure" grep -q 'vm-prod-1 | deploy failed' "$tmp/summary.md"

# 3. Missing env file.
rm "$tmp/plat/rollouts-demo.env"
: >"$calls"
if run prod "$tmp/plat"; then bad "converge passed without rollouts-demo.env"; else ok "missing rollouts-demo.env rejected"; fi

rm -rf "$root/ansible/artifact"
[ "$fail" -eq 0 ] && echo "PASS"
exit "$fail"
