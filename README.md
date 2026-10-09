# Linux Server Installation & Observability Scripts

A collection of Bash installers and configuration helpers for Linux
server administration, network monitoring, security monitoring, and
phpBB lab deployments.

The repository includes scripts for AlmaLinux/RHEL-compatible systems
and a few tools with their own platform requirements. **Always check
each script's header before running it**; not every script targets the
same OS or deployment scenario.

## Repository contents

  -----------------------------------------------------------------------
  File                                Purpose
  ----------------------------------- -----------------------------------
  `OpenObserve.sh`                    Installs OpenObserve as a systemd
                                      service on AlmaLinux 9.x, using the
                                      Linux musl binary and local
                                      storage.

  `Vector_ClickHouse_Grafana.sh`      Sets up a MikroTik log pipeline
                                      using Vector, ClickHouse, and
                                      Grafana. The script header targets
                                      AlmaLinux 8/9.

  `install-phpbb-almalinux9 (1).sh`   Installs a phpBB forum stack using
                                      Nginx, PHP-FPM, and MariaDB,
                                      intended for AlmaLinux 9.

  `install_arkime_almalinux9.sh`      Installs Arkime with OpenSearch for
                                      network traffic capture and search
                                      on an EL9-compatible system.

  `install_suricata_almalinux9.sh`    Installs Suricata network threat
                                      detection on AlmaLinux 9.

  `install_zeek_almalinux9.sh`        Builds and installs Zeek for
                                      network security monitoring on
                                      AlmaLinux 9.

  `wazuh-install-almalinux9.sh`       Installs a single-node Wazuh stack
                                      (indexer, manager, and dashboard)
                                      on AlmaLinux 9.

  `semaphoreui.sh`                    Installs Semaphore UI with MariaDB
                                      and Ansible on AlmaLinux 9.x.

  `phpbb20.sh`                        Creates multiple phpBB boards for a
                                      local lab, with configurable count
                                      and optional self-signed TLS.

  `phpbbapihook.zip`                  ZIP archive shown in the repository
                                      listing; inspect its contents and
                                      documentation before installing it.
  -----------------------------------------------------------------------

Scripts and archive names may change; inspect the actual files in your
checked-out branch before relying on this table.

## Intended environments

-   **AlmaLinux 9.x:** OpenObserve, phpBB, Arkime, Suricata, Zeek,
    Wazuh, and Semaphore scripts have AlmaLinux 9-oriented names or
    headers.
-   **AlmaLinux 8/9:** The Vector → ClickHouse → Grafana pipeline script
    declares AlmaLinux 8/9.
-   **phpBB multi-board lab:** `phpbb20.sh` is intended for a local
    VM/lab and may create multiple web applications and open multiple
    ports.

These are script-declared targets, not a guarantee that every version of
every dependency will work on every machine. Test in a disposable VM
first.

## Before running any installer

1.  Clone or download the repository.
2.  Inspect the exact script and its variables.
3.  Confirm the OS version, architecture, available disk/RAM, network
    interfaces, and required ports.
4.  Take a VM snapshot or backup.
5.  Change all example/default passwords and secrets.
6.  Confirm firewall rules and which interfaces/services will be
    exposed.
7.  Run only the script you intend to use, with root privileges if
    required by that script.

Example:

``` bash
git clone https://github.com/redhatmurali/install.git
cd install
ls -lah
cat /etc/os-release
uname -m
less OpenObserve.sh
```

Make a script executable only after reviewing it:

``` bash
chmod +x OpenObserve.sh
sudo ./OpenObserve.sh
```

Some scripts can be run with `sudo bash script-name.sh` without setting
the executable bit. Use the usage instructions in each script's header.

## OpenObserve

`OpenObserve.sh` is designed for AlmaLinux 9.x and installs OpenObserve
as a systemd service. The script's default web port is `5080`.

Before running it, edit the script or override its supported environment
variables to set a strong administrator password. Do not use a
sample/default password on a reachable server.

