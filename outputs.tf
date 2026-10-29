output "config_file" {
  description = "Path of the configuration file the circuit writes on each host."
  value       = "/etc/lldap/lldap_config.toml"
}

output "admin_dn" {
  description = "DN the admin user binds as, for the services that read the directory."
  value       = "uid=${var.admin_username},ou=people,${var.base_dn}"
}
