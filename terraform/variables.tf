variable "proxmox_api_url" {
  description = "URL de l'API Proxmox"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "ID du token API Proxmox"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Secret du token API Proxmox"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Nom du nœud Proxmox"
  type        = string
}

variable "network_bridge" {
  description = "Bridge réseau pour les VMs"
  type        = string
}

variable "storage_pool" {
  description = "Nom du stockage Proxmox"
  type        = string
}

variable "ssh_public_key" {
  description = "Clé SSH publique à injecter"
  type        = string
}
