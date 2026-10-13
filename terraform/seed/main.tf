resource "proxmox_download_file" "noble" {
  content_type = "iso"
  datastore_id = var.iso_storage
  node_name    = var.node_name
  url          = var.image_url
  file_name    = "noble-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippet_storage
  node_name    = var.node_name

  source_raw {
    file_name = "vm-demo-seed-user-data.yaml"
    data = templatefile("${path.module}/cloud-init.yaml", {
      ssh_public_key = trimspace(var.ssh_public_key)
    })
  }
}

resource "proxmox_virtual_environment_vm" "seed" {
  name        = var.template_name
  description = "vm-demo seed: Ubuntu 24.04 cloud image with qemu-guest-agent via cloud-init. Managed by Terraform."
  node_name   = var.node_name
  vm_id       = var.vm_id
  # Proxmox sorts tags; keep them sorted to avoid a permanent diff.
  tags = ["seed", "vm-demo"]

  template = true
  started  = false
  on_boot  = false

  agent {
    enabled = true
  }

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 1024
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.disk_storage
    file_id      = proxmox_download_file.noble.id
    interface    = "scsi0"
    size         = var.disk_size
    discard      = "on"
    iothread     = true
  }

  initialization {
    datastore_id = var.disk_storage

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # Ubuntu cloud images log to the serial console.
  serial_device {}

  vga {
    type = "serial0"
  }
}
