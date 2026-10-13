# VM Deployment Demo: Kargo Promotions to Proxmox VMs

- **Date:** 2026-10-12
- **Status:** Draft, pending review
- **Audience:** Prospect technical demo (2026-10-13). No customer or person
  names appear in this repo or in the public repos (`sedemo-platform`,
  `sedemo-monorepo`).

## Purpose

Show that Kargo governs VM-based deployments with the same Freight, gates and
audit trail it uses for Kubernetes, by driving the customer's existing
mechanism (Ansible run from GitHub Actions) rather than replacing it.

Prospect pains this answers:

1. "How do I know what was copy-pasted to SIT is what was in QA?" Freight pins
   the app artifact and the config chart commit, so every stage gets the same
   shared config; only the stage's own `values.yaml` differs. The rendered file
   in git is byte-for-byte what lands on that stage's VM.
2. SysOps approve PRs without seeing the real change. UAT/prod PRs contain the
   rendered config and deploy pin, i.e. exactly what will land.
3. Manual SysOps sync during the change window. Prod waits on the ServiceNow
   change request, then deploys itself.
4. Missed config values (hours to a day each). Required per-env values fail
   rendering before any VM is touched.
5. The "Kargo is click-ops" objection. Everything is YAML; dev and qa auto-promote;
   rollback is driven from the CLI.

## Success criteria

- A live promotion travels dev → qa → sit → uat → prod, with the UAT/prod PRs
  showing the rendered config diff and prod gated by a ServiceNow CR.
- A bad config pushed to the monorepo fails verification in dev and is
  auto-rolled back with no human actor; it never reaches qa.
- A config missing a required per-env value fails at render time.
- Promoting the previous Freight to prod restores the previous version on both
  prod VMs, through the same CR and PR gates.
- A new Packer base image is promoted through the stages and replaces VMs,
  with prod replaced one VM at a time.
- Everything (template, VMs, runner, agent, pipeline) is reproducible from git.

## Decisions

| Topic | Decision |
|---|---|
| VM hypervisor | Proxmox (homelab), presented from home |
| OS | Ubuntu 24.04 cloud image |
| Image build | Packer `proxmox-clone` from a Terraform-created seed template |
| VM lifecycle | Terraform `bpg/proxmox`, state in Kubernetes Secret backend |
| App deploy | Ansible from GitHub Actions on a self-hosted ARC runner |
| Runner repo | New private repo `akuity/sedemo-vm-infra` (public repos must not host self-hosted runners) |
| Kargo execution | Self-hosted Kargo agent in homelab cluster, shard `homelab` |
| Warehouses | Two: `nav-service` (app + config) and `base-image` (Packer output) |
| Config | Rendered by Kargo with `helm-template`; Ansible copies verbatim, no templating on host |

## Architecture

### Repositories

**`akuity/sedemo-monorepo` (public), `vm-app/`**

- `app/`: Go HTTP service `nav-service` (fund NAV pricing). Endpoints:
  `/` (HTML page: version, stage, key config values), `/version` (JSON
  `{version, stage, configHash}`), `/healthz` (returns 500 when `pricing.feedUrl`
  is not a valid `https://` URL; deterministic, no network dependency). Reads `/etc/nav-service/config.yaml`.
- `config-chart/`: Helm chart whose only template renders `config.yaml`.
  Shared defaults in `values.yaml`; per-env keys use `required`.
- `.github/workflows/publish-vm-app.yml`: on push to `vm-app/app/**`, build a
  static linux/amd64 binary, `oras push ghcr.io/akuity/sedemo-monorepo-nav-service:<semver>`
  a tarball containing the binary and systemd unit. Version from a `VERSION`
  file.

**`akuity/sedemo-vm-infra` (private, this repo)**

- `terraform/seed/`: downloads the Ubuntu 24.04 cloud image
  (`proxmox_virtual_environment_download_file`) and creates seed template
  `ubuntu-2404-seed` with cloud-init installing `qemu-guest-agent`.
- `packer/ubuntu-2404/`: `proxmox-clone` of the seed; apt upgrade, install
  base packages, create `nav` service user, directories, hardening; outputs
  template `ubuntu-2404-base-<YYYYMMDDhhmm>` with a new VMID.
- `images/base.json`: `{ "template": "...", "vmid": N, "built": "...", "packer_commit": "..." }`,
  committed by the bake workflow; watched by the `base-image` Warehouse.
