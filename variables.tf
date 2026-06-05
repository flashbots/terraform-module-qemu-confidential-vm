variable "volumes" {
  type = map(object({
    pool       = string
    capacity   = optional(string)
    format     = optional(string, "qcow2")
    source_url = optional(string)
    backing_store = optional(object({
      path   = string
      format = optional(string, "qcow2")
    }))
    permissions = optional(object({
      owner = optional(string)
      group = optional(string)
      mode  = optional(string)
    }))
  }))
  description = <<-EOT
    Map of libvirt storage volumes to create in pre-existing pools, keyed by
    volume name. The pool itself is not managed by this module and must
    already exist on the host.

    Per-volume fields:
    - `pool`: name of the existing libvirt storage pool to create the volume in
    - `capacity`: volume capacity as a number (optionally fractional) with a
      unit suffix, where `K` = KiB, `M` = MiB, `G` = GiB, `T` = TiB
      (binary/IEC units). For example `"100G"` is 100 GiB, `"2.2T"` is
      2.2 TiB. Resolved to an integer byte count internally. Required unless
      `source_url` is set (in which case capacity is derived from the source).
    - `format`: volume format (default `qcow2`)
    - `source_url`: URL to populate the volume from. Accepts `http(s)://...`,
      `file://...`, or a plain local file path. When set, the libvirt
      provider uploads the file into the pool at apply time.
    - `backing_store`: optional copy-on-write backing for the volume.
      `path` is the path of the backing file on the host; `format` defaults
      to `qcow2`.
    - `permissions`: optional `{ owner, group, mode }` for the resulting
      file on the host. Useful when the upload-time uid (the user running
      `terraform apply`) wouldn't otherwise be readable by the qemu user.
      For example `{ owner = "root", group = "root", mode = "0644" }`
      makes the volume world-readable regardless of who applied.

    Example:
    ```terraform
    volumes = {
      "buildernet-image.qcow2" = {
        pool       = "default"
        source_url = "https://downloads.buildernet.org/buildernet-images/v2.6.0/buildernet-qemu_v2.6.0.qcow2"
        permissions = {
          owner = "root"
          group = "root"
          mode  = "0644"
        }
      }
      "persistent" = {
        pool     = "vm-storage"
        capacity = "100G"
      }
    }
    ```
  EOT
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k, v in var.volumes :
      v.capacity == null || can(regex("^[0-9]+([.][0-9]+)?[KMGT]$", v.capacity))
    ])
    error_message = "volume capacity must be null or a number (optionally fractional) followed by one of K, M, G, or T (e.g. \"100G\", \"2.2T\")."
  }
}

variable "vms" {
  type = map(object({
    vcpu      = number
    memory    = string
    os_loader = optional(string, "/usr/share/ovmf/OVMF.inteltdx.fd")

    disks = list(object({
      source = object({
        file  = optional(string)
        block = optional(string)
        volume = optional(object({
          pool   = string
          volume = string
        }))
      })
      target = object({
        dev = string
        bus = optional(string, "virtio")
      })
      driver = optional(object({
        type    = optional(string, "raw")
        cache   = optional(string)
        io      = optional(string)
        discard = optional(string)
      }), {})
      read_only    = optional(bool, false)
      serial       = optional(string)
      boot_order   = optional(number)
      io_threading = optional(bool)
    }))

    interfaces = list(object({
      source = object({
        network = optional(string)
        bridge  = optional(string)
      })
      mac        = optional(string)
      model_type = optional(string, "virtio")
    }))
  }))
  description = <<-EOT
    Map of VM configurations keyed by VM name. See the inner
    `modules/qemu-confidential-vm` module variables for the meaning of each
    field.

    Example:
    ```terraform
    vms = {
      "cvm-01" = {
        vcpu   = 32
        memory = "64G"

        disks = [
          {
            source     = { volume = { pool = "default", volume = "buildernet-image.qcow2" } }
            target     = { dev = "vdc" }
            driver     = { type = "qcow2" }
            read_only  = true
            boot_order = 1
          },
          {
            source = { block = "/dev/vg0/cvm-01" }
            target = { dev = "vda" }
            driver = { type = "raw", cache = "none", io = "native", discard = "unmap" }
            serial = "persistent"
          },
        ]

        interfaces = [
          { source = { network = "default" } },
          { source = { bridge = "br0" }, mac = "52:54:00:aa:bb:cc" },
        ]
      }
    }
    ```
  EOT
}
