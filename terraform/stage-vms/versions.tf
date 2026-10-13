terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
  }

  # One state Secret per stage. Supply at init time:
  #   -backend-config=secret_suffix=vm-demo-<stage>
  # plus in_cluster_config=true (runner pod) or config_path=~/.kube/config-annarchy.
  backend "kubernetes" {
    namespace = "arc-runners"
  }
}

# Configured from the environment: PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN,
# PROXMOX_VE_INSECURE. Cloning needs no SSH access to the node.
provider "proxmox" {}