- `terraform/stage-vms/`: module + root config keyed by stage; VMs cloned
  from the template in the stage's `deploy.yaml`; DHCP addressing with a
  fixed MAC per VM (replacements usually keep their lease) and Proxmox tags
  `vm-demo` + `stage-<stage>`; guest agent enabled and awaited before
  reporting an IP; Kubernetes backend (`secret_suffix = <stage>`).
- `ansible/inventory/proxmox.yml`: `community.general.proxmox` dynamic
  inventory, groups from Proxmox tags, `ansible_host` from guest-agent IPs.
  No IP addresses are stored anywhere in git.
- `ansible/deploy.yml`: `serial: 1`; `oras pull` the pinned artifact,
  install binary and unit, copy rendered `config.yaml`, restart, wait for
  `/healthz` and matching `/version`.
- `.github/workflows/bake-base-image.yml` (manual): Packer build, write and
  commit `images/base.json`.
- `.github/workflows/converge.yml` (`workflow_dispatch`, inputs `stage`,
  `platform_sha`): checkout `sedemo-platform` at `platform_sha`, read
  `apps/vm-demo/env/<stage>/rendered/deploy.yaml`, Terraform apply for that
  stage (prod: per-VM `-target`, then deploy that VM, then next), Ansible
  deploy. Idempotent: an app promotion is a Terraform no-op; a base-image
  promotion replaces VMs and redeploys the stage's current app version.
- Secrets (repo Actions secrets): Proxmox API token (Packer/Terraform/inventory), Ansible SSH private key,
  ghcr read token. None of these live in Kargo or the public repos.
- `docs/`: this spec, implementation plan, demo runbook, reset script.

**`akuity/sedemo-platform` (public), `apps/vm-demo/`**

- `kargo/`: Project + ProjectConfig, two Warehouses, five Stages, PromotionTask
  `vm-promote`, AnalysisTemplate(s), credentials references. The verification
  job's read-only Proxmox token is referenced by Secret name only; the Secret
  itself is created out-of-band (or sealed in fleet-infra), never committed
  here.
- `env/<stage>/values.yaml`: env-specific config values (platform-owned).
- `env/<stage>/rendered/{config.yaml,deploy.yaml}`: written only by Kargo.
- Argo CD Application/ApplicationSet that syncs `kargo/` to the Kargo
  instance, following the existing `apps/*` pattern.

**`adamancini/fleet-infra` (homelab cluster `annarchy.net`)**

- ARC `gha-runner-scale-set` controller + scale set registered to
  `akuity/sedemo-vm-infra`, ephemeral runner pods; runner image or workflow
  setup provides terraform, packer, ansible, oras.
- ServiceAccount + Role for Terraform state Secrets/Leases in the runner
  namespace.
- Akuity Kargo agent (shard `homelab`) registered to the akpdemoapps Kargo
  instance.

### VMs

`vm-dev`, `vm-qa`, `vm-sit`, `vm-uat`, `vm-prod-1`, `vm-prod-2`, plus a
transient Packer build VM. All addresses come from the homelab DHCP server,
which does not register hostnames in DNS, so every consumer discovers IPs
through the Proxmox API (guest agent) by tag. Node `pve01`, storage `images`
unless told otherwise.

## Kargo pipeline

### Warehouses

- `nav-service`: `image` subscription on
  `ghcr.io/akuity/sedemo-monorepo-nav-service` (SemVer) and `git`
  subscription on `sedemo-monorepo`, `includePaths: [vm-app/config-chart]`.
- `base-image`: `git` subscription on `sedemo-vm-infra`,
  `includePaths: [images]`.

Every Stage requests Freight from both origins.

### Stages

| Stage | Sources | Promotion | Gate | Verification |
|---|---|---|---|---|
| dev | Warehouses | auto, `autoRollback` | commit + push | `/healthz` + `/version` |
| qa | dev | auto | commit + push | same + smoke-test job |
| sit | qa | manual | commit + push | same |
| uat | sit | manual | `git-open-pr` + `git-wait-for-pr` | same |
| prod | uat | manual | `snow-create` CR → `snow-wait-for-condition` (Implement) → PR + wait → deploy → `snow-update` close | same, both VMs |

All Stages set `shard: homelab`. Verification runs as AnalysisTemplate jobs on
the homelab agent's cluster, which can reach the VMs directly. The job script
(curl + jq) queries the Proxmox API with a read-only token for VMs tagged
`stage-<stage>`, reads each VM's guest-agent IPv4, then checks `/healthz`
(200) and `/version` (`version` equals the promoted app version). It fails if
the expected VM count is not found.

