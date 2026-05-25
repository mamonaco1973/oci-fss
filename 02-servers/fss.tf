# ==============================================================================
# OCI File Storage Service (FSS)
# ------------------------------------------------------------------------------
# Purpose:
#   - Provisions a managed NFS file system equivalent to AWS EFS.
#   - Exposes two export paths: /efs (shared data) and /home (AD user homes).
#   - Linux instance mounts both paths and re-exports /efs via Samba (SMB)
#     so Windows clients can map Z: to \\<linux-ip>\efs.
#
# Scope:
#   - FSS file system (encrypted at rest by default in OCI)
#   - Mount target in vm-subnet (gets a private IP from 10.0.0.64/26)
#   - Two exports: /efs and /home
#
# Notes:
#   - OCI FSS requires 3 resources: file_system + mount_target + export(s).
#   - NFS ports (111, 2048-2050) must be open in the vm-subnet security list.
#   - Mount target IP is computed after apply — templated into Linux userdata.
# ==============================================================================

# ==============================================================================
# File System
# ==============================================================================

resource "oci_file_storage_file_system" "fss" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_ocid
  display_name        = "mcloud-fss"
}

# ==============================================================================
# Mount Target
# ------------------------------------------------------------------------------
# Lives in vm-subnet so both the Linux instance and mount target share
# the same subnet security list rules for NFS traffic.
# ==============================================================================

resource "oci_file_storage_mount_target" "fss_mt" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_ocid
  subnet_id           = local.vm_subnet_ocid
  display_name        = "mcloud-fss-mt"
}

# ==============================================================================
# Exports
# ------------------------------------------------------------------------------
# /efs  — shared data directory, re-exported via Samba to Windows as Z:
# /home — AD user home directories shared across Linux instances
# ==============================================================================

resource "oci_file_storage_export" "efs_export" {
  export_set_id  = oci_file_storage_mount_target.fss_mt.export_set_id
  file_system_id = oci_file_storage_file_system.fss.id
  path           = "/efs"
}

resource "oci_file_storage_export" "home_export" {
  export_set_id  = oci_file_storage_mount_target.fss_mt.export_set_id
  file_system_id = oci_file_storage_file_system.fss.id
  path           = "/home"
}
