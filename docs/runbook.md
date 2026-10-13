# VM Demo Runbook

Kargo promoting `rollouts-app` and an Ubuntu base image through
dev → qa → sit → uat → prod on Proxmox VMs, deployed by Ansible from GitHub
Actions. Target length: 6–8 minutes. All timings below are from the
2026-10-13 rehearsal.

## Links

| What | Where |
|---|---|
| Kargo project | https://kargo.akpdemoapps.link/project/vm-demo |
| Pipeline YAML | `akuity/sedemo-platform` `apps/vm-demo/kargo/` (`stages.yaml`, `project.yaml`) |
| Rendered config (what lands on each VM) | `akuity/sedemo-platform` branches `rendered/vm-demo/<stage>` |
| Converge runs | https://github.com/akuity/sedemo-vm-infra/actions/workflows/converge.yml |
| Prod change tickets | Jira project CHANGE, https://eddiewebb.atlassian.net/browse/CHANGE |
| Config chart (shared defaults) | `akuity/sedemo-monorepo` `vm-app/config-chart/values.yaml` |
| App on a VM | `http://<vm-ip>:8080/` (IPs: last `vm-health` verification log, or Proxmox) |

## Starting state (`scripts/demo/reset-demo.sh`)

| Stage | App | How it got there |
|---|---|---|
| dev, qa | `50-blue` (new release) | auto-promoted, verified |
| sit, uat, prod | `49-green` (current release) | verified |

All stages share the latest base image. Run the reset any time; it is
idempotent (≈12s when already in state, ≈6–10 min from a messy state):

```bash
cd ~/src/github.com/akuity/sedemo-vm-infra
AUTO_MERGE=1 scripts/demo/reset-demo.sh            # merges uat/prod PRs for you
# prod gate: approve the CHANGE issue it prints, or also set
# JIRA_EMAIL=... JIRA_API_TOKEN=... to approve it unattended
```

It stops (rather than guessing) when: a rehearsal change is still on `main`
(chart `errorRate`/`latency` not 0, or `namespace` missing from
`env/sit/values.yaml`), or a promotion is still in flight. The CLI cannot
abort promotions: abort them in the Kargo UI (Promotion → Abort), re-run.

## Pre-demo checklist (T-30 min)

1. `kargo login https://kargo.akpdemoapps.link --sso` and `gh auth status`.
2. Run the reset; confirm the final table matches the starting state.
3. Runner online: `gh api repos/akuity/sedemo-vm-infra/actions/runners -q '.runners[] | .name + " " + .status'`.
4. Agent healthy: Kargo UI → instance → Agents → `team-ada`.
5. Warm the converge tool cache: the first converge after a cache miss takes ~2 min instead of ~40s.
6. Tabs: Kargo project, `stages.yaml`, an app tab per VM you'll show (dev and prod-1), Jira CHANGE board.

## Segment script

1. **YAML first (answers "Kargo is click-ops").** `project.yaml` promotion
   policies (dev/qa auto, `autoRollback` on dev), then `stages.yaml`: prod's
   gates (PR, Jira CHANGE issue, converge, result comment). Point out every
   stage is pinned to `shard: team-ada`, an agent in the "datacenter".
2. **Opener: auto-rollback (~4 min, start it first and talk over it).**
   Edit `vm-app/config-chart/values.yaml` on `main`: `latency: 0` → `latency: 10`
   ("someone shipped a bad config"). New Freight → dev auto-promotes → `vm-health`
   fails (every `/color` request times out) → Kargo re-promotes the last good
   Freight with no human actor. qa never sees it.
   **Revert only after the rollback promotion (no actor) appears and dev is
   verified again (~3.5 min).** Reverting earlier creates newer Freight that dev
   auto-promotes before verification fails, so the auto-rollback never shows.
   **After an auto-rollback, dev's auto-promotion stays paused until a human
   promotes.** So after the revert, promote the new (fixed) Freight to dev
   yourself (`kargo promote --project vm-demo --stage dev --freight-alias <fix>`);
   qa then auto-follows. Say it out loud: Kargo won't roll forward on its own
   after a rollback; a person decides the fix is ready.
   Rehearsal: push 06:05:03, verification Failed ~06:08, rollback promotion 06:08:29.
