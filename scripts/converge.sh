#!/usr/bin/env bash
# Converge one stage: Terraform (VM lifecycle) then Ansible (app deploy),
# one VM at a time so prod is replaced and redeployed VM by VM.
#
# Usage:
#   scripts/converge.sh <stage> <platform_dir>
#   scripts/converge.sh --list-vms <stage>
#
# <platform_dir> is a checkout of rendered/vm-demo/<stage> with config.yaml
# and deploy.yaml (app_version, artifact, base_vmid, vm_count, ...) at its root.
#
# Environment:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN   Terraform provider
#   PROXMOX_URL, PROXMOX_USER, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET   Ansible inventory
#   TF_VAR_ssh_public_key                      deploy public key
#   ANSIBLE_PRIVATE_KEY_FILE                   deploy private key
#   KUBERNETES_SERVICE_HOST                    set in-cluster; otherwise KUBECONFIG
#                                              (default ~/.kube/config-annarchy) holds the state
#   INVENTORY_WAIT_TRIES (30), INVENTORY_WAIT_DELAY (10)
set -euo pipefail

# Rollout order per stage. Must equal local.vms in terraform/stage-vms/locals.tf
# (scripts/test_converge_lists.sh checks this).
vms_for_stage() {
  case "$1" in
    dev) echo "vm-dev" ;;
    qa) echo "vm-qa" ;;
    sit) echo "vm-sit" ;;
    uat) echo "vm-uat" ;;
    prod) echo "vm-prod-1 vm-prod-2" ;;
    *) return 1 ;;
  esac
}

usage() {
  echo "usage: $0 <dev|qa|sit|uat|prod> <platform_dir> | --list-vms <stage>" >&2
  exit 2
}

if [ "${1:-}" = "--list-vms" ]; then
  [ $# -eq 2 ] || usage
  vms_for_stage "$2" | tr ' ' '\n'
  exit 0
fi

[ $# -eq 2 ] || usage
stage="$1"
platform_dir="$(cd "$2" && pwd)"
read -r -a vms <<<"$(vms_for_stage "$stage" || true)"
[ "${#vms[@]}" -gt 0 ] || { echo "unknown stage: ${stage}" >&2; usage; }

root="$(cd "$(dirname "$0")/.." && pwd)"
tf_dir="${root}/terraform/stage-vms"
ansible_dir="${root}/ansible"
deploy_yaml="${platform_dir}/deploy.yaml"
config_file="${platform_dir}/config.yaml"

for f in "$deploy_yaml" "$config_file"; do
  [ -f "$f" ] || { echo "missing ${f}" >&2; exit 1; }
done

field() { yq -r ".$1 // \"\"" "$deploy_yaml"; }
app_version="$(field app_version)"
artifact="$(field artifact)"
base_vmid="$(field base_vmid)"
base_template="$(field base_template)"
vm_count="$(field vm_count)"
vm_count="${vm_count:-${#vms[@]}}"

for v in app_version artifact base_vmid; do
  [ -n "${!v}" ] || { echo "deploy.yaml has no ${v}" >&2; exit 1; }
done
[[ "$base_vmid" =~ ^[0-9]+$ ]] || { echo "base_vmid '${base_vmid}' is not a number" >&2; exit 1; }
if [ "$vm_count" != "${#vms[@]}" ]; then
  echo "deploy.yaml vm_count=${vm_count} but stage ${stage} has ${#vms[@]} VM(s): ${vms[*]}" >&2
  exit 1
fi
healthz_gate=false
[ "$stage" = "prod" ] && healthz_gate=true

# --- job summary (written on success and failure) ---------------------------
declare -a results=()
summary() {
  local rc=$?
  local out="${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  {
    echo "### converge ${stage}: $([ "$rc" -eq 0 ] && echo success || echo FAILED)"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| stage | \`${stage}\` |"
    echo "| app_version | \`${app_version}\` |"
    echo "| artifact | \`${artifact}\` |"
    echo "| base template | \`${base_template:-?}\` (VMID ${base_vmid}) |"
    echo
    echo "| VM | result |"
    echo "|---|---|"
    local r
    for r in "${results[@]}"; do echo "| ${r%%=*} | ${r#*=} |"; done
  } >>"$out"
}
trap summary EXIT

# --- terraform ---------------------------------------------------------------
backend_args=("-backend-config=secret_suffix=vm-demo-${stage}")
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
  backend_args+=("-backend-config=in_cluster_config=true")
else
  backend_args+=("-backend-config=config_path=${KUBECONFIG:-$HOME/.kube/config-annarchy}")
fi

tf() { terraform -chdir="$tf_dir" "$@"; }
tf_apply() {
  local targets=() n
  for n in "$@"; do
    targets+=("-target=terraform_data.template[\"${n}\"]" "-target=proxmox_virtual_environment_vm.vm[\"${n}\"]")
  done
  tf apply -input=false -auto-approve -no-color \
    -var "stage=${stage}" -var "template_vmid=${base_vmid}" "${targets[@]}"
}

tf init -input=false -reconfigure -no-color "${backend_args[@]}"

# A fresh stage creates all its VMs first, so the Ansible count check (which
# always looks at the whole stage) holds from the first VM on. Existing VMs are
# replaced one at a time below.
state="$(tf state list 2>/dev/null || true)"
missing=()
for name in "${vms[@]}"; do
  grep -qxF "proxmox_virtual_environment_vm.vm[\"${name}\"]" <<<"$state" || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "::group::create ${missing[*]}"
  tf_apply "${missing[@]}"
  echo "::endgroup::"
fi

# --- per-VM: terraform (replace if the template changed), then deploy --------
wait_for_inventory_ip() {
  local name="$1" tries="${INVENTORY_WAIT_TRIES:-30}" delay="${INVENTORY_WAIT_DELAY:-10}" i ip
  for ((i = 1; i <= tries; i++)); do
    ip="$( (cd "$ansible_dir" && ansible-inventory --host "$name" 2>/dev/null) \
      | jq -r 'walk(if type == "object" and has("__ansible_unsafe") then .__ansible_unsafe else . end) | .ansible_host // ""' 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${name}: guest agent reports ${ip}"
      return 0
    fi
    echo "${name}: no guest-agent IPv4 yet (${i}/${tries})"
    sleep "$delay"
  done
  echo "${name}: guest agent never reported an IPv4" >&2
  return 1
}

extra_vars="$(jq -cn \
  --arg stage "$stage" --arg artifact "$artifact" --arg app_version "$app_version" \
  --arg config_file "$config_file" --argjson expected_count "$vm_count" \
  --argjson healthz_gate "$healthz_gate" \
  '{stage: $stage, artifact: $artifact, app_version: $app_version, config_file: $config_file,
    expected_count: $expected_count, healthz_gate: $healthz_gate}')"

for name in "${vms[@]}"; do
  results+=("${name}=running")
  last=$((${#results[@]} - 1))

  echo "::group::terraform ${name}"
  results[last]="${name}=terraform failed"
  tf_apply "$name"
  echo "::endgroup::"

  results[last]="${name}=no IP from guest agent"
  wait_for_inventory_ip "$name"

  echo "::group::ansible ${name}"
  results[last]="${name}=deploy failed"
  (cd "$ansible_dir" && ansible-playbook deploy.yml --limit "${name},localhost" -e "$extra_vars")
  echo "::endgroup::"

  results[last]="${name}=ok (${app_version})"
done
