# circuit-lldap

A Conn3x circuit that runs [LLDAP](https://github.com/lldap/lldap), a small LDAP server with a web interface for managing users and groups. It's the one directory your other services sign people in against: Authelia, Nextcloud, Jellyfin, Gitea and Forgejo all speak LDAP, so one account and one password works in every one of them, and you add a person in one place instead of five.

It downloads a pinned LLDAP release from GitHub, checks its SHA-256, and runs it under systemd as an `lldap` user. You set the base DN, the addresses and ports, and the admin password; the circuit writes `/etc/lldap/lldap_config.toml` from them and restarts LLDAP when anything changes. Out of the box LLDAP listens only on `127.0.0.1`, LDAP on port 3890 and the web interface on 17170, and keeps its data in SQLite.

The JWT secret and the key seed are generated on the host by the first apply and never leave it. The admin password and the database URL reach the host as files, so neither is in the plan or state either. Change `admin_password` and the next apply sets it.

## Usage

```hcl
variable "lldap_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "lldap" {
  source = "github.com/conn3xorg/circuit-lldap?ref=v0.1.0"

  hosts                = { auth1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  base_dn        = "dc=example,dc=com"
  admin_password = var.lldap_admin_password
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_lldap_admin_password`. A second `conn3x plan` says `No changes.`

Your services bind as `uid=admin,ou=people,dc=example,dc=com`, the `admin_dn` output, and find users under `ou=people` and groups under `ou=groups`. For anything that only reads the directory, create a user in the web interface and put it in the `lldap_strict_readonly` group, rather than handing out the admin password.

The web interface speaks plain HTTP. Put it behind a TLS proxy on the same host, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) with a reverse proxy to `127.0.0.1:17170`. When your services run on other hosts, set `ldap_address = "0.0.0.0"` and open `ldap_port` to them only, or turn on LDAPS.

To try it on a throwaway container first, see [examples/local](examples/local).

### The admin password

LLDAP on its own reads the admin password once, when it creates the admin on its first start, and ignores it after that. This circuit sets `force_ldap_user_pass_reset = "always"`, which makes LLDAP set the admin's password from the file on every start. A new `admin_password` changes the file, the file change restarts LLDAP, and the new password works as soon as the apply finishes.

The flip side: the password you set in Conn3x is the password. If you change the admin's password in the web interface, the next restart, whether from an apply or a reboot, puts it back.

### LDAPS

Point `ldaps_cert_file` and `ldaps_key_file` at a PEM certificate and key already on the host, and LLDAP also serves LDAPS on `ldaps_port`, 6360 by default, on `ldap_address`. The `lldap` user must be able to read both files. LLDAP reads them when it starts, so restart it after you renew the certificate: `systemctl restart lldap`.

```hcl
module "lldap" {
  # ...
  ldap_address    = "0.0.0.0"
  ldaps_cert_file = "/etc/ssl/lldap/fullchain.pem"
  ldaps_key_file  = "/etc/ssl/lldap/privkey.pem"
}
```

Plain LDAP stays on alongside it. Keep `ldap_port` closed to the network, or `ldap_address` on `127.0.0.1`, if you want only LDAPS reachable. LLDAP binds both to the same address, so for that you need the firewall.

### PostgreSQL or MySQL

SQLite is plenty for a household or a small team. To keep LLDAP's data in PostgreSQL or MySQL instead, pass the URL in `database_url`, which is sensitive and ephemeral like the password:

```hcl
module "lldap" {
  # ...
  database_url = "postgres://lldap:${var.lldap_db_password}@127.0.0.1/lldap"
}
```

