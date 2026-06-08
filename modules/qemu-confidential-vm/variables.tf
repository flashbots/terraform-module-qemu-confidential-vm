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

variable "cpu" {
  type = object({
    topology = optional(object({
      sockets = number
      cores   = number
      threads = number
      dies    = optional(number)
    }))
    numa = optional(list(object({
      cpus      = string
      memory    = string
      host_cpus = optional(string)
      host_node = optional(number)
    })))
    pinning = optional(object({
      emulator_cpus  = optional(string)
      io_thread_cpus = optional(string)
    }))
  })
  description = <<-EOT
    Optional CPU topology, NUMA, and pinning configuration. The TDX-required
    `cpu.mode = "host-passthrough"` and `cpu.check = "none"` are always
    set by the module — only the topology, NUMA layout, and pinning are exposed.

    - `topology`: SMP layout. The product
      `sockets * (dies | 1) * cores * threads` must equal `vcpu`.
    - `numa`: ordered list of NUMA cells. Each cell gets an auto-assigned
      `nodeid` from its list index (0, 1, 2, ...). Per cell:
      - `cpus`: vCPU list in libvirt format (e.g. `"0-31"`, `"0,2-7"`)
      - `memory`: cell memory size with K/M/G suffix (e.g. `"32G"`)
      - `host_cpus` (optional): the **host** physical CPU set this cell's
        vCPUs are pinned to (libvirt cpuset syntax, e.g. `"0-13,28-41"`).
        Copy the per-node CPU list straight from `numactl -H` on the host.
      - `host_node` (optional): the **host** NUMA node id this cell's memory
        is strictly bound to (e.g. `0`).
    - `pinning` (optional): where to place the non-vCPU threads.
      - `emulator_cpus`: host cpuset for the QEMU emulator thread.
      - `io_thread_cpus`: host cpuset for the disk IOThreads.

    ### CPU pinning

    Pinning is enabled per-VM by setting `host_cpus` + `host_node` on the NUMA
    cells (all-or-nothing: a cell must set both or neither). When enabled the
    module switches `vcpu_placement` from `"auto"` (numad) to `"static"` and
    emits, for every guest vCPU in a cell, a `<vcpupin>` onto that cell's
    `host_cpus`, plus a strict `<memnode>` binding the cell's memory to its
    `host_node`. This keeps each vCPU and the memory it touches on the same
    physical NUMA node, avoiding cross-socket memory latency.

    **The `host_cpus`/`host_node`/`*_cpus` values are host-specific.** CPU
    enumeration is BIOS-dependent — always derive them from the live host
    (`numactl -H`, `lscpu -e`, `/sys/devices/system/cpu/cpu*/topology/thread_siblings_list`).
    Wrong values silently hurt performance instead of helping.

    Example — `-smp 56,sockets=2,cores=14,threads=2`, two NUMA cells each
    pinned to a host node (host CPU lists taken from `numactl -H`):
    ```terraform
    cpu = {
      topology = { sockets = 2, cores = 14, threads = 2 }
      numa = [
        { cpus = "0-27",  memory = "64G", host_cpus = "0-13,28-41",  host_node = 0 },
        { cpus = "28-55", memory = "64G", host_cpus = "14-27,42-55", host_node = 1 },
      ]
      pinning = {
        emulator_cpus  = "0-13,28-41"
        io_thread_cpus = "0-13,28-41"
      }
    }
    ```
  EOT
  default     = null

  validation {
    condition = var.cpu == null || var.cpu.numa == null || alltrue([
      for c in var.cpu.numa : can(regex("^[0-9]+[KMG]$", c.memory))
    ])
    error_message = "NUMA cell memory must be a number followed by K, M, or G (e.g. \"32G\")."
  }

  validation {
    # Pinning is all-or-nothing per cell: host_cpus and host_node must be set
    # together (both pin compute and memory of the cell to the same host node).
    condition = var.cpu == null || var.cpu.numa == null || alltrue([
      for c in var.cpu.numa : (c.host_cpus == null) == (c.host_node == null)
    ])
    error_message = "Each NUMA cell must set both host_cpus and host_node to enable pinning, or neither."
  }
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
