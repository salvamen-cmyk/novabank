locals {
  nodes = {
    "k8s-master"   = { vmid = 501, ip = "192.168.100.30", cores = 4, memory = 8192, disk = 80 }
    "k8s-worker-1" = { vmid = 502, ip = "192.168.100.31", cores = 4, memory = 8192, disk = 80 }
    "k8s-worker-2" = { vmid = 503, ip = "192.168.100.32", cores = 4, memory = 8192, disk = 80 }
    "minio-backup" = { vmid = 504, ip = "192.168.100.33", cores = 2, memory = 4096, disk = 100 }
  }
}

resource "proxmox_virtual_environment_vm" "k8s_nodes" {
  for_each = local.nodes

  agent {
    enabled = true

    wait_for_ip {
      disabled = true
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {
    device = "socket"
  }



  name          = each.key
  node_name     = var.proxmox_node
  vm_id         = each.value.vmid
  scsi_hardware = "virtio-scsi-single"

  clone {
    vm_id = 801
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = each.value.disk
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.storage_pool
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.100.1"
      }
    }

    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  started         = true
  stop_on_destroy = true

  lifecycle {
    ignore_changes = [
      clone
    ]
  }
}

output "ansible_inventory_content" {
  value = <<-EOT
  [k8s_master]
  k8s-master ansible_host=192.168.100.30

  [k8s_workers]
  k8s-worker-1 ansible_host=192.168.100.31
  k8s-worker-2 ansible_host=192.168.100.32

  [minio_server]
  minio-backup ansible_host=192.168.100.33

  [k8s_cluster:children]
  k8s_master
  k8s_workers

  [all:vars]
  ansible_user=ubuntu
  ansible_ssh_private_key_file=~/.ssh/id_rsa
  ansible_python_interpreter=/usr/bin/python3
  ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  EOT
}
