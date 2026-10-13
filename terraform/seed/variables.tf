variable "node_name" {
  description = "Proxmox node that holds the seed template."
  type        = string
  default     = "pve01"
}

variable "vm_id" {
  description = "VMID of the seed template."
  type        = number
  default     = 9100
}

variable "template_name" {
  description = "Name of the seed template."
  type        = string
  default     = "ubuntu-2404-seed"
}

variable "disk_storage" {
  description = "Datastore for VM disks and the cloud-init drive (content type images)."
  type        = string
  default     = "images"
}

variable "iso_storage" {
  description = "Datastore that receives the downloaded cloud image (content type iso)."
  type        = string
  default     = "isos"
}

variable "snippet_storage" {
  description = "Datastore for the cloud-init user-data snippet (content type snippets)."
  type        = string
  default     = "isos"
}

variable "bridge" {
  description = "Network bridge for the VM NIC."
  type        = string
  default     = "vmbr0"
}

variable "image_url" {
  description = "Ubuntu 24.04 (noble) cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "disk_size" {
  description = "Boot disk size in GiB."
  type        = number
  default     = 10
}

variable "ssh_public_key" {
  description = "Deploy SSH public key installed for user ubuntu."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be an OpenSSH public key."
  }
}
