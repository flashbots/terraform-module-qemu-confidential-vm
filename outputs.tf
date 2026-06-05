output "vm_details" {
  value = {
    for k, vm in module.cvm : k => {
      id   = vm.domain_id
      name = vm.domain_name
    }
  }
  description = "Details of created VMs"
}

output "volumes" {
  value = {
    for k, v in libvirt_volume.this : k => {
      id   = v.id
      path = v.path
      pool = v.pool
    }
  }
  description = "Map of libvirt volumes created by this module"
}