After installation, check service status and logs:

``` bash
sudo systemctl status openobserve --no-pager
sudo journalctl -u openobserve -n 100 --no-pager
curl -i http://127.0.0.1:5080/healthz
```

If you access the UI remotely, restrict access with the host firewall
and network ACLs. Prefer a trusted private network or a properly
configured TLS reverse proxy instead of exposing the UI directly to the
public internet.

Official references: - [OpenObserve
documentation](https://openobserve.ai/docs/) - [OpenObserve
downloads](https://openobserve.ai/downloads/)

## MikroTik logging pipeline: Vector, ClickHouse, and Grafana

`Vector_ClickHouse_Grafana.sh` describes a pipeline for sending MikroTik
logs through Vector into ClickHouse and visualizing/querying them with
Grafana.

Before deployment, review the script for: - Syslog listener port and
source restrictions. - ClickHouse database, table, user, and password. -
Grafana and ClickHouse ports. - Firewalld changes. - Service
configuration and retention/storage requirements.

Do not use credentials embedded in a script for production. Change them
and limit syslog ingestion to trusted router and management networks.

## Network security monitoring

The repository contains separate scripts for:

-   **Arkime:** packet capture and searchable network sessions.
-   **Suricata:** network threat detection and alerting.
-   **Zeek:** network security monitoring and protocol metadata.
-   **Wazuh:** host security monitoring, log analysis, and security
    event management.

These tools have different resource, interface, storage, and firewall
requirements. Configure the correct capture interface and local networks
before running a sensor. Packet capture may collect sensitive data;
obtain authorization and define retention/access controls before
monitoring production traffic.

## phpBB installers

The repository includes a single-forum installer and a multi-board lab
script. Review each script's configured web root, PHP version, database
name/user, ports, and overwrite behavior.

**Warning:** `FORCE=1` or similar overwrite options may delete existing
forum files. Never use them until you have a verified backup and have
checked the exact code path.

For production forums: - Use a supported phpBB release and supported
PHP/database versions. - Use HTTPS with a trusted certificate. - Change
generated administrator/database passwords and keep credential files
private. - Follow phpBB's post-installation security guidance.

Official reference: [phpBB installation
guide](https://www.phpbb.com/community/docs/INSTALL.html).

## Semaphore UI

`semaphoreui.sh` installs Semaphore UI with a local MariaDB database and
Ansible. Review the configured application version, database
credentials, administrator credentials, port, and service settings
before installation.

After installation, verify the service name and port from the script
output or service file; do not assume they are identical across
revisions.

## General troubleshooting

Useful first checks on systemd-based Linux:

``` bash
cat /etc/os-release
uname -m
df -h
free -h
ip -br address
sudo ss -lntup
sudo systemctl --failed
sudo journalctl -p warning -b --no-pager
```

For a specific service, use its actual unit name:

``` bash
sudo systemctl status SERVICE_NAME --no-pager
sudo journalctl -u SERVICE_NAME -n 100 --no-pager
```

Do not paste passwords, API keys, database credentials, or sensitive log
data into public issues.

## Security notes

-   These installers make system-level changes and may install packages,
    create users, change firewall rules, configure services, and write
    credentials.
-   Run them only after reviewing the full script.
-   Never assume a script is safe for an existing production host just
    because it is described as an installer.
-   Replace hard-coded/example credentials and store secrets with
    restrictive permissions.
-   Expose only required ports, and limit administrative interfaces to
    trusted networks.
-   Verify download sources and version compatibility before
    installation.
-   Keep backups and test restore procedures.
-   Scripts and pinned component versions can become outdated; validate
    versions against official project documentation before production
    use.

## Disclaimer

These scripts are provided as administrative examples. Use them at your
own risk and adapt them to your environment. No guarantee is made that a
script will work unchanged on every system. Test in a lab before using
it in production.

## License

No repository-wide license is specified here. Unless a license is added,
do not assume permission to redistribute or reuse the scripts.
Individual components retain their respective upstream licenses.