The database must exist; [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) or [circuit-mariadb](https://github.com/conn3xorg/circuit-mariadb) can make it. Switching an existing install from SQLite doesn't move its data. LLDAP's docs describe migrating.

## What it does

On each host, in order:

1. Installs `curl`, `tar` and `gzip` if they're missing.
2. Creates the `lldap` system user, with `/var/lib/lldap` as its home, where SQLite keeps `users.db`. Creates `/etc/lldap`, which `lldap` can read but not write.
3. Downloads `ARCH-lldap.tar.gz` from the GitHub release into `/opt/lldap/VERSION` and unpacks it. If the checksum doesn't match `checksums`, the apply fails. The binaries are static, so the same one runs on every distribution.
4. Generates `/etc/lldap/jwt_secret` and `/etc/lldap/key_seed` once: 64 random letters and digits each, owned by root and readable by `lldap`. Later applies leave them alone. The key seed derives the key LLDAP stores passwords with, so keep it with your backups: LLDAP refuses to start on a database whose seed it doesn't have.
5. Writes `admin_password` to `/etc/lldap/admin_password` and the database URL to `/etc/lldap/database_url`, both write-only and mode `0640`, then `lldap_config.toml`, which points at those four files with LLDAP's `*_file` keys and holds no secrets itself. Then `/etc/systemd/system/lldap.service`.
6. Restarts LLDAP when the binary, the config, the unit, the password or the database URL changed, starts it now and at boot, and waits until `/health` answers. On a first start, LLDAP creates its database and the admin here.

The two write-only files reach the host, but the plan and state hold only an HMAC of each. A new password shows in the plan as `content_hmac` changing. See [Secrets](https://docs.conn3x.org/reference/circuits/secrets) for the HMAC key Conn3x uses.

The unit runs LLDAP with `ProtectSystem=strict`, so it can write only to `/var/lib/lldap`.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH. `x86_64` and `aarch64` each get their own build; other architectures fail the plan.

### What it doesn't do

- It doesn't create users or groups beyond the admin. Use the web interface, or LLDAP's GraphQL API.
- It doesn't open a firewall port or set up TLS for the web interface. Use [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for ports and a proxy for HTTPS.
- It doesn't configure SMTP, so LLDAP can't send password reset emails. Reset passwords as the admin.
- It doesn't take backups. Copy `/var/lib/lldap/users.db` with LLDAP stopped, or dump your database, along with `/etc/lldap/key_seed`.
- Changing `admin_username` or `admin_email` after the first apply doesn't rename or update the admin. Pick the name before the first apply.
- Changing `base_dn` after the first apply changes the DNs LLDAP serves, and every service bound to the old ones needs updating.
- Deleting the module leaves LLDAP installed and running, with its data.

### Upgrading

Set `lldap_version` and `checksums` together. Each asset on the [release page](https://github.com/lldap/lldap/releases) shows its SHA-256, or:

```sh
gh release view v0.6.3 -R lldap/lldap --json assets -q '.assets[] | .name + " " + .digest'
```

```hcl
module "lldap" {
  source = "github.com/conn3xorg/circuit-lldap?ref=v0.1.0"

  # ...
  lldap_version = "0.6.3"
  checksums = {
    x86_64  = "e80b50ef39be61de9f1d75182b1e1fa5d82c672261c7e34fd8ffec5455ed3883"
    aarch64 = "3843e3fde8dff0d2a16c51f62ec2ed318916e722857d20daa61d9175a2b7c020"
  }
}
```

The new release unpacks beside the old one, the unit points at it, and LLDAP restarts on the same data, migrating its database on the way up. Back up first and read LLDAP's release notes. The old directory in `/opt/lldap` stays until you remove it.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port Conn3x connects to. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `lldap_version` | string | `"0.6.3"` | LLDAP release to install, without the leading `v`. |
| `checksums` | map(string) | The 0.6.3 checksums | SHA-256 of the release tarball for `x86_64` and `aarch64`. |
| `base_dn` | string | Required | Base DN of the directory, such as `"dc=example,dc=com"`. You don't need to own the domain. |
| `ldap_address` | string | `"127.0.0.1"` | Address LDAP, and LDAPS when it's on, listen on. `"0.0.0.0"` listens on every address. |
| `ldap_port` | number | `3890` | Port of the LDAP server. |
| `http_address` | string | `"127.0.0.1"` | Address the web interface listens on. |
| `http_port` | number | `17170` | Port of the web interface. |
| `admin_username` | string | `"admin"` | Name of the admin user LLDAP creates on its first start. Lowercase. |
| `admin_email` | string | `null` | Email address of the admin, set when LLDAP creates it. |
| `admin_password` | string | Required | Password of the admin, at least 8 characters. Sensitive and ephemeral, and kept out of state. Changing it sets the new one. |
| `database_url` | string | `null` | `postgres://` or `mysql://` URL of an existing database. When null, SQLite in `/var/lib/lldap`. Sensitive and ephemeral, and kept out of state. |
| `ldaps_cert_file` | string | `null` | Path on the host of a PEM certificate for LDAPS. Set with `ldaps_key_file` to turn LDAPS on. |
| `ldaps_key_file` | string | `null` | Path on the host of the certificate's PEM private key. |
| `ldaps_port` | number | `6360` | Port of the LDAPS server. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the configuration file, `/etc/lldap/lldap_config.toml`. |
| `admin_dn` | DN the admin binds as, such as `uid=admin,ou=people,dc=example,dc=com`. |

## Requirements

Requires Conn3x v0.6.7 or later, systemd on each host, and outbound HTTPS to github.com.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. Then `ldapsearch` binds as `uid=admin,ou=people,dc=example,dc=test` and finds the admin under `ou=people`, a wrong password is refused, `/health` answers, and the config holds no secrets. A second apply with a new `admin_password` restarts LLDAP, the plan after it has no changes, the new password binds and the old one is refused. The same checks passed on arm64 containers of all four by hand.

By hand, on Debian 13 in a container, LDAPS with a self-signed certificate answered `ldapsearch` on port 6360 and the plan had no changes.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both with 1 vCPU and 1 GB of memory, the same checks passed, the password change included. On Rocky Linux, LLDAP ran as `unconfined_service_t` and the audit log had no denials. After a reboot both came back, the new password still bound, and the plan had no changes.

PostgreSQL and MySQL through `database_url` haven't been tried.

## License

MPL-2.0. See [LICENSE](LICENSE). LLDAP itself is GPL-3.0.
