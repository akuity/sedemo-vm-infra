output "vm_names" {
  description = "VM names in this stage, in rollout order."
  value       = [for vm in local.vms[var.stage] : vm.name]
}

output "vm_ipv4" {
  description = "Guest-agent IPv4 addresses per VM (informational; nothing depends on them)."
  value       = { for name, vm in proxmox_virtual_environment_vm.vm : name => vm.ipv4_addresses }
}