3. **Same artifact everywhere.** Compare `rendered/vm-demo/dev` with `/qa`
   (both on the same Freight in the starting state): `rollouts-demo.env` differs
   only in `STAGE`/`NAMESPACE`, and `deploy.yaml` only in `stage`. The Freight
   pins the image and the chart commit, so what QA tested is what moves on.
4. **Release `50-blue` to sit (CLI, ~2 min):**
   `kargo promote --project vm-demo --stage sit --freight-alias <blue alias>`
5. **uat with the SysOps PR (~3 min):** promote in the UI; open the PR Kargo
   creates. The diff is exactly the two files that land on the VM. Merge it.
6. **prod (~3.5 min):** promote; Kargo opens the PR *and* a CHANGE issue.
   Move the issue to **Approved**, merge the PR; converge rolls vm-prod-1 then
   vm-prod-2; Kargo comments the result on the issue. Show the app turning blue.
   **Show the change ticket as the release manager sees it:** the CHANGE issue
   is a release summary of what prod runs now vs. what's coming: Application
   (tag change, rollouts-app commits, compare link), Configuration (chart
   commits, compare link, the rendered-config PR), Base image (template change
   and the OS package diff, e.g. `+ auditd`, `~ openssl a -> b`).
   **Then show the audit trail:** Kargo project → Events (or Akuity org audit
   log, actions `custom-*`): promotion-requested (who promoted), change-approved
   (`jira:<approver>`), pr-merged (`github:<login>`), deployed (with the
   converge run link) — every human input, attributed, per promotion.
7. **Rollback prod (~3.5 min):** `kargo promote --project vm-demo --stage prod --freight-alias <green alias>`:
   same PR + CHANGE gates; bubbles go back to green. "Rollback is just another
   audited promotion."
8. **(Optional) OS patching (~5 min per stage with replacement):** dispatch
   `bake-base-image.yml`; the new template becomes base-image Freight; dev and qa
   replace their VMs automatically; prod replaces one VM at a time. Pre-roll
   this before the call if time is short.

Not shown live (tested): a missing per-stage value (delete `namespace` from
`env/sit/values.yaml`) fails the sit promotion at `helm-template` with
`namespace is required`, before any VM is touched.

## Gotchas found in rehearsal

- **One promotion moves one Freight.** A ticket shows the app *or* the base
  image changing; the other section reads "(unchanged)" / "no package changes".
  For a package diff on stage, promote a new base image (`bake-base-image.yml`,
  ~5 min) to prod; images baked before 2026-10-13 16:09 UTC have no manifest.
- **Hand-assembled Freight has no source revision** (e.g. `steady-green`), so
  its app section reads "(unknown revision)". Warehouse Freight is exact.

- **Do not use `errorRate` for the bad-config story.** `rollouts-app` inverts
  `ERROR_RATE` (500 when `rand(100) >= ERROR_RATE`): 100 never errors, 1 errors
  ~99%. Use `latency: 10`.
- **First promotion into an empty stage** must include both Freight origins;
  promote the missing one second. Only relevant after a full teardown.
- **A recreated Freight keeps its content-hash name**, and Kargo will not
  auto-promote Freight that already failed on that stage. The reset promotes
  dev explicitly for this reason.
- **Verification Secret** lives in the Kargo project
  (`kargo create generic-credentials --project vm-demo vm-demo-proxmox-verify`);
  the agent mirrors it to the homelab cluster per AnalysisRun.
- **Merge order at prod doesn't matter**: Kargo waits for Jira first, then the PR.

## Recovery moves

| Symptom | Fix |
|---|---|
| Promotion stuck at a gate you don't want to finish | Kargo UI → Promotion → Abort; close its PR |
| Converge failed | Open the run from the promotion's step link; re-promote the same Freight after fixing |
| Verification can't find VMs | Guest agent slow after replacement; `kargo verify stage <s> --project vm-demo` |
| Everything confusing | Abort in-flight promotions, revert rehearsal commits, run the reset |

## Housekeeping after the demo

- Rotate/delete the classic runner PAT (`fleet-infra/annarchy.net/arc-github-token-classic`, 7-day expiry).
- `akuity kargo agent delete ... team-ada` and remove the `akuity` namespace on annarchy when the demo is retired.
- Old unused ghcr package `sedemo-monorepo-nav-service` (private) can be deleted by an org admin.
- ServiceNow CHG0030032 / CHG0030033 on `dev314516` can be cancelled by its owner.
