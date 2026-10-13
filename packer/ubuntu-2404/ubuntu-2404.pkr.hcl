packer {
  required_plugins {
    proxmox = {
      version = "= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

locals {
  build_timestamp = var.build_timestamp != "" ? var.build_timestamp : timestamp()
}

source "proxmox-clone" "ubuntu" {
  proxmox_url              = var.proxmox_url
  username                 = "${var.proxmox_user}!${var.proxmox_token_id}"
  token                    = var.proxmox_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true
  # A full clone of the 10G seed onto NFS takes ~90s; the 1m default times out.
  task_timeout = "10m"

  clone_vm_id = var.clone_vm_id
  full_clone  = true

  vm_id                = var.vm_id
  vm_name              = "packer-${var.template_name}"
  template_name        = var.template_name
  template_description = "vm-demo base image built ${local.build_timestamp} from seed ${var.clone_vm_id}"
  # Proxmox sorts tags: vm-demo;base
  tags = "base;vm-demo"

  os              = "l26"
  cpu_type        = "x86-64-v2-AES"
  cores           = 2
  memory          = 2048
  scsi_controller = "virtio-scsi-single"

  network_adapters {
    model  = "virtio"
    bridge = var.bridge
  }

  # The seed's cloud-init (user ubuntu + deploy key + qemu-guest-agent) runs in
  # the build VM; Packer reads the DHCP address from the guest agent.
  qemu_agent              = true
  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage

  ipconfig {
    ip = "dhcp"
  }

  communicator         = "ssh"
  ssh_username         = "ubuntu"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "15m"
}

build {
  sources = ["source.proxmox-clone.ubuntu"]

  provisioner "shell" {
    script           = "${path.root}/scripts/provision.sh"
    environment_vars = ["BUILD_TIMESTAMP=${local.build_timestamp}"]
    execute_command  = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
  }

  # Package manifest for this image ("<package> <version>", sorted). The bake
  # workflow commits it as images/packages.txt so Kargo can diff the OS
  # contents of two base images for the release ticket.
  provisioner "shell" {
    inline = ["dpkg-query -W -f='$${Package} $${Version}\\n' | LC_ALL=C sort > /tmp/packages.txt"]
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/packages.txt"
    destination = "${path.root}/packages.txt"
  }
}
