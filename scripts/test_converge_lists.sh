#!/usr/bin/env bash
# The per-stage VM list in converge.sh must equal local.vms in
# terraform/stage-vms/locals.tf (same names, same rollout order).
# Requires hcl2json and jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
locals_json="$(hcl2json "$root/terraform/stage-vms/locals.tf")"

fail=0
for stage in dev qa sit uat prod; do
  want="$(jq -r --arg s "$stage" '[.locals[] | select(.vms) | .vms[$s][] | .name] | join(" ")' <<<"$locals_json")"
  got="$("$root/scripts/converge.sh" --list-vms "$stage" 2>/dev/null | xargs || true)"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    echo "ok: ${stage}: ${got}"
  else
    echo "FAIL: ${stage}: converge.sh has '${got}', locals.tf has '${want}'"
    fail=1
  fi
done

# No stray stages on either side.
tf_stages="$(jq -r '[.locals[] | select(.vms) | .vms | keys[]] | sort | join(" ")' <<<"$locals_json")"
if [ "$tf_stages" != "dev prod qa sit uat" ]; then
  echo "FAIL: locals.tf stages are '${tf_stages}'"
  fail=1
fi
if "$root/scripts/converge.sh" --list-vms bogus >/dev/null 2>&1; then
  echo "FAIL: converge.sh accepts unknown stage"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS"
exit "$fail"
