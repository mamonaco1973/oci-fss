# OCI File Storage (FSS) + Active Directory on OCI: NFS and Samba File Sharing

Shared file storage for Linux and Windows, backed by **OCI File Storage**
and secured with a **mini-AD** domain. A Linux gateway mounts an FSS export
over NFS for home directories and a shared area, and re-shares it over
**SMB**, so a Windows instance reaches the same files as a mapped drive. Every
login uses an AD account.

[![Watch the video](https://img.youtube.com/vi/dbPnF3yEgXk/maxresdefault.jpg)](https://www.youtube.com/watch?v=dbPnF3yEgXk)

| Piece | Where | Role |
|---|---|---|
| **SMB gateway** | `vm-subnet` | Ubuntu 24.04, `VM.Standard.E4.Flex` (1 OCPU, 4 GB); joined to AD with SSSD; mounts the FSS export as `/nfs`, with `/home` on it; shares `/nfs` through Samba; SSH from the internet |
| **Windows Server 2022** | `vm-subnet` | `VM.Standard.E4.Flex` (2 OCPU, 8 GB); joined to AD; RSAT for managing users; maps the gateway's `nfs` share as `Z:` |
| **mini-AD** (Samba DC) | `ad-subnet`, no public IP | Ubuntu 24.04 on `VM.Standard.A1.Flex` (ARM); users, groups, POSIX IDs, DNS, Kerberos |
| **File Storage** | mount target in `vm-subnet` | file system `mcloud-fss`, exported as `/nfs`, encrypted at rest |
| **OCI Bastion** | targets `ad-subnet` | SSH port-forwarding sessions to the DC |
| **Object Storage** | regional | sentinel bucket the DC writes to when it has finished booting |
| **NAT gateway** | `ad-subnet` route | outbound internet for the DC |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="An SSH client reaches the SMB gateway, an Ubuntu 24.04 instance, and an RDP client reaches a Windows Server 2022 instance beside it; both are in the public VM subnet. The gateway mounts the /nfs export of an OCI File Storage file system over NFSv3 and re-shares it over SMB to the Windows instance as drive Z:. Terraform keeps the AD passwords in its state and passes them to both instances as user data; both join the mini-AD domain controller. The DC sits in a private subnet, reaches the internet through a NAT gateway, is reached over SSH through OCI Bastion, and writes a dc-ready object to an Object Storage sentinel bucket when it has finished booting." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-directory/`**: the VCN (`mini-ad-vcn`, 10.0.0.0/24) with a public
  `vm-subnet` (10.0.0.64/26) and a private `ad-subnet` (10.0.0.0/26), the
  internet and NAT gateways, the security lists, the bastion, the SSH key
  pair and AD passwords, and the
  [`module-oci-mini-ad`](https://github.com/mamonaco1973/module-oci-mini-ad)
  Samba DC with users and POSIX attributes from `users.json`.
- **`02-servers/`**: the FSS file system, mount target and `/nfs` export, the
  SMB gateway and Windows instances, and their network security groups. It
  reads the passwords, key and subnet IDs from the `01-directory` state.

## Why a Samba gateway

FSS serves NFS only. Linux mounts it directly with POSIX ownership, but
Windows can't use it with AD identities. The gateway mounts the export and
serves the same directory over SMB. Samba runs in ADS mode with SSSD as its
ID map backend, so a file written as `rpatel` on Linux is owned by
`rpatel@mcloud.mikecloud.com` on Windows, with the same POSIX IDs from AD.

## How the share works

1. The DC boots, builds the domain, and writes `dc-ready` to its sentinel
   bucket. Terraform waits for that object, then points the VCN's DHCP
   options at the DC for DNS.
2. At boot the gateway waits for DNS and outbound internet, then mounts the
   FSS export as `/nfs` over NFSv3. It moves the local `/home` aside and
   links `/home` to `/nfs/home`, so home directories live on FSS.
3. It waits until the DC answers Kerberos, then joins the domain with
   `realm join`. SSSD is set for short names (`jsmith`, not
   `jsmith@mcloud.mikecloud.com`) and the POSIX IDs stored in AD, and SSH
   allows password logins.
4. Samba shares `/nfs` as `nfs` and each user's home as `homes`. New files are
   group `mcloud-users`, mode `0770`. `/nfs/data` is the shared area for
   `mcloud-users`; each home directory is `0700`.
5. The gateway clones this repository into `/nfs/oci-fss`, so the share has
   content from the start.
6. The Windows instance creates a local `windows_local_admin` account as an
   RDP fallback, joins the domain, allows `mcloud-users` to sign in over RDP,
   maps `\\<gateway IP>\nfs` as `Z:` at every login, and reboots.
7. Members of **`linux-admins`** get passwordless sudo on the gateway.

| User | Groups | sudo on the gateway |
|---|---|---|
| jsmith | mcloud-users, us, linux-admins, Domain Admins | yes |
| edavis | mcloud-users, us | no |
| rpatel | mcloud-users, india, linux-admins, Domain Admins | yes |
| akumar | mcloud-users, india | no |

| Group | gidNumber |
|---|---|
| mcloud-users | 10001 |
| us | 10002 |
| india | 10003 |
| linux-admins | 10004 |

`mcloud-users` is named after the NetBIOS domain (`<netbios>-users`), so it
changes if you change the domain.

## Network security

```
internet ─22────▶ SMB gateway ─NFS─▶ FSS mount target
internet ─3389──▶ Windows ─445─▶ SMB gateway (Z: is /nfs)
internet ─Bastion session─▶ DC :22
```

| Rule | Where | Allows |
|---|---|---|
| `vm-security-list` | `vm-subnet` | 22 and 3389 from anywhere; 111, 2048–2050 (NFS) and 445 from `vm-subnet` only |
| `ad-ssh-nsg` | SMB gateway | 22 from anywhere |
| `ad-smb-nsg` | SMB gateway | 445 from `vm-subnet` |
| `ad-rdp-nsg` | Windows | 3389 from anywhere |
| `ad-security-list` | `ad-subnet` | everything from the VCN |

SMB and NFS stay inside `vm-subnet`. The DC has no public IP; the bastion
accepts sessions from any address.

## Where the passwords live

The AD passwords are generated by Terraform and kept as sensitive outputs in
`01-directory/terraform.tfstate`. `02-servers` reads them from that state and
passes the admin password to both instances as user data, for the domain
join.

OCI Vault was the obvious place for them, but a destroyed vault stays in
`PENDING_DELETION` and still counts against the tenancy limit (one vault by
default), so every `apply` after a `destroy` fails with `LimitExceeded`.

```bash
./get_password.sh rpatel               # also: admin, jsmith, edavis, akumar, ubuntu, windows_local_admin
```

## Prerequisites

* An OCI account with available Always Free resources
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm),
  configured with a `DEFAULT` profile in `~/.oci/config`
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install jq](https://jqlang.github.io/jq/download/)

## Deploy

```bash
git clone https://github.com/mamonaco1973/oci-fss.git
cd oci-fss
export OCI_COMPARTMENT_ID=<compartment-ocid>   # optional; defaults to the tenancy
./apply.sh       # 1: VCN + bastion + mini-AD  2: FSS, gateway, Windows
```

Everything deploys to `us-ashburn-1`, in the first availability domain. A
full run takes about 20–25 minutes, most of it the DC's bootstrap. After
`apply.sh` finishes, the gateway needs a few minutes to mount FSS and join
the domain. The Windows instance takes longer, because it joins and then
reboots.

`apply.sh` ends by running `validate.sh`, which prints the hosts:

```
============================================================================
OCI FSS - Deployment Summary
============================================================================

  Domain Controller (private)
    IP       : 10.0.0.10
    Connect  : ./connect.sh

  SMB Gateway (public)
    IP       : 203.0.113.20
    Connect  : ssh -i 01-directory/keys/Private_Key ubuntu@203.0.113.20
    AD user  : ./get_password.sh rpatel  =>  ssh rpatel@203.0.113.20

  Windows Client (public)
    IP       : 203.0.113.10
    Connect  : RDP to 203.0.113.10 as MCLOUD\Admin

  Passwords  : ./get_password.sh <user>
               users: admin jsmith edavis rpatel akumar

============================================================================
```

## Try it

1. `./get_password.sh rpatel`, then SSH to the **SMB Gateway** as `rpatel`.
   Try `id`, `df -h /nfs`, `ls -l /nfs /nfs/home` and `sudo -l`.

2. RDP to the **Windows Client** as `MCLOUD\rpatel`. `Z:` is the gateway's
   `/nfs`: the same `home` and `data` folders, and the cloned repository.

3. `./connect.sh` opens a bastion session to the DC and drops you into a
   shell there as `ubuntu`. `./connect.sh <private-ip>` reaches any other
   private address the same way.

## Changing the domain name

The default domain is `mcloud.mikecloud.com` / `MCLOUD`. To use another,
uncomment and edit the override lines near the top of `apply.sh` and
`destroy.sh`:

```bash
export TF_VAR_dns_zone="lab.mikecloud.com"
export TF_VAR_realm="LAB.MIKECLOUD.COM"
export TF_VAR_netbios="LAB"
export TF_VAR_user_base_dn="CN=Users,DC=lab,DC=mikecloud,DC=com"
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| SSH rejects every AD password | The gateway hasn't finished its domain join. SSH in as `ubuntu` with `01-directory/keys/Private_Key` and `sudo tail /root/userdata.log`; it logs each wait (DNS, internet, Kerberos) and join attempt. |
| `/nfs` isn't mounted | `grep nfs /etc/fstab`, then `sudo mount /nfs`. The mount target IP is `terraform output mount_target_ip` in `02-servers`. |
| `Z:` is missing on Windows | The Windows instance joins the domain and reboots after deploy; give it time. The mapping runs from `map_drives.bat` in the all-users Startup folder at each login. The boot log is `C:\ProgramData\userdata.log`. |
| The domain join failed on Windows | RDP as `windows_local_admin` (`./get_password.sh windows_local_admin`) and read `C:\ProgramData\userdata.log`. |
| `connect.sh` hangs or the tunnel is refused | Bastion sessions report `ACTIVE` before the key is in place; the script waits, but run it again if the first attempt fails. |
| `id <user>` finds nothing | The user needs `uidNumber`, `gidNumber` and `uid` set in AD. SSSD caches lookups; `sudo sss_cache -E` clears it. |

## Teardown

```bash
./destroy.sh     # destroys phase 2, then phase 1, then deletes the local SSH keys
```

## Notes

- **Lab only.** SSH and RDP are open to the internet, the bastion accepts any
  client address, jsmith and rpatel are Domain Admins, and the join uses the
  domain admin account. The admin password is in Terraform state and in both
  instances' user data, and the gateway's local `ubuntu` password is set to
  it. Restrict the rules and use a dedicated join account for anything more.
- Users, groups and POSIX IDs are defined in
  `01-directory/scripts/users.json.template`.
