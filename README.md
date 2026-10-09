# Linux Installation Scripts

Simple Bash installers for monitoring, security, automation, and phpBB on AlmaLinux.

## Installation

Clone the repository:

```bash
git clone https://github.com/redhatmurali/install.git
cd install
```

## Available Scripts

| Script | Purpose | Install command |
|---|---|---|
| `OpenObserve.sh` | Log management | `sudo bash OpenObserve.sh` |
| `Vector_ClickHouse_Grafana.sh` | MikroTik log monitoring | `sudo bash Vector_ClickHouse_Grafana.sh` |
| `install-phpbb-almalinux9 (1).sh` | Install phpBB forum | `sudo bash 'install-phpbb-almalinux9 (1).sh'` |
| `install_arkime_almalinux9.sh` | Network traffic analysis | `sudo bash install_arkime_almalinux9.sh` |
| `install_suricata_almalinux9.sh` | Network threat detection | `sudo bash install_suricata_almalinux9.sh ens160` |
| `install_zeek_almalinux9.sh` | Network security monitoring | `sudo bash install_zeek_almalinux9.sh` |
| `wazuh-install-almalinux9.sh` | Security monitoring | `sudo bash wazuh-install-almalinux9.sh` |
| `semaphoreui.sh` | Ansible automation | `sudo bash semaphoreui.sh` |
| `phpbb20.sh` | Install multiple phpBB boards | `sudo bash phpbb20.sh` |
| `phpbbapihook.zip` | phpBB API hook files | `unzip -l phpbbapihook.zip` |

## Important

- Most scripts target **AlmaLinux 9**; the Vector logging stack targets AlmaLinux 8/9.
- Review scripts and change default passwords before installation.
- Replace `ens160` with your actual network interface for Suricata.
- Test in a VM before production use.
