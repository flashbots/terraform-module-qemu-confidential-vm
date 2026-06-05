terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.7"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

module "confidential_vm" {
  source = "../"

  volumes = {
    "buildernet-v2.6.0.qcow2" = {
      pool       = "default"
      source_url = "https://downloads.buildernet.org/buildernet-images/v2.6.0/buildernet-qemu_v2.6.0.qcow2"
    }

    "persistent" = {
      pool       = "vm-storage"
      capacity   = "1G"
      format     = "raw"
    }
  }

  vms = {
    "cvm-01" = {
      vcpu   = 32
      memory = "64G"

      disks = [
        # Boot image: read-only qcow2 from the volume created above
        {
          source     = { volume = { pool = "default", volume = "buildernet-v2.6.0.qcow2" } }
          target     = { dev = "vda" }
          driver     = { type = "qcow2" }
          read_only  = true
          boot_order = 1
        },
        # Persistent data disk: writable block device from the host
        {
          source = { volume = { pool = "vm-storage", volume = "persistent" } }
          target = { dev = "vdb" }
          driver = { type = "raw", cache = "none", io = "native", discard = "unmap" }
          serial = "persistent"
          io_threading = true
        },
      ]

      interfaces = [
        { source = { network = "default" } },
        {
          source = { bridge = "br0" }
          mac    = "52:54:00:aa:bb:cc"
        },
      ]
    }
  }
}

output "vm_details" {
  value       = module.confidential_vm.vm_details
  description = "Details of deployed VMs"
}
