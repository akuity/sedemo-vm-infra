#!/usr/bin/env bash
# Put the VM demo back into its starting state:
#   sit, uat, prod  on the "current" release (default 49-green), verified
#   dev, qa         on the "new" release (default 50-blue), auto-promoted
#                   and verified -- the release that "landed overnight"
#
# Safe to re-run: stages already in the target state are skipped.
#
# Usage:
#   scripts/demo/reset-demo.sh                 # waits for you at the uat/prod gates
#   AUTO_MERGE=1 JIRA_EMAIL=... JIRA_API_TOKEN=... scripts/demo/reset-demo.sh
#
# Env: CURRENT_TAG (49-green), NEW_TAG (50-blue), plus lib.sh settings.
set -euo pipefail
# shellcheck source=scripts/demo/lib.sh
source "$(dirname "$0")/lib.sh"

CURRENT_TAG="${CURRENT_TAG:-49-green}"
NEW_TAG="${NEW_TAG:-50-blue}"

check_main_branches() {
  local values sit
  values="$(gh api "repos/${MONOREPO}/contents/vm-app/config-chart/values.yaml" -q .content | base64 -d)"
  grep -Eq '^errorRate:[[:space:]]*0[[:space:]]*(#.*)?$' <<<"$values" \
    || die "${MONOREPO} vm-app/config-chart/values.yaml errorRate is not 0 (auto-rollback rehearsal not reverted?)"
  grep -Eq '^latency:[[:space:]]*0[[:space:]]*(#.*)?$' <<<"$values" \
    || die "${MONOREPO} vm-app/config-chart/values.yaml latency is not 0 (auto-rollback rehearsal not reverted?)"
  sit="$(gh api "repos/${PLATFORM_REPO}/contents/apps/vm-demo/env/sit/values.yaml" -q .content | base64 -d)"
  grep -Eq '^namespace:' <<<"$sit" \
    || die "${PLATFORM_REPO} apps/vm-demo/env/sit/values.yaml has no namespace (render-failure rehearsal not reverted?)"
  log "main branches are clean"
}

# The kargo CLI cannot abort a promotion, so stop and ask instead of
# queueing new promotions behind one that is waiting on a gate.
check_in_flight() {
  local running
  running="$(kargo get promotions --project "$PROJECT" -o json \
    | jq -r '.items[] | select(.status.phase == "Running" or .status.phase == "Pending") | .metadata.name')"
  [[ -z "$running" ]] || die "promotions still in flight; abort them in the Kargo UI (Promotion > Abort), then re-run:
$running"
}

close_stale_prs() {
  local s
  for s in "${STAGES[@]}"; do
    gh pr list -R "$PLATFORM_REPO" --base "rendered/vm-demo/$s" --state open --json number -q '.[].number' \
      | while read -r n; do
          gh pr close "$n" -R "$PLATFORM_REPO" --delete-branch \
            --comment "Closed by reset-demo.sh (stale demo promotion)." >/dev/null && log "closed PR #$n"
        done
  done
}

# The new release must be the newest app Freight, or dev/qa auto-promotion
# will not pick it up. If an older Freight for it exists (e.g. after a
# manual Freight was created later), delete it and let the Warehouse
# rediscover the tag as new Freight.
ensure_new_release_is_newest() {
  local newest name tag s
  read -r name tag <<<"$(newest_app_freight)"
  if [[ "$tag" == "$NEW_TAG" ]]; then
    log "newest app Freight is $NEW_TAG ($name)"
    return
  fi
  name="$(freight_for_tag "$NEW_TAG")"
  if [[ -n "$name" ]]; then
    for s in "${STAGES[@]}"; do
      [[ "$(stage_freight "$s" app)" != "$name" ]] \
        || die "$NEW_TAG Freight $name is current in $s; promote $s to $CURRENT_TAG first"
    done
    kargo delete freight --project "$PROJECT" --name "$name" >/dev/null
    log "deleted older $NEW_TAG Freight $name so the Warehouse recreates it as newest"
  fi
  kargo refresh warehouse app --project "$PROJECT" >/dev/null
  newest=""
  for _ in $(seq 1 40); do
    read -r name tag <<<"$(newest_app_freight)"
    [[ "$tag" == "$NEW_TAG" ]] && { newest="$name"; break; }
    sleep 6
  done
  [[ -n "$newest" ]] || die "Warehouse did not produce $NEW_TAG Freight"
  log "Warehouse produced $NEW_TAG Freight $newest"
}

# Wait until a stage holds exactly Freight $2 (not just the same image tag:
# rehearsal Freight can share a tag with a different chart commit) and it is
# verified.
wait_auto() {
  local stage="$1" want="$2" deadline=$((SECONDS + ${AUTO_WAIT:-150}))
  while :; do
    if [[ "$(stage_freight "$stage" app)" == "$want" && "$(stage_verification "$stage")" == Successful ]]; then
      log "$stage: on $(freight_tag "$want") ($want) and verified (auto-promotion)"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      # Kargo does not auto-promote Freight a stage already held earlier
      # (e.g. after someone moved the stage back by hand), so promote it.
      log "$stage: no auto-promotion to $want; promoting it"
      promote_and_wait "$stage" "$want" || die "$stage did not reach $want"
      return 0
    fi
    sleep 20
  done
}

main() {
  require_tools
  check_main_branches
  check_in_flight
  close_stale_prs

  local green s cur
  green="$(freight_for_tag "$CURRENT_TAG")"
  [[ -n "$green" ]] || die "no app Freight for $CURRENT_TAG"

  for s in sit uat prod; do
    cur="$(stage_freight "$s" app)"
    if [[ "$cur" == "$green" && "$(stage_verification "$s")" == Successful ]]; then
      log "$s: already on $CURRENT_TAG and verified"
      continue
    fi
    promote_and_wait "$s" "$green" || die "$s did not reach $CURRENT_TAG"
  done

  ensure_new_release_is_newest
  # Kargo does not auto-promote Freight that already failed on a stage (the
  # recreated Freight keeps its content-hash name), so promote dev directly;
  # qa then follows through its auto-promotion policy.
  local blue
  blue="$(freight_for_tag "$NEW_TAG")"
  if [[ "$(stage_freight dev app)" == "$blue" && "$(stage_verification dev)" == Successful ]]; then
    log "dev: already on $NEW_TAG and verified"
  else
    promote_and_wait dev "$blue" || die "dev did not reach $NEW_TAG"
  fi
  wait_auto qa "$blue"

  echo
  print_status
}

main "$@"
