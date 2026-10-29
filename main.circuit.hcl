# Facts give each host's architecture, which picks the release tarball.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = contains(keys(var.checksums), self.arch)
      error_message = "Host ${each.key} is ${self.arch}. The circuit has LLDAP builds for ${join(" and ", keys(var.checksums))}."
    }
  }
}

locals {
  home   = "/var/lib/lldap"
  etc    = "/etc/lldap"
  config = "${local.etc}/lldap_config.toml"
  dir    = "/opt/lldap/${var.lldap_version}"

  # LLDAP names its tarballs, and the directory inside each, by these.
  release  = { x86_64 = "amd64", aarch64 = "aarch64" }
  tarball  = { for name, f in data.conn3x_host.facts : name => "${local.release[f.arch]}-lldap.tar.gz" }
  unpacked = { for name, f in data.conn3x_host.facts : name => "${local.dir}/${local.release[f.arch]}-lldap" }

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.http_address, strcontains(var.http_address, ":") ? "[${var.http_address}]" : var.http_address)
  local_url  = "http://${local.local_host}:${var.http_port}"

  # Generated on the host by the first apply. LLDAP reads every *_file key
  # from the file it names, so none of them is in the config, the plan or
  # state.
  secrets = ["jwt_secret", "key_seed"]

  # TOML basic strings take JSON's escapes, so jsonencode quotes safely.
  # Nothing secret is in here: the password, the database URL and the
  # generated secrets each sit in a file of their own beside it.
  # force_ldap_user_pass_reset = "always" sets the admin password from its
  # file on every start, so a new admin_password takes effect on the
  # restart that follows it. LLDAP otherwise reads it only on the first.
  config_toml = { for name, h in var.hosts : name => <<-EOT
    # Written by Conn3x. Changes here are overwritten on the next apply.
    ldap_host = ${jsonencode(var.ldap_address)}
    ldap_port = ${var.ldap_port}
    http_host = ${jsonencode(var.http_address)}
    http_port = ${var.http_port}
    ldap_base_dn = ${jsonencode(var.base_dn)}
    ldap_user_dn = ${jsonencode(var.admin_username)}
    ldap_user_email = ${jsonencode(var.admin_email == null ? "" : var.admin_email)}
    ldap_user_pass_file = "${local.etc}/admin_password"
    force_ldap_user_pass_reset = "always"
    jwt_secret_file = "${local.etc}/jwt_secret"
    key_seed_file = "${local.etc}/key_seed"
    key_file = ""
    database_url_file = "${local.etc}/database_url"
    assets_path = "${local.unpacked[name]}/app"

    [ldaps_options]
    enabled = ${var.ldaps_cert_file != null}
    port = ${var.ldaps_port}
    cert_file = ${jsonencode(var.ldaps_cert_file == null ? "" : var.ldaps_cert_file)}
    key_file = ${jsonencode(var.ldaps_key_file == null ? "" : var.ldaps_key_file)}
  EOT
  }
}

circuit "lldap" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack any of these. curl waits for LLDAP to come up.
  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  step "user" {
    user {
      name   = "lldap"
      system = true
      home   = local.home
      shell  = "/usr/sbin/nologin"
    }
  }

  step "home" {
    directory {
      path  = local.home
      owner = "lldap"
      group = "lldap"
      mode  = "0750"
    }
  }

  # The config and its secrets belong to root, and lldap can only read
  # them.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "lldap"
      mode  = "0750"
    }
  }

  step "release_dir" {
    directory {
      path = local.dir
    }
  }

  step "download" {
    download {
      url    = "https://github.com/lldap/lldap/releases/download/v${var.lldap_version}/${local.tarball[each.key]}"
      sha256 = var.checksums[data.conn3x_host.facts[each.key].arch]
      dest   = "${local.dir}/${local.tarball[each.key]}"
    }
  }

  step "unpack" {
    archive {
      src     = "${local.dir}/${local.tarball[each.key]}"
      dest    = local.dir
      creates = "${local.unpacked[each.key]}/lldap"
    }
  }

  # 64 letters and digits, with no newline, since LLDAP reads the whole
  # file. key_seed derives the key LLDAP stores passwords with, so it must
  # never change once LLDAP has started with it.
  step "secret" {
    for_each = toset(local.secrets)
    command {
      command = "umask 077 && LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 64 > ${local.etc}/${item.value}.new && chgrp lldap ${local.etc}/${item.value}.new && chmod 640 ${local.etc}/${item.value}.new && mv ${local.etc}/${item.value}.new ${local.etc}/${item.value}"
      creates = "${local.etc}/${item.value}"
    }
  }

  # Write-only: the plan and state record only an HMAC of the content.
  step "admin_password" {
    file {
      path       = "${local.etc}/admin_password"
      content_wo = var.admin_password
      owner      = "root"
      group      = "lldap"
      mode       = "0640"
    }
  }

  # A PostgreSQL or MySQL URL carries its password, so it's write-only too.
  step "database_url" {
    file {
      path       = "${local.etc}/database_url"
      content_wo = coalesce(var.database_url, "sqlite://${local.home}/users.db?mode=rwc")
      owner      = "root"
      group      = "lldap"
      mode       = "0640"
    }
  }

  step "config" {
    file {
      path    = local.config
      content = local.config_toml[each.key]
      owner   = "root"
      group   = "lldap"
      mode    = "0640"
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/lldap.service"
      content = <<-EOT
        [Unit]
        Description=LLDAP
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=lldap
        Group=lldap
        WorkingDirectory=${local.home}
        ExecStart=${local.unpacked[each.key]}/lldap run --config-file ${local.config}
        Restart=on-failure
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=true
        ProtectSystem=strict
        ProtectHome=true
        PrivateTmp=true
        ReadWritePaths=${local.home}

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # A step rather than a handler, so the check below waits for the LLDAP
  # that runs the new binary, config and password. A handler would restart
  # it after them. On a first apply it's what starts LLDAP.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart lldap"
      triggers = {
        binary   = conn3x_download.lldap__download[each.key].revision
        config   = conn3x_file.lldap__config[each.key].revision
        unit     = conn3x_file.lldap__unit[each.key].revision
        password = conn3x_file.lldap__admin_password[each.key].revision
        database = conn3x_file.lldap__database_url[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "lldap"
      state   = "started"
      enabled = true
    }
  }

  # unless is checked at plan time, before the restart, so the restart's
  # revision makes the apply check again.
  step "ready" {
    command {
      command  = "for _ in $(seq 60); do curl -sf -o /dev/null ${local.local_url}/health && exit 0; sleep 1; done; exit 1"
      unless   = "curl -sf -o /dev/null ${local.local_url}/health"
      triggers = { restart = conn3x_command.lldap__restart[each.key].revision }
    }
  }
}
