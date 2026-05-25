# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Deploys a Samba 4 Active Directory Domain Controller on OCI plus an Ubuntu Linux NFS/Samba gateway and a Windows client. The Linux instance mounts OCI File Storage Service (FSS) at `/efs` and `/home`, then re-exports `/efs` as a Samba (SMB) share. The Windows instance domain-joins and maps `Z:` to `\\<linux-ip>\efs` at every login.

Two-phase Terraform deploy: `01-directory` provisions networking + DC + FSS security rules, `02-servers` provisions FSS, client instances, and Samba gateway config.

## Commands

```bash
./apply.sh              # validate env, deploy 01-directory then 02-servers
./destroy.sh            # destroy 02-servers first, then 01-directory
./connect.sh [ip]       # create bastion session + SSH tunnel; drops into shell
./get_password.sh <user># print username@domain + password from tfstate
./validate.sh           # print DC IP, bastion ID, script hints
./check_env.sh          # validate oci/terraform/jq in PATH + OCI CLI connectivity
```

## Architecture

```
01-directory/
  networking.tf   — VCN, IGW, NAT, route tables, security lists (incl. NFS+SMB rules)
  ad.tf           — module invocation, user JSON locals, outputs
  accounts.tf     — tls_private_key (RSA 4096), random_password resources
  bastion.tf      — oci_bastion_bastion (STANDARD type, free)
  variables.tf    — compartment_ocid, domain vars

02-servers/
  main.tf         — OCI provider, terraform_remote_state from 01-directory, image data sources
  fss.tf          — FSS file system, mount target (vm-subnet), exports /efs and /home
  linux.tf        — Ubuntu E4.Flex: NFS mounts + Samba gateway; templates mt_ip
  windows.tf      — Windows Server 2022 E4.Flex; templates samba_server for Z: drive
  roles.tf        — empty (no vault; passwords in tfstate)
  security_groups.tf — ssh_nsg (22), smb_nsg (445), rdp_nsg (3389)
  outputs.tf      — linux_public_ip, linux_private_ip, mount_target_ip
```

Module source: `github.com/mamonaco1973/module-oci-mini-ad`

## FSS Architecture

```
vm-subnet (10.0.0.64/26)
  ├── Linux instance  ──NFS──▶  Mount Target (FSS)
  │     └── Samba [efs] share         ├── export /efs
  │                                   └── export /home
  └── Windows instance ──SMB──▶ \\<linux-private-ip>\efs  →  Z:
```

- **Mount target**: OCI resource with a private IP from vm-subnet CIDR.
- **Exports**: `/efs` (shared data, Samba gateway) and `/home` (AD user home dirs on NFS).
- **Samba**: `security = ADS`, uses machine keytab from `realm join` — no separate `net ads join` needed.
- **Z: drive**: `map_drives.bat` placed in All Users startup folder; runs at each login.

## Auth and Variable Wiring

- OCI auth: `~/.oci/config` DEFAULT profile — no credentials in code
- Compartment: set `OCI_COMPARTMENT_ID` env var; scripts translate to `TF_VAR_compartment_ocid`
- Tenancy: extracted from `~/.oci/config` and exported as `TF_VAR_tenancy_ocid`
- Passwords: stored as sensitive outputs in `terraform.tfstate` — retrieve with `./get_password.sh <user>`
- Valid users: `admin`, `jsmith`, `edavis`, `rpatel`, `akumar`, `windows_local_admin`

## Secrets / Vault

OCI Vault was removed due to the `PENDING_DELETION` service-limit issue (see README). Passwords are sensitive outputs in tfstate, injected into instances via `templatefile` at apply time.

## Samba / Winbind Notes

- Packages: `samba`, `winbind`, `libpam-winbind`, `libnss-winbind` (added on top of the SSSD stack).
- SSSD handles Linux PAM/NSS (login, `su`, `ssh`). Winbind handles SMB authentication for Windows clients.
- `nsswitch.conf` includes both: `passwd: files sss winbind`, `group: files sss winbind`.
- `idmap config MCLOUD : backend = sss` — Winbind delegates UID/GID lookup to SSSD.
- Samba NetBIOS name is derived from the hostname (uppercase, dashes stripped, ≤15 chars).
- `realm join` writes `/etc/krb5.keytab`; Samba picks it up via `kerberos method = secrets and keytab`.

## FSS NFS Security Rules (vm-subnet security list)

OCI FSS requires these ingress rules on the mount target's subnet:
- TCP/UDP 111 from 10.0.0.64/26 (portmapper)
- TCP 2048-2050 from 10.0.0.64/26 (NFS lockd/mountd/statd)
- UDP 2048 from 10.0.0.64/26 (NFS)
- TCP 445 from 10.0.0.64/26 (SMB — Windows to Linux Samba gateway)

## Bastion Connect

OCI Bastion is a PORT_FORWARDING session. Correct CLI syntax:

```bash
oci bastion session create \
  --bastion-id "$BASTION_ID" \
  --target-resource-details '{"targetResourcePrivateIpAddress":"...","targetResourcePort":22,"sessionType":"PORT_FORWARDING"}' \
  --key-type PUB \
  --ssh-public-key-file keys/Private_Key.pub \
  --session-ttl-in-seconds 10800
```

Poll `oci bastion session get --session-id` until `lifecycle-state == ACTIVE`, then use the `ssh-metadata.command` template (substituting `<privateKey>` and `<localPort>`).

## Known OCI Quirks

- **cloud-init timing**: OCI fires cloud-init before DNS and NAT routing are stable. `userdata.sh` loops on `nslookup` + `curl` (30s intervals) before running `apt-get`.
- **apt lock race**: OCI fires cloud-init so fast that `apt-daily` grabs the apt lists lock before userdata runs. Fix: retry loop on `apt-get update` with `pkill -9 -f apt` on each failure.
- **IPv6 / NAT gateway**: OCI NAT gateway silently drops IPv6. Fix: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` plus `Acquire::ForceIPv4 "true"` for apt.
- **pip3 / urllib3 conflict**: Ubuntu 24.04 ships urllib3 without a RECORD file. Fix: install OCI CLI into a venv at `/opt/oci-venv`.
- **SSSD offline at boot**: Fixed with `offline_timeout = 60` in sssd.conf.
- **time_sleep**: DC bootstraps in ~6 minutes. `time_sleep` in the module is 600s before DHCP options update.
- **ARM64 apt sources**: DC instance is A1.Flex (ARM64) so Ubuntu uses `ports.ubuntu.com`.
- **Bastion RSA only**: OCI Bastion rejects ECDSA keys. RSA 4096 required.
- **Bastion ACTIVE lag**: OCI reports session `ACTIVE` before the key is propagated. `sleep 5` after ACTIVE before opening the tunnel.
- **FSS mount before domain join**: NFS mounts must happen after `nfs-common` is installed but before `realm join`, so mkhomedir writes AD user home dirs to FSS (`/home` export).

## Keys

RSA 4096 key pair generated by `tls_private_key` in `01-directory/accounts.tf`. Written to `01-directory/keys/Private_Key` (0600) and `01-directory/keys/Private_Key.pub`. Gitignored — never committed.

## SSH to Linux Client

```bash
ssh -i 01-directory/keys/Private_Key -o StrictHostKeyChecking=no ubuntu@<linux_public_ip>
```

No bastion needed — Linux client is in a public subnet.

## Windows RDP Fallback

If the domain join fails, RDP as `windows_local_admin` — password retrieved with `./get_password.sh windows_local_admin`.
