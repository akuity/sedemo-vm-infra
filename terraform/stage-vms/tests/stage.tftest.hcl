# Offline checks: run with `terraform init -backend=false && terraform test`.
mock_provider "proxmox" {}

variables {
  template_vmid  = 9101
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnly test"
}

run "rejects_unknown_stage" {
  command = plan

  variables {
    stage = "bogus"
  }

  expect_failures = [var.stage]
}

run "prod_has_two_vms_in_order" {
  command = plan

  variables {
    stage = "prod"
  }

  assert {
    condition     = output.vm_names == ["vm-prod-1", "vm-prod-2"]
    error_message = "prod must roll vm-prod-1 then vm-prod-2"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.vm["vm-prod-2"].vm_id == 7106
    error_message = "vm-prod-2 must be VMID 7106"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.vm["vm-prod-1"].tags == tolist(["stage-prod", "vm-demo"])
    error_message = "prod VMs must be tagged vm-demo and stage-prod"
  }
}

run "dev_clones_requested_template" {
  command = plan

  variables {
    stage = "dev"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.vm["vm-dev"].clone[0].vm_id == 9101
    error_message = "vm-dev must clone template_vmid"
  }

  assert {
    condition     = upper(proxmox_virtual_environment_vm.vm["vm-dev"].network_device[0].mac_address) == "BC:24:11:D0:00:01"
    error_message = "vm-dev must use its fixed MAC"
  }
}
