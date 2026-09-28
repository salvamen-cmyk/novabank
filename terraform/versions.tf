terraform {
  required_version = "= 1.13.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.112.0"
    }
  }
}
