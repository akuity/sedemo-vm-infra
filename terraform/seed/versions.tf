terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
  }

  # State lives in a Secret in the runner namespace of the homelab cluster.
  # Pick the cluster credentials at init time:
  #   in cluster (runner pod): -backend-config=in_cluster_config=true
  #   workstation:             -backend-config=config_path=~/.kube/config-annarchy
  backend "kubernetes" {
    secret_suffix = "vm-demo-seed"
    namespace     = "arc-runners"
  }
}

# Configured entirely from the environment:
#   PROXMOX_VE_ENDPOINT   https://pve01.annarchy.net:8006/
#   PROXMOX_VE_API_TOKEN  user@realm!id=secret
#   PROXMOX_VE_INSECURE   true when the API certificate is self-signed
# The cloud-init snippet upload goes over SSH to the node, so also set
#   PROXMOX_VE_SSH_USERNAME and PROXMOX_VE_SSH_AGENT=true (or PROXMOX_VE_SSH_PRIVATE_KEY).
provider "proxmox" {}
