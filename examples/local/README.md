# Local example

Applies circuit-lldap to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` LLDAP listens on `127.0.0.1` inside the container, LDAP on 3890 and the web interface on 17170. To bind as the admin and list the users, install the OpenLDAP clients in the container and search:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  "dnf -qy install openldap-clients && ldapsearch -x -H ldap://127.0.0.1:3890 \
   -D uid=admin,ou=people,dc=example,dc=test -w '$TF_VAR_admin_password' -b ou=people,dc=example,dc=test"
```

To use the web interface from your browser, forward the port over SSH, open `http://localhost:17170` and sign in as `admin`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 17170:127.0.0.1:17170 -N root@127.0.0.1
```

Set a new `TF_VAR_admin_password` and apply again to change the admin's password.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
