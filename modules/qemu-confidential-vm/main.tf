locals {
  # Parse the memory suffix (K/M/G) into a libvirt amount + IEC unit.
  size_unit_lookup = { K = "KiB", M = "MiB", G = "GiB" }
  memory_parts     = regex("^([0-9]+)([KMG])$", var.memory)
  memory_amount    = tonumber(local.memory_parts[0])
  memory_unit      = local.size_unit_lookup[local.memory_parts[1]]

  # libvirt always normalises NUMA cell memory to KiB on readback (e.g. "64G"
  # becomes 67108864 KiB). Emit KiB directly so the planned state matches what
  # libvirt reports back and the domain doesn't perpetually drift.
  size_kib_lookup = { K = 1, M = 1024, G = 1048576 }

  # NUMA cells: parse per-cell memory suffix, auto-assign nodeid from index.
  # try() because TF's boolean operators do not short-circuit: evaluating
  # `var.cpu.numa` crashes when var.cpu itself is null.
  numa_cells = try(var.cpu.numa, null) != null ? [
    for i, c in var.cpu.numa : {
      id     = i
      cpus   = c.cpus
      memory = tonumber(regex("^([0-9]+)([KMG])$", c.memory)[0]) * local.size_kib_lookup[regex("^([0-9]+)([KMG])$", c.memory)[1]]
      unit   = "KiB"
    }
  ] : null

  io_thread_count = 4
  disk_queues     = 8

  # CPU pinning is opted into per NUMA cell via host_cpus/host_node. The
  # variable validation guarantees both are set together, so testing host_cpus
  # on any cell is enough to detect the intent.
  cpu_pinning_enabled = (
    length([for c in coalesce(try(var.cpu.numa, null), []) : c if c.host_cpus != null]) > 0
  )

  # One <vcpupin> per guest vCPU, pinning every vCPU in a cell to that cell's
  # host_cpus. Guest cpusets are expanded ("0-27" / "0,2-7" -> [0,1,...]) so we
  # can emit an entry per vCPU index, which is what libvirt's cputune expects.
  vcpu_pins = local.cpu_pinning_enabled ? flatten([
    for c in var.cpu.numa : [
      for v in flatten([
        for part in split(",", c.cpus) :
        strcontains(part, "-") ?
        range(tonumber(split("-", part)[0]), tonumber(split("-", part)[1]) + 1) :
        [tonumber(part)]
      ]) : { vcpu = v, cpu_set = c.host_cpus }
    ] if c.host_cpus != null
  ]) : null

  # Strict per-cell memory binding: guest cell `i` -> host NUMA node host_node.
  numa_mem_nodes = local.cpu_pinning_enabled ? [
    for i, c in var.cpu.numa : {
      cell_id = i
      mode    = "strict"
      nodeset = tostring(c.host_node)
    } if c.host_node != null
  ] : null

  cpu_tune = local.cpu_pinning_enabled ? {
    vcpu_pin = local.vcpu_pins
    emulator_pin = try(var.cpu.pinning.emulator_cpus, null) != null ? {
      cpu_set = var.cpu.pinning.emulator_cpus
    } : null
    io_thread_pin = try(var.cpu.pinning.io_thread_cpus, null) != null ? [
      for tid in range(1, local.io_thread_count + 1) :
      { io_thread = tid, cpu_set = var.cpu.pinning.io_thread_cpus }
    ] : null
  } : null

  # libvirt canonicalises <numatune> nodesets to a sorted, range-collapsed form
  # ("0,1" -> "0-1", "0,2" -> "0,2"), and omits `placement` (it defaults to
  # `static` whenever a nodeset is given under static vCPU placement). Compute
  # that exact form here so the global numatune policy doesn't drift on readback.
  pinned_host_nodes = local.cpu_pinning_enabled ? distinct([
    for c in var.cpu.numa : c.host_node if c.host_node != null
  ]) : []
  host_node_min = length(local.pinned_host_nodes) > 0 ? min(local.pinned_host_nodes...) : 0
  host_node_max = length(local.pinned_host_nodes) > 0 ? max(local.pinned_host_nodes...) : 0
  # Ascending, de-duplicated node ids (range() emits them in order).
  sorted_host_nodes = [
    for n in range(local.host_node_min, local.host_node_max + 1) : n
    if contains(local.pinned_host_nodes, n)
  ]
  # A node opens a new range when its immediate predecessor is absent.
  host_node_run_starts = [
    for n in local.sorted_host_nodes : n
    if !contains(local.pinned_host_nodes, n - 1)
  ]
  numatune_nodeset = join(",", [
    for s in local.host_node_run_starts :
    (min([for n in range(s, local.host_node_max + 2) : n if !contains(local.pinned_host_nodes, n)]...) - 1) == s
    ? tostring(s)
    : "${s}-${min([for n in range(s, local.host_node_max + 2) : n if !contains(local.pinned_host_nodes, n)]...) - 1}"
  ])

  numa_tune = local.cpu_pinning_enabled ? {
    # Global policy spanning every pinned host node, plus the precise per-cell
    # bindings. Setting both keeps libvirt happy across versions.
    memory = {
      mode    = "strict"
      nodeset = local.numatune_nodeset
    }
    mem_nodes = local.numa_mem_nodes
  } : null

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
  name      = var.vm_name
  type      = "kvm"
  running   = true
  autostart = var.autostart

  # Always static: `auto` would require numad on the host, and unpinned
  # domains are perfectly fine with libvirt's default static placement.
  vcpu           = var.vcpu
  vcpu_placement = "static"

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
    mode     = "host-passthrough"
    check    = "none"
    topology = try(var.cpu.topology, null)
    numa     = local.numa_cells != null && length(coalesce(local.numa_cells, [])) > 0 ? { cell = local.numa_cells } : null
  }

  # vCPU/IOThread/emulator pinning and strict per-cell memory binding. Both are
  # null (omitted) unless pinning is opted into via the NUMA cells' host_cpus.
  cpu_tune  = local.cpu_tune
  numa_tune = local.numa_tune

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
