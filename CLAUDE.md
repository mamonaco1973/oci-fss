# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Deploys a Samba 4 Active Directory Domain Controller on OCI plus Windows and Linux client instances that domain-join at boot. Two-phase Terraform deploy: `01-directory` provisions networking + DC, `02-servers` provisions the client instances.

## Commands

```bash
./apply.sh              # validate env, deploy 01-directory then 02-servers
./destroy.sh            # destroy 02-servers first, then 01-directory
./connect.sh [ip]       # create bastion session + SSH tunnel; drops into shell
./get_password.sh <user># print username@domain + password from vault
./validate.sh           # print DC IP, bastion ID, script hints
./check_env.sh          # validate oci/terraform/jq in PATH + OCI CLI connectivity
```

## Architecture

```
01-directory/
  networking.tf   — VCN, IGW, NAT, route tables, security lists, 3 subnets
  ad.tf           — module invocation, user JSON locals, outputs
  accounts.tf     — tls_private_key (RSA 4096), random_password resources
  bastion.tf      — oci_bastion_bastion (STANDARD type, free)
  vault.tf        — OCI KMS vault + secrets for all AD accounts + windows_local_admin
  variables.tf    — compartment_ocid, domain vars

02-servers/
  main.tf         — OCI provider, terraform_remote_state from 01-directory, image data sources
  linux.tf        — Ubuntu E4.Flex client, public IP, domain join via userdata
  windows.tf      — Windows Server 2022 E4.Flex, RDP, cloudbase-init userdata
  roles.tf        — dynamic group + IAM policy for Linux instance principal vault access
  security_groups.tf — ssh_nsg (22), rdp_nsg (3389)
  outputs.tf      — linux_public_ip
```

Module source: `github.com/mamonaco1973/module-oci-mini-ad`

## Auth and Variable Wiring

- OCI auth: `~/.oci/config` DEFAULT profile — no credentials in code
- Compartment: set `OCI_COMPARTMENT_ID` env var; scripts translate to `TF_VAR_compartment_ocid`
- Tenancy: extracted from `~/.oci/config` and exported as `TF_VAR_tenancy_ocid` — required for dynamic group creation (dynamic groups must live in root tenancy)
- Falls back to tenancy OCID from `~/.oci/config` if `OCI_COMPARTMENT_ID` is unset
- Passwords: stored in OCI Vault as JSON `{"username": "...", "password": "..."}` — retrieve with `./get_password.sh <user>`
- Valid users: `admin`, `jsmith`, `edavis`, `rpatel`, `akumar`, `windows_local_admin`

## Secrets / Vault

All credentials are stored in the OCI Vault in `01-directory/vault.tf`. Secret naming convention: `{user}_ad_credentials` and `windows_local_admin_credentials`. Each secret is BASE64-encoded JSON with `username` and `password` fields.

The Linux client fetches its AD join credential at runtime using instance principal auth:
- `roles.tf` creates a dynamic group (compartment-scoped) + IAM policy
- OCI CLI installed into `/opt/oci-venv` (venv avoids Debian urllib3 conflict); symlinked to `/usr/local/bin/oci`
- **Dynamic group must use compartment-scoped rule** (`instance.compartment.id`), NOT instance OCID — referencing the instance OCID creates a Terraform circular dependency that causes the group to be created after the instance boots

The Windows instance has `windows_local_admin` created as a local account (Administrators + Remote Desktop Users) for RDP fallback if the domain join fails. Password injected via templatefile from vault output.

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

- **cloud-init timing**: OCI fires cloud-init before DNS and NAT routing are stable. Both `mini-ad.sh.template` and `userdata.sh` loop on `nslookup` + `curl` (30s intervals) before running `apt-get`.
- **apt lock race**: OCI fires cloud-init so fast that `apt-daily` grabs the apt lists lock before userdata runs. `systemctl disable --now` + `pkill -9` does not reliably win the race if apt-daily already started. Fix: retry loop on `apt-get update` with `pkill -9 -f apt` on each failure.
- **IPv6 / NAT gateway**: OCI NAT gateway silently drops IPv6 (unlike AWS/Azure/GCP which return ENETUNREACH immediately). glibc prefers AAAA records, causing indefinite hangs. Fix: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` at the top of every userdata script, plus `Acquire::ForceIPv4 "true"` for apt.
- **pip3 / urllib3 conflict**: Ubuntu 24.04 ships urllib3 without a RECORD file; `pip install --break-system-packages` fails. Fix: install OCI CLI into a venv (`python3 -m venv /opt/oci-venv`) and symlink to `/usr/local/bin/oci`.
- **SSSD offline at boot**: OCI's chaotic boot sequence can cause SSSD to go offline during network initialization. Fixed with `offline_timeout = 60` in sssd.conf — SSSD retries every 60s instead of exponential backoff.
- **time_sleep**: DC bootstraps in ~6 minutes. `time_sleep` in the module is 600s before DHCP options update to avoid client instances getting the DC IP before it is ready.
- **ARM64 apt sources**: DC instance is A1.Flex (ARM64) so Ubuntu uses `ports.ubuntu.com`, not `archive.ubuntu.com`. The IPv4 force applies to both.
- **Bastion RSA only**: OCI Bastion rejects ECDSA keys for tunnel authentication. RSA 4096 required.
- **Bastion ACTIVE lag**: OCI reports session `ACTIVE` before the key is propagated. `sleep 5` after ACTIVE before opening the tunnel.

## Keys

RSA 4096 key pair generated by `tls_private_key` in `01-directory/accounts.tf`. Written to `01-directory/keys/Private_Key` (0600) and `01-directory/keys/Private_Key.pub`. Gitignored — never committed. Used for both DC access (via bastion tunnel) and Linux client direct SSH.

## SSH to Linux Client

```bash
ssh -i 01-directory/keys/Private_Key -o StrictHostKeyChecking=no ubuntu@<linux_public_ip>
```

No bastion needed — Linux client is in a public subnet.

## Windows RDP Fallback

If the domain join fails, RDP as `windows_local_admin` — password in vault as `windows_local_admin_credentials`. The OCI console "Get Initial Password" option is not available for this instance type.
