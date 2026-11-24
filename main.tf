locals {
  # Binary/IEC multipliers for the capacity suffixes.
  unit_bytes = {
    K = 1024
    M = 1048576
    G = 1073741824
    T = 1099511627776
  }

  # Parse each volume's capacity/allocation (e.g. "1G") and convert to an
  # integer byte count. libvirt scales capacity as an integer, so a
  # fractional value with a large unit must be resolved to bytes here.
  volume_capacity = {
    for k, v in var.volumes : k =>
    v.capacity != null ? regex("^([0-9]+(?:[.][0-9]+)?)([KMGT])$", v.capacity) : null
  }
  volume_capacity_bytes = {
    for k, parts in local.volume_capacity : k =>
    parts != null ? floor(tonumber(parts[0]) * local.unit_bytes[parts[1]]) : null
  }
  volume_allocation = {
    for k, v in var.volumes : k =>
    v.allocation != null ? regex("^([0-9]+(?:[.][0-9]+)?)([KMGT])$", v.allocation) : null
  }
  volume_allocation_bytes = {
    for k, parts in local.volume_allocation : k =>
    parts != null ? floor(tonumber(parts[0]) * local.unit_bytes[parts[1]]) : null
  }

  # Volumes populated from a private Cloudflare R2 bucket.
  s3_volumes = {
    for k, v in var.volumes : k => v
    if startswith(coalesce(v.source_url, "-"), "s3://")
  }
}

# Signed GET URL for each s3:// (Cloudflare R2) source, made on every plan from
# the CLOUDFLARE_API_TOKEN environment variable. The libvirt provider fetches
# the URL from the machine running terraform, at create time only. It must
# still be valid then, so apply a saved plan within 24 hours.
data "external" "presigned_url" {
  for_each = local.s3_volumes

  program = ["python3", "${path.module}/scripts/r2-presign.py"]
  query = {
    url        = each.value.source_url
    account_id = coalesce(var.r2_account_id, "-")
    expires    = "86400"
  }

  lifecycle {
    precondition {
      condition     = var.r2_account_id != null
      error_message = "Volume \"${each.key}\" has an s3:// source_url, but r2_account_id is not set."
    }
  }
}

# Stable record of each volume's source. The volume is replaced when this
# changes, not when the presigned URL rotates.
resource "terraform_data" "volume_source" {
  for_each = var.volumes

  input = each.value.source_url
}

resource "libvirt_volume" "this" {
  for_each = var.volumes

  name = each.key
  pool = each.value.pool

  # capacity/allocation default to bytes when the *_unit attrs are unset
  capacity   = local.volume_capacity_bytes[each.key]
  allocation = local.volume_allocation_bytes[each.key]

  target = {
    format = { type = each.value.format }
    permissions = each.value.permissions != null ? {
      owner = each.value.permissions.owner
      group = each.value.permissions.group
      mode  = each.value.permissions.mode
    } : null
  }

  create = each.value.source_url != null ? {
    content = {
      url = (
        contains(keys(local.s3_volumes), each.key)
        ? sensitive(data.external.presigned_url[each.key].result.url)
        : each.value.source_url
      )
    }
  } : null

  backing_store = each.value.backing_store != null ? {
    path   = each.value.backing_store.path
    format = { type = each.value.backing_store.format }
  } : null

  lifecycle {
    # `create` holds the presigned URL for s3:// sources, which changes on
    # every plan. Source changes are tracked by terraform_data.volume_source.
    ignore_changes       = [create]
    replace_triggered_by = [terraform_data.volume_source[each.key]]
  }
}

module "cvm" {
  source = "./modules/qemu-confidential-vm"

  for_each = var.vms

  vm_name    = each.key
  vcpu       = each.value.vcpu
  memory     = each.value.memory
  os_loader  = each.value.os_loader
  autostart  = each.value.autostart
  cpu        = each.value.cpu
  disks      = each.value.disks
  interfaces = each.value.interfaces

  depends_on = [libvirt_volume.this]
}
