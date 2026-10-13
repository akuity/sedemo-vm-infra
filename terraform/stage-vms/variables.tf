variable "stage" {
  description = "Kargo stage whose VMs this state manages."
  type        = string

  validation {
    condition     = contains(["dev", "qa", "sit", "uat", "prod"], var.stage)
    error_message = "stage must be one of: dev, qa, sit, uat, prod."
  }
}

variable "template_vmid" {
  description = "VMID of the base template to clone (from images/base.json via deploy.yaml base_vmid)."
  type        = number

  validation {
    condition     = var.template_vmid >= 9100 && var.template_vmid <= 9190
    error_message = "template_vmid must be the seed (9100) or a baked base template (9101-9190)."
  }
}

variable "ssh_public_key" {
  description = "Deploy SSH public key for user ubuntu."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be an OpenSSH public key."
  }
}

variable "node_name" {
  description = "Proxmox node for the stage VMs."
  type        = string
  default     = "pve01"
}

variable "disk_storage" {
  description = "Datastore for cloned disks and the cloud-init drive."
  type        = string
  default     = "images"
}

variable "bridge" {
  description = "Network bridge for the VM NIC."
  type        = string
  default     = "vmbr0"
}
