# OCI File Storage Service (FSS)

This project deploys a shared NFS file system on OCI using File Storage Service (FSS) — the OCI equivalent of AWS EFS. An Ubuntu Linux instance mounts the FSS filesystem and acts as a Samba (SMB) gateway, allowing a Windows Server instance to map a persistent `Z:` drive to the shared storage. All instances are joined to a Samba 4 Active Directory domain.

Two-phase Terraform deploy: `01-directory` provisions networking, security rules, and the Samba 4 DC. `02-servers` provisions the FSS filesystem, mount target, exports, and client instances.

---

## Architecture

```
vm-subnet (10.0.0.64/26)
  ┌──────────────────┐        NFS         ┌──────────────────────┐
  │  Linux Instance  │ ──────────────────▶ │   FSS Mount Target   │
  │  (Ubuntu 24.04)  │                     │   (10.0.0.x)         │
  │                  │                     ├──────────────────────┤
  │  /efs  (mounted) │                     │ export /efs          │
  │  /home (mounted) │                     │ export /home         │
  │                  │                     └──────────────────────┘
  │  Samba [efs]     │
  └──────────────────┘
          │ SMB (Z: drive)
          ▼
  ┌──────────────────┐
  │ Windows Instance │
  │  (Server 2022)   │
  │   Z: = \\linux\efs│
  └──────────────────┘

ad-subnet (10.0.0.0/26) — private, NAT egress only
  └── Samba 4 DC (ARM64, always-free A1.Flex)
```

---

## What Gets Deployed

**Networking:**
- VCN (10.0.0.0/24) with Internet Gateway and NAT Gateway
- Public vm-subnet (10.0.0.64/26) — Linux and Windows instances
- Private ad-subnet (10.0.0.0/26) — Samba 4 domain controller
- Security list rules for SSH, RDP, NFS (111/2048-2050), and SMB (445)

**Active Directory:**
- Ubuntu 24.04 ARM64 instance (VM.Standard.A1.Flex, always-free) running Samba 4
- OCI Bastion Service for SSH access to the private DC

**File Storage:**
- OCI FSS filesystem (encrypted at rest)
- Mount target in vm-subnet with two NFS exports: `/efs` and `/home`

**Linux NFS/Samba Gateway:**
- Ubuntu 24.04 (VM.Standard.E4.Flex, 1 OCPU / 4 GB)
- Mounts FSS `/efs` at `/efs` and FSS `/home` at `/home`
- Exposes `/efs` as a Samba `[efs]` share (SMB, AD-authenticated)
- Joined to the domain; AD users can SSH in with their domain credentials

**Windows Client:**
- Windows Server 2022 (VM.Standard.E4.Flex, 2 OCPU / 16 GB)
- Joined to the domain at first boot
- Maps `Z:` to `\\<linux-ip>\efs` at every login via a startup script

---

## Prerequisites

- An OCI account with available Always Free resources
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) configured with a DEFAULT profile in `~/.oci/config`
- [Terraform](https://developer.hashicorp.com/terraform/install) (latest)
- `jq` installed in PATH

---

## Download this Repository

```bash
git clone https://github.com/mamonaco1973/oci-fss.git
cd oci-fss
```

---

## Build the Code

Run `check_env.sh` to validate your environment, then run `apply.sh` to provision.

```bash
export OCI_COMPARTMENT_ID=<your-compartment-ocid>   # optional; falls back to tenancy OCID
./apply.sh
```

The deploy runs in two phases:

1. **01-directory** — VCN, subnets, bastion, security rules (including NFS/SMB), and the Samba 4 DC. Waits for the DC to signal completion before updating DHCP options.
2. **02-servers** — FSS filesystem, mount target, NFS exports, Linux gateway, and Windows client.

Total build time is approximately 20–25 minutes end to end.

---

## Users and Groups

The following sample users and groups are created automatically during DC provisioning.

### Groups

| Group Name   | gidNumber |
|--------------|-----------|
| mcloud-users | 10001     |
| us           | 10002     |
| india        | 10003     |
| linux-admins | 10004     |

### Users

| Username | Full Name   | uidNumber | gidNumber | Groups                            |
|----------|-------------|-----------|-----------|-----------------------------------|
| jsmith   | John Smith  | 10001     | 10001     | mcloud-users, us, linux-admins    |
| edavis   | Emily Davis | 10002     | 10001     | mcloud-users, us                  |
| rpatel   | Raj Patel   | 10003     | 10001     | mcloud-users, india, linux-admins |
| akumar   | Amit Kumar  | 10004     | 10001     | mcloud-users, india               |

---

## Retrieving Passwords

Passwords are read directly from Terraform state:

```bash
./get_password.sh admin
./get_password.sh jsmith
./get_password.sh edavis
./get_password.sh rpatel
./get_password.sh akumar
./get_password.sh windows_local_admin
```

---

## Connecting to the Linux Instance

The Linux client has a public IP. SSH directly using the generated key:

```bash
ssh -i 01-directory/keys/Private_Key -o StrictHostKeyChecking=no ubuntu@<linux_public_ip>
```

After login you can verify the FSS mounts:

```bash
df -h /efs /home
ls /efs
```

---

## Connecting to the Windows Instance

Use the public IP shown in Terraform outputs. Connect via RDP with domain credentials:

- **Username:** `MCLOUD\Admin` or any domain user from the table above
- **Password:** retrieved via `./get_password.sh <user>`

After login, open File Explorer — `Z:` should be mapped to `\\<linux-ip>\efs`.

---

## Connecting to the DC

The DC has no public IP. Use `connect.sh` to create an OCI Bastion port-forwarding session:

```bash
./connect.sh            # connects to the DC
./connect.sh 10.0.0.x   # connects to any private IP
```

---

## Why We Did Not Use OCI Vault

OCI KMS Vault was the natural choice for storing generated AD passwords securely. However, OCI imposes a mandatory pending-deletion hold on KMS vaults after they are destroyed, and during this hold the vault still counts against the tenancy service limit (defaults to one vault per tenancy). This makes Vault fundamentally incompatible with `destroy`/`rebuild` workflows: every fresh `apply` after a `destroy` fails with `LimitExceeded`.

AWS Secrets Manager and Azure Key Vault both handle deletion gracefully. This is an OCI platform deficiency.

**Current approach:** Passwords are stored as sensitive outputs in `terraform.tfstate`. Use `./get_password.sh` to retrieve any credential.

---

## Clean Up

```bash
./destroy.sh
```

Destroys `02-servers` first (FSS, instances), then `01-directory` (DC, networking). All OCI resources are deleted immediately — no retention periods.
