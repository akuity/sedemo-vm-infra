variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL."
  default     = "https://pve01.annarchy.net:8006/api2/json"
}

variable "proxmox_user" {
  type        = string
  description = "Proxmox user that owns the API token, e.g. vm-demo@pve."
  default     = env("PROXMOX_USER")
}

variable "proxmox_token_id" {
  type        = string
  description = "API token ID (the part after '!')."
  default     = env("PROXMOX_TOKEN_ID")
}

variable "proxmox_token_secret" {
  type        = string
  description = "API token secret."
  default     = env("PROXMOX_TOKEN_SECRET")
  sensitive   = true
}

variable "proxmox_node" {
  type    = string
  default = "pve01"
}

variable "clone_vm_id" {
  type        = number
  description = "VMID of the Terraform-managed seed template."
  default     = 9100
}

variable "vm_id" {
  type        = number
  description = "VMID of the resulting template (9101 + run_number % 90)."
}

variable "template_name" {
  type        = string
  description = "Name of the resulting template, ubuntu-2404-base-<YYYYMMDDhhmm>."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Deploy private key; its public half is installed in the seed by cloud-init."
}

variable "disk_storage" {
  type        = string
  description = "Datastore for the clone's disks and cloud-init drive."
  default     = "images"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "build_timestamp" {
  type        = string
  description = "Build timestamp written to /etc/vm-demo-base. Empty means now."
  default     = ""
}
