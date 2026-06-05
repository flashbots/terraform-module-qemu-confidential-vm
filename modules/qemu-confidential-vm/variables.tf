variable "vm_name" {
  type        = string
  description = "Name of the libvirt domain"
  nullable    = false
}

variable "vcpu" {
  type        = number
  description = "Number of vCPUs allocated to the VM"
  nullable    = false
}

variable "memory" {
  type        = string
  description = <<-EOT
    Memory allocated to the VM, as a number with a unit suffix.
    `K` = KiB, `M` = MiB, `G` = GiB (binary/IEC units). For example
    `"64G"` is 64 GiB, `"512M"` is 512 MiB.
  EOT
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+[KMG]$", var.memory))
    error_message = "memory must be a number followed by one of K, M, or G (e.g. \"64G\")."
  }
}

variable "os_loader" {
  type        = string
  description = "Path on the host to the UEFI firmware loader. Make sure it supports Intel TDX."
  nullable    = false
}

variable "disks" {
  type = list(object({
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
  description = <<-EOT
    List of disks to attach to the VM. Each entry sets exactly one of
    `source.file`, `source.block`, or `source.volume` to point at the
    backing storage on the host.

    Fields per disk:
    - `source.file`: path to a file-backed disk image (qcow2, raw, etc.)
    - `source.block`: path to a host block device (e.g. an LVM volume)
    - `source.volume`: reference to a libvirt storage volume by `{ pool, volume }`
    - `target.dev`: guest-side device name (e.g. `vda`, `vdb`)
    - `target.bus`: guest-side bus (default `virtio`)
    - `driver.type`: image format (`raw` for block devices, `qcow2` for qcow2 files)
    - `driver.cache`, `driver.io`, `driver.discard`: passed through to the qemu driver
    - `read_only`: mount the disk read-only (typical for a boot image)
    - `serial`: stable serial string the guest sees (matched on by udev / `/dev/disk/by-id/...`)
    - `boot_order`: BIOS boot priority (lower = earlier)
    - `io_threading`: opt in to the hardcoded multi-queue + io_thread fan-out
      (8 queues across 4 io_threads). Set `true` for performance-sensitive
      writable block-backed disks; leave unset / `false` otherwise.
  EOT
  nullable    = false

  validation {
    condition = alltrue([
      for d in var.disks :
      length([for v in [d.source.file, d.source.block, d.source.volume] : v if v != null]) == 1
    ])
    error_message = "Each disk must set exactly one of source.file, source.block, or source.volume."
  }
}

variable "interfaces" {
  type = list(object({
    source = object({
      network = optional(string)
      bridge  = optional(string)
    })
    mac        = optional(string)
    model_type = optional(string, "virtio")
  }))
  description = <<-EOT
    List of network interfaces. Each entry sets exactly one of
    `source.network` (libvirt network name) or `source.bridge` (host bridge name).

    Fields per interface:
    - `source.network`: name of a libvirt network on the host
    - `source.bridge`: name of a Linux bridge on the host
    - `mac`: MAC address; if unset, libvirt generates one
    - `model_type`: NIC model (default `virtio`)
  EOT
  nullable    = false

  validation {
    condition = alltrue([
      for i in var.interfaces :
      length([for v in [i.source.network, i.source.bridge] : v if v != null]) == 1
    ])
    error_message = "Each interface must set exactly one of source.network or source.bridge."
  }
}
