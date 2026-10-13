# Changing the template (a base-image promotion) replaces every VM in the stage.
# converge.sh applies with -target one VM at a time, so prod is replaced and
# redeployed VM by VM.
resource "terraform_data" "template" {
  for_each = local.stage_vms

  input = var.template_vmid
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.stage_vms

  name        = each.key
  description = "vm-demo ${var.stage} VM. Managed by Terraform (sedemo-vm-infra)."
  node_name   = var.node_name
  vm_id       = each.value.vmid
  # Proxmox sorts tags; keep them sorted to avoid a permanent diff.
  tags = sort(["vm-demo", "stage-${var.stage}"])

  started         = true
  on_boot         = true
  stop_on_destroy = true

  clone {
    vm_id        = var.template_vmid
    full         = true
    datastore_id = var.disk_storage
  }

  # Wait for the guest agent to report an IPv4 address before apply returns,
  # so the inventory that runs next can see it.
  agent {
    enabled = true
    timeout = "5m"

    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 1024
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = each.value.mac
  }

  initialization {
    datastore_id = var.disk_storage

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "ubuntu"
      keys     = [trimspace(var.ssh_public_key)]
    }
  }

  lifecycle {
    replace_triggered_by = [terraform_data.template[each.key]]
  }
}
