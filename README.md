Terraform module to provision Intel TDX-based confidential virtual machines on a bare-metal libvirt/QEMU/KVM host.

The module focuses on deploying VMs for [BuilderNet](https://buildernet.org/) and pins down the parts of the libvirt domain XML that need to be exactly right for TDX, while leaving everything that varies between VMs (CPU/memory sizing, disks, NICs) configurable.

## Overview

The module handles the following infrastructure components:

- Creates [`libvirt_volume`](https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs/resources/volume) resources in pre-existing storage pools (optional);
- Creates [`libvirt_domain`](https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs/resources/domain) resources with Intel TDX `launch_security`, OVMF firmware, `host-passthrough` CPU, and the small constellation of `features`/`clock`/`pm`/`memory_backing`/device settings TDX needs;
- Lets each VM declare its disks (file, host block device, or libvirt volume reference) and NICs (libvirt network or host bridge).

Storage pools and libvirt networks are **not** managed by this module — they must already exist on the host. The volumes created by this module live inside one of those pre-existing pools.

## Prerequisites

Before using this module, the host must:

- Be configured for Intel TDX (kernel, BIOS, `kvm_intel` module options);
- Have a TDX-aware OVMF firmware available at the path passed in `os_loader` (default `/usr/share/ovmf/OVMF.inteltdx.fd`);
- Have the `numad` package installed and running — required for `vcpu_placement = "auto"`, which the module uses unless CPU pinning is configured (see [CPU topology and NUMA](#cpu-topology-and-numa));
- Have at least one libvirt storage pool and one libvirt network (or host bridge) defined.

## Hardcoded for TDX

The following parts of the domain XML are fixed by the module and not user-configurable:

- `update` / `destroy` timeouts (10 min each)
- `vcpu_placement` (`"auto"`, requires `numad`; switches to `"static"` automatically when CPU pinning is configured)
- `memory_backing` (anonymous private mapping)
- Most of the `os` block (`type`, `type_arch`, `type_machine`, `loader_*`); only `loader` is exposed
- `features` (acpi, apic, vm_port off, ioapic via qemu)
- `cpu` (`host-passthrough`)
- `clock` (utc with rtc/pit/hpet timers)
- `on_poweroff` / `on_reboot` / `on_crash`
- `pm` (suspend disabled)
- `launch_security.tdx` (policy `0x10000000`, default QGS)
- `devices.emulator`, `devices.serials`, `devices.consoles`, `devices.mem_balloon`

If you need to tweak any of these, fork the module — they're tuned together and changing one in isolation tends to break TDX boot.

## Usage

Refer to the [examples](./examples/) directory for detailed configuration examples.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.4 |
| <a name="requirement_external"></a> [external](#requirement\_external) | >= 2.3 |
| <a name="requirement_libvirt"></a> [libvirt](#requirement\_libvirt) | >= 0.9.8 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_r2_account_id"></a> [r2\_account\_id](#input\_r2\_account\_id) | Cloudflare account ID of the R2 buckets in `s3://<bucket>/<key>` volume<br/>sources. Required when any volume uses such a source.<br/><br/>The credentials come from the `CLOUDFLARE_API_TOKEN` environment variable<br/>(the same one the Cloudflare provider reads); the token needs read access<br/>to the bucket. On every plan the module signs a short-lived GET URL for<br/>each `s3://` volume with `scripts/r2-presign.py` (needs `python3`), which<br/>calls the Cloudflare API once to look up the token ID. The token itself is<br/>not stored in the configuration or the state; the signed URL (valid for<br/>24 hours) is. | `string` | `null` | no |
| <a name="input_vms"></a> [vms](#input\_vms) | Map of VM configurations keyed by VM name. See the inner<br/>`modules/qemu-confidential-vm` module variables for the meaning of each<br/>field.<br/><br/>Example:<pre>terraform<br/>vms = {<br/>  "cvm-01" = {<br/>    vcpu   = 32<br/>    memory = "64G"<br/><br/>    disks = [<br/>      {<br/>        source     = { volume = { pool = "default", volume = "buildernet-image.qcow2" } }<br/>        target     = { dev = "vdc" }<br/>        driver     = { type = "qcow2" }<br/>        read_only  = true<br/>        boot_order = 1<br/>      },<br/>      {<br/>        source = { block = "/dev/vg0/cvm-01" }<br/>        target = { dev = "vda" }<br/>        driver = { type = "raw", cache = "none", io = "native", discard = "unmap" }<br/>        serial = "persistent"<br/>      },<br/>    ]<br/><br/>    interfaces = [<br/>      { source = { network = "default" } },<br/>      { source = { bridge = "br0" }, mac = "52:54:00:aa:bb:cc" },<br/>    ]<br/>  }<br/>}</pre> | <pre>map(object({<br/>    vcpu      = number<br/>    memory    = string<br/>    os_loader = optional(string, "/usr/share/ovmf/OVMF.inteltdx.fd")<br/>    autostart = optional(bool, true)<br/><br/>    cpu = optional(object({<br/>      topology = optional(object({<br/>        sockets = number<br/>        cores   = number<br/>        threads = number<br/>        dies    = optional(number)<br/>      }))<br/>      numa = optional(list(object({<br/>        cpus      = string<br/>        memory    = string<br/>        host_cpus = optional(string)<br/>        host_node = optional(number)<br/>        distances = optional(list(number))<br/>      })))<br/>      pinning = optional(object({<br/>        emulator_cpus  = optional(string)<br/>        io_thread_cpus = optional(string)<br/>      }))<br/>    }))<br/><br/>    disks = list(object({<br/>      source = object({<br/>        file  = optional(string)<br/>        block = optional(string)<br/>        volume = optional(object({<br/>          pool   = string<br/>          volume = string<br/>        }))<br/>      })<br/>      target = object({<br/>        dev = string<br/>        bus = optional(string, "virtio")<br/>      })<br/>      driver = optional(object({<br/>        type    = optional(string, "raw")<br/>        cache   = optional(string)<br/>        io      = optional(string)<br/>        discard = optional(string)<br/>      }), {})<br/>      read_only    = optional(bool, false)<br/>      serial       = optional(string)<br/>      boot_order   = optional(number)<br/>      io_threading = optional(bool)<br/>    }))<br/><br/>    interfaces = list(object({<br/>      source = object({<br/>        network = optional(string)<br/>        bridge  = optional(string)<br/>      })<br/>      mac        = optional(string)<br/>      model_type = optional(string, "virtio")<br/>      driver = optional(object({<br/>        name          = optional(string)<br/>        queues        = optional(number)<br/>        rx_queue_size = optional(number)<br/>      }))<br/>    }))<br/>  }))</pre> | n/a | yes |
| <a name="input_volumes"></a> [volumes](#input\_volumes) | Map of libvirt storage volumes to create in pre-existing pools, keyed by<br/>volume name. The pool itself is not managed by this module and must<br/>already exist on the host.<br/><br/>Per-volume fields:<br/>- `pool`: name of the existing libvirt storage pool to create the volume in<br/>- `capacity`: volume capacity as a number (optionally fractional) with a<br/>  unit suffix, where `K` = KiB, `M` = MiB, `G` = GiB, `T` = TiB<br/>  (binary/IEC units). For example `"100G"` is 100 GiB, `"2.2T"` is<br/>  2.2 TiB. Resolved to an integer byte count internally. Required unless<br/>  `source_url` is set (in which case capacity is derived from the source).<br/>- `allocation`: initial allocation, same format as `capacity`. Set it<br/>  equal to `capacity` for volumes in logical (LVM) pools: when the<br/>  requested allocation is lower than capacity, libvirt creates the LV as<br/>  a sparse snapshot with a copy-on-write area of only the allocated<br/>  size. The snapshot is irreversibly invalidated the moment writes<br/>  exceed that area, after which ALL I/O to the volume fails with EIO.<br/>  File-backed pools grow on demand and can safely omit it.<br/>- `format`: volume format (default `qcow2`)<br/>- `source_url`: URL to populate the volume from. Accepts `http(s)://...`,<br/>  `s3://<bucket>/<key>` (private Cloudflare R2 bucket, see<br/>  `r2_account_id`), `file://...`, or a plain local file path. When set,<br/>  the libvirt provider uploads the file into the pool at apply time.<br/>  Changing it replaces the volume.<br/>- `backing_store`: optional copy-on-write backing for the volume.<br/>  `path` is the path of the backing file on the host; `format` defaults<br/>  to `qcow2`.<br/>- `permissions`: optional `{ owner, group, mode }` for the resulting<br/>  file on the host. Useful when the upload-time uid (the user running<br/>  `terraform apply`) wouldn't otherwise be readable by the qemu user.<br/>  For example `{ owner = "root", group = "root", mode = "0644" }`<br/>  makes the volume world-readable regardless of who applied.<br/><br/>Example:<pre>terraform<br/>volumes = {<br/>  "buildernet-image.qcow2" = {<br/>    pool       = "default"<br/>    source_url = "https://downloads.buildernet.org/buildernet-images/v2.6.0/buildernet-qemu_v2.6.0.qcow2"<br/>    permissions = {<br/>      owner = "root"<br/>      group = "root"<br/>      mode  = "0644"<br/>    }<br/>  }<br/>  "persistent" = {<br/>    pool       = "vm-storage"<br/>    capacity   = "100G"<br/>    allocation = "100G"<br/>  }<br/>}</pre> | <pre>map(object({<br/>    pool       = string<br/>    capacity   = optional(string)<br/>    allocation = optional(string)<br/>    format     = optional(string, "qcow2")<br/>    source_url = optional(string)<br/>    backing_store = optional(object({<br/>      path   = string<br/>      format = optional(string, "qcow2")<br/>    }))<br/>    permissions = optional(object({<br/>      owner = optional(string)<br/>      group = optional(string)<br/>      mode  = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_vm_details"></a> [vm\_details](#output\_vm\_details) | Details of created VMs |
| <a name="output_volumes"></a> [volumes](#output\_volumes) | Map of libvirt volumes created by this module |

## Private image sources (`s3://`)

A volume's `source_url` can be `s3://<bucket>/<key>` for an object in a private Cloudflare R2 bucket. Set `r2_account_id` in the module call and export a Cloudflare API token with read access to the bucket before running terraform, as for the Cloudflare provider:

```bash
export CLOUDFLARE_API_TOKEN=...
terraform plan
```

```terraform
module "cvm" {
  # ...
  r2_account_id = "<cloudflare-account-id>"

  volumes = {
    "image-v1.2.3.qcow2" = {
      pool       = "pool"
      source_url = "s3://<bucket>/images/v1.2.3/image-v1.2.3.qcow2"
    }
  }
}
```

How it works:
- On every plan, `scripts/r2-presign.py` (Python standard library only) makes a GET URL signed for 24 hours. R2 S3 credentials are derived from the token: the access key ID is the token ID, looked up with one Cloudflare API call, and the secret is the SHA-256 hash of the token.
- The libvirt provider downloads that URL from the machine running terraform when it creates the volume. Apply a saved plan within 24 hours.
- The volume is replaced when `source_url` changes, not when the signed URL changes.
- The token is not stored in the configuration or the state. The signed URL is stored in the state and works until it expires.
- Every plan of a configuration with `s3://` volumes needs `CLOUDFLARE_API_TOKEN`, even when nothing changes.
- Upgrading from an earlier version of this module adds one `terraform_data.volume_source` per volume to the first plan and changes nothing else (existing volumes are not replaced). This version needs Terraform >= 1.4 and the `hashicorp/external` provider (`terraform init -upgrade`).

## Size suffixes

A VM's `memory` and a volume's `capacity` are strings: a number with a unit suffix in binary/IEC units. `memory` accepts integer values with `K` = KiB, `M` = MiB, `G` = GiB; `capacity` additionally accepts `T` = TiB and fractional values (e.g. `"2.2T"`), resolved to an integer byte count. For example `"64G"` is 64 GiB, `"512M"` is 512 MiB, `"2.2T"` is 2.2 TiB. The suffix is mandatory (for `capacity`, the field may instead be omitted when `source_url` derives the size).

## Disks

Each entry in a VM's `disks` list sets exactly one of `source.file`, `source.block`, or `source.volume`:

| Source | Backing | Typical use |
|--------|---------|-------------|
| `source.file` | path to a file on the host (qcow2, raw, etc.) | Direct file-backed image |
| `source.block` | host block device path (e.g. `/dev/vg0/...`) | LVM-backed writable data disk |
| `source.volume` | `{ pool, volume }` reference to a libvirt volume | Image managed by this or another module |

For write-enabled block disks the typical pattern is to also set `serial` so the guest sees a stable identifier under `/dev/disk/by-id/...`, plus `driver = { type = "raw", cache = "none", io = "native", discard = "unmap" }` for sensible performance defaults, plus `io_threading = true` to opt in to the hardcoded multi-queue layout (8 virtqueues fanned out across 4 io_threads at the domain level).

For the boot image, set `read_only = true` and `boot_order = 1` (lower wins).

## Interfaces

Each entry in a VM's `interfaces` list sets exactly one of `source.network` (a libvirt network) or `source.bridge` (a host Linux bridge). The MAC address is left unset by default, so libvirt picks one; supply `mac` if you need it stable across recreates or pre-allocated upstream.

By default the virtio NIC is single-queue: the guest handles every inbound packet's interrupt and softirq on one vCPU, and the host serves the device from one vhost worker. For busy guests, set `driver` to spread that work:

```terraform
interfaces = [
  {
    source = { bridge = "br0" }
    driver = { name = "vhost", queues = 8, rx_queue_size = 1024 }
  },
]
```

- `queues`: RX/TX queue pairs. The guest's `virtio_net` enables all of them at boot and spreads their interrupts across vCPUs; the host gets one vhost worker per pair, placed with the emulator threads (`cpu.pinning.emulator_cpus` when pinned).
- `rx_queue_size`: RX ring depth (256, 512 or 1024; QEMU default 256). A deeper ring absorbs inbound bursts before the host tap starts dropping. The TX ring stays at 256 because QEMU only honours larger TX rings for vhost-user.
- `name = "vhost"` makes the in-kernel backend mandatory instead of silently falling back to userspace.

Like any domain change, adding or changing `driver` on a running VM makes the provider shut the guest down gracefully (`update.shutdown`, 600 s), redefine the domain and start it again.

## CPU topology and NUMA

`cpu.mode = "host-passthrough"` and `cpu.check = "none"` are required for TDX and always set by the module. Beyond that, an optional `cpu` field on each VM exposes the SMP topology and NUMA layout:

```terraform
cpu = {
  topology = { sockets = 2, cores = 16, threads = 2 }
  numa = [
    { cpus = "0-31",  memory = "32G" },
    { cpus = "32-63", memory = "32G" },
  ]
}
```

This is equivalent to the QEMU flags:

```
-smp 64,sockets=2,cores=16,threads=2
-numa node,nodeid=0,cpus=0-31,memdev=mem0
-numa node,nodeid=1,cpus=32-63,memdev=mem1
```

Notes:

- `topology.sockets * (dies | 1) * cores * threads` must equal `vcpu`; the module does not cross-check this (Terraform validation can't reference other variables), libvirt will error at start time if they disagree.
- `numa` is an ordered list; each cell's `nodeid` is auto-assigned from its index (0, 1, 2, ...). Memory uses the same K/M/G suffix as `var.memory`.
- libvirt auto-generates the per-cell `memdev=memN` memory backends from the NUMA cells; you don't (and can't) set them directly.

### CPU pinning

By default `vcpu_placement = "auto"` lets `numad` float the vCPUs across the host. For latency-sensitive guests that span more than one host NUMA node, that floating causes cross-socket memory access — a vCPU ends up far from the memory it touches, and memory-bound work (e.g. EVM simulation) stalls. To avoid it, pin each guest NUMA cell to a host NUMA node by adding `host_cpus` + `host_node` to the cell, and (optionally) place the non-vCPU threads with `pinning`:

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

When any cell sets `host_cpus`/`host_node`, the module:

- switches `vcpu_placement` to `"static"` (no `numad` needed);
- emits a `<vcpupin>` for every guest vCPU in the cell onto that cell's `host_cpus`;
- emits a strict `<memnode>` binding the cell's memory to `host_node`, plus a global `<memory mode="strict">` spanning all pinned nodes;
- pins the emulator thread and the IOThreads onto `emulator_cpus` / `io_thread_cpus` if given.

Notes:

- Pinning is all-or-nothing per cell: a cell must set **both** `host_cpus` and `host_node`, or neither.
- `host_cpus`, `host_node`, `emulator_cpus`, and `io_thread_cpus` are **host-specific** — CPU enumeration is BIOS-dependent. Derive them from the live host with `numactl -H`, `lscpu -e`, and `/sys/devices/system/cpu/cpu*/topology/thread_siblings_list`. Wrong values silently hurt performance.
- Pin a cell's vCPUs only to host CPUs that actually belong to `host_node` (copy the per-node list straight from `numactl -H`), otherwise the strict memory binding and the vCPU placement disagree and you reintroduce cross-NUMA access.

### NUMA distances

Without explicit distances QEMU builds no ACPI SLIT table, and the guest kernel falls back to a flat `20` between every pair of nodes. That hides the real cost structure from the guest scheduler and from NUMA-aware applications: on a Sub-NUMA Clustering (SNC) host the two nodes of the same socket are much closer (e.g. `12`) than nodes on the other socket (e.g. `21`), but the guest sees them all as equally remote.

Give each cell its row of the distance matrix with `distances`, one value per cell in cell order. For pinned cells, copy the values from the host's `numactl -H` for the corresponding `host_node`s:

```terraform
# Host (2 sockets, SNC2):   node   0   1   2   3
#                              0: 10  12  21  21
#                              1: 12  10  21  21
#                              2: 21  21  10  12
#                              3: 21  21  12  10
numa = [
  { cpus = "0-27",   memory = "224G", host_cpus = "0-13,64-77",    host_node = 0, distances = [10, 12, 21, 21] },
  { cpus = "28-55",  memory = "224G", host_cpus = "16-29,80-93",   host_node = 1, distances = [12, 10, 21, 21] },
  { cpus = "56-83",  memory = "224G", host_cpus = "32-45,96-109",  host_node = 2, distances = [21, 21, 10, 12] },
  { cpus = "84-111", memory = "224G", host_cpus = "48-61,112-125", host_node = 3, distances = [21, 21, 12, 10] },
]
```

This emits `<distances><sibling id='N' value='D'/>...</distances>` per cell, which libvirt turns into `-numa dist,src=I,dst=N,val=D`. Check the result in the guest with `cat /sys/devices/system/node/node*/distance`.

Notes:

- All-or-nothing: set `distances` on every cell or none. Each row needs exactly one entry per cell, `10` for the cell itself and an integer 11-255 for every other cell.
- The SLIT is an ACPI table, so adding or changing distances changes the guest's RTMR[0] measurement.

## Note for contributors

Make sure to use [terraform-docs](https://github.com/terraform-docs/terraform-docs) to generate the configuration parameters of the module (provider requirements, input variables, outputs) should you update them.

```
terraform-docs markdown --hide modules,resources,providers ./
```
