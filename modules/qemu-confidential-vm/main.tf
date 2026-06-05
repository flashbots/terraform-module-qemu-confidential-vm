locals {
  # Parse the memory suffix (K/M/G) into a libvirt amount + IEC unit.
  memory_parts  = regex("^([0-9]+)([KMG])$", var.memory)
  memory_amount = tonumber(local.memory_parts[0])
  memory_unit   = { K = "KiB", M = "MiB", G = "GiB" }[local.memory_parts[1]]

  io_thread_count = 4
  disk_queues     = 8

  disk_io_thread_map = {
    io_thread = [
      for tid in range(1, local.io_thread_count + 1) : {
        id     = tid
        queues = [for qid in range((tid - 1) * 2, tid * 2) : { id = qid }]
      }
    ]
  }

  disks = [for d in var.disks : {
    device    = "disk"
    read_only = d.read_only
    serial    = d.serial

    # Disks opt in to the queue + io_thread fan-out via `io_threading = true`.
    # Typical use: writable block-backed data disks.
    driver = {
      name       = "qemu"
      type       = d.driver.type
      cache      = d.driver.cache
      io         = d.driver.io
      discard    = d.driver.discard
      queues     = d.io_threading == true ? local.disk_queues : null
      io_threads = d.io_threading == true ? local.disk_io_thread_map : null
    }

    source = {
      file   = d.source.file != null ? { file = d.source.file } : null
      block  = d.source.block != null ? { dev = d.source.block } : null
      volume = d.source.volume != null ? { pool = d.source.volume.pool, volume = d.source.volume.volume } : null
    }

    target = {
      dev = d.target.dev
      bus = d.target.bus
    }

    boot = d.boot_order != null ? { order = d.boot_order } : null
  }]

  interfaces = [for i in var.interfaces : {
    model = { type = i.model_type }
    mac   = i.mac != null ? { address = i.mac } : null
    source = {
      network = i.source.network != null ? { network = i.source.network } : null
      bridge  = i.source.bridge != null ? { bridge = i.source.bridge } : null
    }
  }]
}

resource "libvirt_domain" "this" {
  name    = var.vm_name
  type    = "kvm"
  running = true

  # `numad` must be installed on the host for `auto` placement to work
  vcpu           = var.vcpu
  vcpu_placement = "auto"

  io_threads = local.io_thread_count
  io_thread_i_ds = {
    io_threads = [for tid in range(1, local.io_thread_count + 1) : { id = tid }]
  }

  memory              = local.memory_amount
  memory_unit         = local.memory_unit
  current_memory      = local.memory_amount
  current_memory_unit = local.memory_unit

  update  = { shutdown = { timeout = 600 } }
  destroy = { shutdown = { timeout = 600 } }

  memory_backing = {
    memory_source = { type = "anonymous" }
    memory_access = { mode = "private" }
  }

  os = {
    type            = "hvm"
    type_arch       = "x86_64"
    type_machine    = "pc-q35-10.2"
    loader          = var.os_loader
    loader_readonly = "yes"
    loader_type     = "rom"
    loader_format   = "raw"
  }

  features = {
    acpi    = true
    apic    = {}
    vm_port = { state = "off" }
    ioapic  = { driver = "qemu" }
  }

  cpu = {
    mode  = "host-passthrough"
    check = "none"
  }

  clock = {
    offset = "utc"
    timer = [
      { name = "rtc", tick_policy = "catchup" },
      { name = "pit", tick_policy = "delay" },
      { name = "hpet", present = "no" },
    ]
  }

  on_poweroff = "destroy"
  on_reboot   = "restart"
  on_crash    = "destroy"

  pm = {
    suspend_to_mem  = { enabled = "no" }
    suspend_to_disk = { enabled = "no" }
  }

  launch_security = {
    tdx = {
      # 0x10000000
      policy                   = 268435456
      quote_generation_service = {}
    }
  }

  devices = {
    emulator   = "/usr/bin/qemu-system-x86_64"
    disks      = local.disks
    interfaces = local.interfaces

    serials = [
      { target = { type = "isa-serial", port = 0, model = { name = "isa-serial" } } },
    ]

    consoles = [
      { target = { type = "serial", port = 0 } },
    ]

    mem_balloon = { model = "none" }
  }
}
