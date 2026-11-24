terraform {
  required_version = ">= 1.4"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = ">= 0.9.8"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}
