variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "lldap_version" {
  type        = string
  default     = "0.6.3"
  description = "LLDAP release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.lldap_version))
    error_message = "lldap_version must be a release number such as \"0.6.3\", without the leading v."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the release tarball for each architecture, x86_64 and aarch64, from the release page. Change these with lldap_version."
  default = {
    x86_64  = "e80b50ef39be61de9f1d75182b1e1fa5d82c672261c7e34fd8ffec5455ed3883"
    aarch64 = "3843e3fde8dff0d2a16c51f62ec2ed318916e722857d20daa61d9175a2b7c020"
  }

  validation {
    condition     = alltrue([for a, c in var.checksums : contains(["x86_64", "aarch64"], a) && can(regex("^[0-9a-f]{64}$", c))])
    error_message = "checksums maps x86_64 or aarch64 to a SHA-256 in lowercase hex."
  }
}

variable "base_dn" {
  type        = string
  description = "Base DN of the directory, such as \"dc=example,dc=com\". Users live under ou=people and groups under ou=groups beneath it."

  validation {
    condition     = can(regex("^[A-Za-z]+=[^,=\"\\\\\n]+(,[A-Za-z]+=[^,=\"\\\\\n]+)*$", var.base_dn))
    error_message = "base_dn must be a DN such as \"dc=example,dc=com\"."
  }
}

variable "ldap_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the LDAP server, and LDAPS if it's on, listens on. The default keeps it to the host itself; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.ldap_address}/${strcontains(var.ldap_address, ":") ? 128 : 32}", 0))
    error_message = "ldap_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "ldap_port" {
  type        = number
  default     = 3890
  description = "Port of the LDAP server."

  validation {
    condition     = var.ldap_port >= 1 && var.ldap_port <= 65535 && floor(var.ldap_port) == var.ldap_port
    error_message = "ldap_port must be a port number from 1 to 65535."
  }
}

variable "http_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the web interface listens on. The default keeps it to the host itself, for a proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.http_address}/${strcontains(var.http_address, ":") ? 128 : 32}", 0))
    error_message = "http_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "http_port" {
  type        = number
  default     = 17170
  description = "Port of the web interface and its API."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535 && floor(var.http_port) == var.http_port
    error_message = "http_port must be a port number from 1 to 65535."
  }
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "Name of the admin user LLDAP creates on its first start. It binds as uid=NAME,ou=people,BASE_DN."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_.@-]{0,63}$", var.admin_username))
    error_message = "admin_username must start with a lowercase letter or digit and use only lowercase letters, digits, _, ., @ and -."
  }
}

variable "admin_email" {
  type        = string
  default     = null
  description = "Email address of the admin user, set when LLDAP creates it."

  validation {
    condition     = var.admin_email == null || can(regex("^[^@\\s\"]+@[^@\\s\"]+$", coalesce(var.admin_email, "-")))
    error_message = "admin_email must be an email address."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the admin user, at least 8 characters. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan. Changing it sets the new one."

  validation {
    condition     = length(var.admin_password) >= 8 && !strcontains(var.admin_password, "\n")
    error_message = "admin_password must be at least 8 characters, on one line."
  }
}

variable "database_url" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "PostgreSQL or MySQL URL to keep LLDAP's data in, such as \"postgres://lldap:PASSWORD@127.0.0.1/lldap\". The database must exist. When null, SQLite in /var/lib/lldap. It never reaches state or the plan."

  validation {
    condition     = var.database_url == null || can(regex("^(postgres|postgresql|mysql)://[^\\s]+$", coalesce(var.database_url, "-")))
    error_message = "database_url must be a postgres:// or mysql:// URL."
  }
}

variable "ldaps_cert_file" {
  type        = string
  default     = null
  description = "Path on the host of a PEM certificate, with its chain, for LDAPS. With ldaps_key_file, turns LDAPS on. The lldap user must be able to read it."

  validation {
    condition     = var.ldaps_cert_file == null || startswith(coalesce(var.ldaps_cert_file, "-"), "/") && !strcontains(coalesce(var.ldaps_cert_file, "-"), "\n")
    error_message = "ldaps_cert_file must be an absolute path."
  }

  validation {
    condition     = (var.ldaps_cert_file == null) == (var.ldaps_key_file == null)
    error_message = "Set ldaps_cert_file and ldaps_key_file together."
  }
}

variable "ldaps_key_file" {
  type        = string
  default     = null
  description = "Path on the host of the PEM private key for ldaps_cert_file. The lldap user must be able to read it."

  validation {
    condition     = var.ldaps_key_file == null || startswith(coalesce(var.ldaps_key_file, "-"), "/") && !strcontains(coalesce(var.ldaps_key_file, "-"), "\n")
    error_message = "ldaps_key_file must be an absolute path."
  }
}

variable "ldaps_port" {
  type        = number
  default     = 6360
  description = "Port of the LDAPS server, when it's on."

  validation {
    condition     = var.ldaps_port >= 1 && var.ldaps_port <= 65535 && floor(var.ldaps_port) == var.ldaps_port
    error_message = "ldaps_port must be a port number from 1 to 65535."
  }
}
