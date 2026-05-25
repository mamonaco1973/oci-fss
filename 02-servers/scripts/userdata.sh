#!/bin/bash
set -euo pipefail

LOG=/root/userdata.log
mkdir -p /root
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG" | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR

echo "user-data start: $(date -Is)"

# Disable IPv6 — OCI subnets are IPv4-only; leaving IPv6 enabled causes glibc
# to prefer AAAA records and waste time on unroutable connection attempts.
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

# Disable automatic updates and kill any already-running apt processes —
# OCI fires cloud-init fast enough that apt-daily may have grabbed the lock
# before this script runs; disable alone does not kill an in-flight process.
systemctl disable --now apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
pkill -9 -f unattended-upgrades 2>/dev/null || true
pkill -9 -f apt 2>/dev/null || true
sleep 2

# OCI Ubuntu images block all inbound ports via iptables by default.
# TODO: restrict source CIDR and open only required ports for production.
iptables -I INPUT -s 0.0.0.0/0 -j ACCEPT

# Credentials and config injected by Terraform via templatefile
ADMIN_USERNAME="Admin"
ADMIN_PASSWORD="${admin_password}"
DOMAIN_FQDN="${domain_fqdn}"

echo "Waiting for DNS resolution..."
until nslookup us.archive.ubuntu.com >/dev/null 2>&1; do
  echo "DNS not ready yet, retrying in 30s..."
  sleep 30
done
echo "DNS ready: $(date -Is)"

echo "Waiting for outbound internet connectivity..."
until curl -fsS --max-time 10 https://us.archive.ubuntu.com/ >/dev/null 2>&1; do
  echo "Internet not reachable yet, retrying in 30s..."
  sleep 30
done
echo "Network ready: $(date -Is)"

# Packages
# Rewrite apt sources — avoids ubuntu.com DDoS issues on OCI
sed -i 's|http://archive.ubuntu.com|http://us.archive.ubuntu.com|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
sed -i 's|http://security.ubuntu.com|http://us.archive.ubuntu.com|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
# OCI NAT gateway does not route IPv6 — force IPv4 for all apt traffic
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
# APT::Update::Error-Mode=any makes apt-get update exit non-zero when any
# source fails — without it, W: warnings still exit 0 and fool the retry loop.
for i in {1..20}; do
  apt-get update -y -o APT::Update::Error-Mode=any && break
  echo "apt-get update failed (attempt $i/20), killing apt and retrying in 30s..."
  pkill -9 -f apt 2>/dev/null || true
  sleep 30
done
apt-get install -y \
  less curl jq python3-venv \
  realmd sssd-ad sssd-tools libnss-sss libpam-sss \
  adcli samba-common-bin samba-libs \
  oddjob oddjob-mkhomedir packagekit krb5-user \
  nano vim iptables-persistent

# Install OCI CLI into a venv — avoids conflict with Debian-managed urllib3
# which has no RECORD file and blocks pip's dependency resolution.
python3 -m venv /opt/oci-venv
/opt/oci-venv/bin/pip install --quiet oci-cli
ln -sf /opt/oci-venv/bin/oci /usr/local/bin/oci

# Wait for DC Kerberos — DNS resolving the domain is not enough; the full AD
# stack (Kerberos, LDAP) takes longer after the DC reboots post-provision.
echo "Waiting for DC Kerberos on $DOMAIN_FQDN..."
until echo "$ADMIN_PASSWORD" | kinit "$ADMIN_USERNAME@${domain_fqdn_upper}" 2>/dev/null; do
  echo "Kerberos not ready yet, retrying in 30s..."
  sleep 30
done
kdestroy 2>/dev/null || true
echo "DC Kerberos ready: $(date -Is)"

# Join AD domain — retry loop in case LDAP/SMB are still initialising
echo "Joining domain $DOMAIN_FQDN as $ADMIN_USERNAME"
for i in {1..10}; do
  if echo "$ADMIN_PASSWORD" | realm join -U "$ADMIN_USERNAME" "$DOMAIN_FQDN"; then
    echo "Domain join succeeded on attempt $i"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "ERROR: domain join failed after 10 attempts"
    exit 1
  fi
  echo "Domain join failed (attempt $i/10), retrying in 30s..."
  sleep 30
done

# SSH: allow password authentication for AD users
if [ -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf ]; then
  sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' \
    /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
else
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config || true
fi

# SSSD tweaks
if [ -f /etc/sssd/sssd.conf ]; then
  sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/g' /etc/sssd/sssd.conf || true
  sed -i 's/ldap_id_mapping = True/ldap_id_mapping = False/g' /etc/sssd/sssd.conf || true
  sed -i 's|fallback_homedir = /home/%u@%d|fallback_homedir = /home/%u|g' /etc/sssd/sssd.conf || true
  sed -i '/^\[nss\]/a entry_negative_timeout = 0' /etc/sssd/sssd.conf || true
  sed -i '/^\[domain\//a offline_timeout = 60' /etc/sssd/sssd.conf || true
  chmod 600 /etc/sssd/sssd.conf || true
fi

# Avoid XAuthority warning for new users
touch /etc/skel/.Xauthority
chmod 600 /etc/skel/.Xauthority

# Enable mkhomedir + restart services
pam-auth-update --enable mkhomedir || true
systemctl restart sssd || true
systemctl restart ssh || systemctl restart sshd || true

# Sudoers for linux-admins group (idempotent)
SUDO_FILE=/etc/sudoers.d/10-linux-admins
if [ ! -f "$SUDO_FILE" ]; then
  echo "%linux-admins ALL=(ALL) NOPASSWD:ALL" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
fi

netfilter-persistent save

realm list || true
echo "user-data complete: $(date -Is)"
