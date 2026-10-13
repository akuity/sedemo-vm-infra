locals {
  # Keep in sync with STAGE_VMS in scripts/converge.sh (checked by scripts/test_converge_lists.sh).
  vms = {
    dev = [
      { name = "vm-dev", vmid = 7101, mac = "BC:24:11:D0:00:01" },
    ]
    qa = [
      { name = "vm-qa", vmid = 7102, mac = "BC:24:11:D0:00:02" },
    ]
    sit = [
      { name = "vm-sit", vmid = 7103, mac = "BC:24:11:D0:00:03" },
    ]
    uat = [
      { name = "vm-uat", vmid = 7104, mac = "BC:24:11:D0:00:04" },
    ]
    prod = [
      { name = "vm-prod-1", vmid = 7105, mac = "BC:24:11:D0:00:05" },
      { name = "vm-prod-2", vmid = 7106, mac = "BC:24:11:D0:00:06" },
    ]
  }

  stage_vms = { for vm in local.vms[var.stage] : vm.name => vm }
}
