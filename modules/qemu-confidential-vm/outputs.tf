output "domain_id" {
  value       = libvirt_domain.this.id
  description = "Libvirt UUID of the domain"
}

output "domain_name" {
  value       = libvirt_domain.this.name
  description = "Name of the libvirt domain"
}