### PromotionTask `vm-promote`

1. `git-clone` `sedemo-platform` (main), `sedemo-monorepo` at the
   `nav-service` Freight commit, `sedemo-vm-infra` at the `base-image` Freight
   commit.
2. `yaml-parse` `images/base.json` to get template name/VMID.
3. `helm-template` config chart with `env/<stage>/values.yaml`, set
   `version`/`stage`, output `env/<stage>/rendered/config.yaml`.
4. `yaml-update` `env/<stage>/rendered/deploy.yaml`: `app_version`,
   `artifact`, `base_template`, `base_vmid`, `freight`.
5. Commit/push (dev, qa, sit) or open PR and wait (uat, prod; prod wraps with
   ServiceNow steps).
6. `gha-dispatch-workflow` `converge.yml` in `sedemo-vm-infra` with
   `stage` and the resulting `platform_sha`; `gha-wait-for-workflow`
   `expectedConclusion: success`.

### Rollback scenarios

1. **Render-time catch:** remove a required SIT value; promotion to sit fails
   at `helm-template`; no VM touched.
2. **Auto-rollback (opener):** push a config change with a bad pricing feed
   URL. dev auto-promotes, `/healthz` fails, `autoRollback` (Kargo 1.11+)
   re-promotes the last good Freight with no human actor. Freight never
   verifies in dev, so qa never sees it.
3. **Prod rollback:** `kargo promote` previous Freight to prod; it passes the
   same CR and PR gates. No auto-rollback on prod because re-promotion would
   block on human gates.

## Risks and spikes (run first)

| # | Assumption | Spike | Fallback |
|---|---|---|---|
| S1 | Kargo `image` subscription accepts an `oras`-pushed tarball artifact | push `0.0.1`, throwaway Warehouse, confirm Freight | `FROM scratch` image wrapping the binary; Ansible extracts with `crane export` |
| S2 | Self-hosted agent can be added to the akpdemoapps Kargo instance and Stages pinned to it | list/create agent via Akuity MCP | hosted shard; health checks move into `converge.yml` |
| S3 | ServiceNow PDI awake, `kargo-step-snow` valid | `snow-create` from a scratch stage | prod with PR gate only; ServiceNow shown via `demo-snow` |
| S4 | Kargo gha steps can dispatch in a private repo | dispatch a no-op workflow | broader-scope token |

Known gotchas designed around: Ubuntu cloud image lacks `qemu-guest-agent`
(seed installs it; every IP lookup depends on it, so Terraform and the
inventory wait for the agent); DHCP leases can change on VM replacement
(fixed MACs make it unlikely, and nothing depends on a stable IP); confirm `bpg/proxmox` replaces on
`clone` source change, else `converge.yml` uses `-replace=`; Kubernetes
backend RBAC; pod network reachability to Proxmox API and VM IPs;
`kyverno-policy-check` is not used (it performs no policy check).

## Build order

1. Spikes S1 to S4.
2. In parallel (worktrees): (A) app + chart + publish workflow; (B) Kargo
   manifests; (C) Packer/Terraform/Ansible/workflows; (D) fleet-infra ARC +
   agent.
3. Live, sequential: seed template → bake → Terraform 6 VMs → publish v1.0.0
   and v1.1.0 → manual converge dispatch → apply Kargo project → end-to-end
   dev to prod.
4. Failure scenarios.
5. Demo runbook, reset script, one rehearsal.

### Cut order under time pressure

1. qa smoke-test job.
2. Rolling prod replacement (one prod VM).
3. Live base-image rollout through all stages (pre-roll, show dev live).
4. Homelab Kargo agent (S2 fallback).

Never cut: rendered-config PR, prod ServiceNow CR, dev auto-rollback, prod
rollback.

## Out of scope

Kubernetes-side demo content, New Relic integration (mechanism shown with
HTTP verification; Argo Rollouts supports New Relic natively), Windows VMs,
Azure.

## Open inputs from presenter

- Confirm node `pve01` / storage `images`.
- Proxmox token for Packer/Terraform/inventory: reuse existing
  `packer-api-token` in `pass` or create a dedicated `vm-demo` token.
- A read-only Proxmox token (`PVEAuditor`) for Kargo verification.
