# shellcheck shell=bash
# Shared helpers for the VM demo scripts. Source it; do not execute it.
#
# Requires: kargo (logged in to the instance), gh, jq, curl.
# Optional, for unattended prod approval:
#   JIRA_EMAIL, JIRA_API_TOKEN  Jira Cloud user + API token allowed to
#                                transition CHANGE issues.
#   AUTO_MERGE=1                 merge the rendered-config PRs Kargo opens for
#                                uat and prod (default: wait for a human).

PROJECT="${PROJECT:-vm-demo}"
PLATFORM_REPO="${PLATFORM_REPO:-akuity/sedemo-platform}"
MONOREPO="${MONOREPO:-akuity/sedemo-monorepo}"
JIRA_BASE="${JIRA_BASE:-https://eddiewebb.atlassian.net}"
JIRA_APPROVE_TRANSITION="${JIRA_APPROVE_TRANSITION:-4}"
PROMOTION_TIMEOUT="${PROMOTION_TIMEOUT:-2400}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"
STAGES=(dev qa sit uat prod)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_tools() {
  local t
  for t in kargo gh jq curl; do
    command -v "$t" >/dev/null || die "$t is not installed"
  done
  kargo get project "$PROJECT" >/dev/null 2>&1 \
    || die "kargo cannot read project $PROJECT; run: kargo login https://kargo.akpdemoapps.link --sso"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
}

freight_json() { kargo get freight --project "$PROJECT" -o json; }
stage_json() { kargo get stage "$1" --project "$PROJECT" -o json; }

# Newest app Freight (by creation time) whose image tag is $1.
freight_for_tag() {
  freight_json | jq -r --arg t "$1" '
    [.items[] | select(.origin.name == "app" and .images[0].tag == $t)]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

# Newest app Freight overall: name and tag.
newest_app_freight() {
  freight_json | jq -r '
    [.items[] | select(.origin.name == "app")]
    | sort_by(.metadata.creationTimestamp) | last
    | "\(.metadata.name) \(.images[0].tag)"'
}

# Current Freight name for a stage and origin (app|base-image).
stage_freight() {
  stage_json "$1" | jq -r --arg o "Warehouse/$2" \
    '.status.freightHistory[0].items[$o].name // empty'
}

# Verification phase of the stage's current Freight collection.
stage_verification() {
  stage_json "$1" | jq -r '.status.freightHistory[0].verificationHistory[0].phase // "None"'
}

freight_tag() {
  freight_json | jq -r --arg n "$1" '.items[] | select(.metadata.name == $n) | .images[0].tag // "-"'
}

jira_status() {
  curl -fsS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    "${JIRA_BASE}/rest/api/3/issue/$1?fields=status" | jq -r '.fields.status.name'
}

jira_approve() {
  curl -fsS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\":\"${JIRA_APPROVE_TRANSITION}\"}}" \
    "${JIRA_BASE}/rest/api/3/issue/$1/transitions" >/dev/null
}

# Handle the human gates of a running uat/prod promotion once each.
handle_gates() {
  local promo="$1" state pr_url jira_key
  state="$(kargo get promotion "$promo" --project "$PROJECT" -o json | jq -c '.status.state // {}')"
  jira_key="$(jq -r '.change.key // empty' <<<"$state")"
  pr_url="$(jq -r '."open-pr".pr.url // empty' <<<"$state")"

  if [[ -n "$jira_key" && -z "${_GATE_JIRA_DONE:-}" ]]; then
    if [[ -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
      if [[ "$(jira_status "$jira_key")" != "Approved" ]]; then
        jira_approve "$jira_key" && log "approved $jira_key"
      fi
    else
      log "waiting for a human: move $jira_key to Approved: ${JIRA_BASE}/browse/${jira_key}"
    fi
    _GATE_JIRA_DONE=1
  fi

  if [[ -n "$pr_url" && -z "${_GATE_PR_DONE:-}" ]]; then
    if [[ "${AUTO_MERGE:-0}" == 1 ]]; then
      if [[ "$(gh pr view "$pr_url" --json state -q .state)" == OPEN ]]; then
        gh pr merge "$pr_url" --merge >/dev/null && log "merged $pr_url"
      fi
    else
      log "waiting for a human: merge $pr_url"
    fi
    _GATE_PR_DONE=1
  fi
}

# Promote Freight $2 to stage $1, handle gates, wait for success and
# verification. Returns non-zero on a failed promotion or verification.
promote_and_wait() {
  local stage="$1" freight="$2" out promo phase deadline v
  out="$(kargo promote --project "$PROJECT" --stage "$stage" --freight "$freight" 2>&1)" \
    || die "promote $stage: $out"
  promo="$(sed -nE 's#^promotion\.kargo\.akuity\.io/([^ ]+) .*#\1#p' <<<"$out")"
  [[ -n "$promo" ]] || die "could not parse promotion name from: $out"
  log "$stage: promotion $promo ($(freight_tag "$freight"))"

  unset _GATE_JIRA_DONE _GATE_PR_DONE
  deadline=$((SECONDS + PROMOTION_TIMEOUT))
  while :; do
    phase="$(kargo get promotion "$promo" --project "$PROJECT" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) break ;;
      Failed|Errored|Aborted)
        log "$stage: promotion $phase: $(kargo get promotion "$promo" --project "$PROJECT" -o jsonpath='{.status.message}')"
        return 1 ;;
      Running) [[ "$stage" == uat || "$stage" == prod ]] && handle_gates "$promo" ;;
    esac
    (( SECONDS < deadline )) || { log "$stage: promotion timed out"; return 1; }
    sleep 15
  done

  deadline=$((SECONDS + VERIFY_TIMEOUT))
  while :; do
    v="$(stage_verification "$stage")"
    [[ "$(stage_freight "$stage" app)" == "$freight" || "$(stage_freight "$stage" base-image)" == "$freight" ]] || v=None
    case "$v" in
      Successful) log "$stage: verified"; return 0 ;;
      Failed|Error|Aborted) log "$stage: verification $v"; return 1 ;;
    esac
    (( SECONDS < deadline )) || { log "$stage: verification timed out"; return 1; }
    sleep 15
  done
}

print_status() {
  local s app base
  printf '%-5s %-10s %-34s %s\n' STAGE APP BASE VERIFIED
  for s in "${STAGES[@]}"; do
    app="$(stage_freight "$s" app)"
    base="$(stage_freight "$s" base-image)"
    printf '%-5s %-10s %-34s %s\n' "$s" \
      "$( [[ -n "$app" ]] && freight_tag "$app" || echo -)" \
      "$( [[ -n "$base" ]] && freight_json | jq -r --arg n "$base" '.items[] | select(.metadata.name==$n) | .alias' || echo -)" \
      "$(stage_verification "$s")"
  done
}
