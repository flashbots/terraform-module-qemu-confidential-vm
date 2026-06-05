locals {
  # Binary/IEC multipliers for the capacity suffixes.
  unit_bytes = {
    K = 1024
    M = 1048576
    G = 1073741824
    T = 1099511627776
  }

  # Parse each volume's capacity (e.g. "2.2T") and convert to an integer
  # byte count. libvirt scales capacity as an integer, so a fractional
  # value with a large unit must be resolved to bytes here.
  volume_capacity = {
    for k, v in var.volumes : k =>
    v.capacity != null ? regex("^([0-9]+(?:[.][0-9]+)?)([KMGT])$", v.capacity) : null
  }
  volume_capacity_bytes = {
    for k, parts in local.volume_capacity : k =>
    parts != null ? floor(tonumber(parts[0]) * local.unit_bytes[parts[1]]) : null
  }
}

resource "libvirt_volume" "this" {
  for_each = var.volumes

  name = each.key
  pool = each.value.pool

  # capacity defaults to bytes when capacity_unit is unset
  capacity   = local.volume_capacity_bytes[each.key]
  # allocation = local.volume_capacity_bytes[each.key]

  target = {
    format = { type = each.value.format }
    permissions = each.value.permissions != null ? {
      owner = each.value.permissions.owner
      group = each.value.permissions.group
      mode  = each.value.permissions.mode
    } : null
  }

  create = each.value.source_url != null ? {
    content = { url = each.value.source_url }
  } : null

  backing_store = each.value.backing_store != null ? {
    path   = each.value.backing_store.path
    format = { type = each.value.backing_store.format }
  } : null
}

module "cvm" {
  source = "./modules/qemu-confidential-vm"

  for_each = var.vms

  vm_name    = each.key
  vcpu       = each.value.vcpu
  memory     = each.value.memory
  os_loader  = each.value.os_loader
  disks      = each.value.disks
  interfaces = each.value.interfaces

  depends_on = [libvirt_volume.this]
}
