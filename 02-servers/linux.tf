# ==============================================================================
# OCI Compute Instance: Linux AD Client
# ------------------------------------------------------------------------------
# Purpose:
#   - Deploys an Ubuntu 24.04 instance for AD integration and testing.
#   - Joined to the Samba domain via realm join using admin credentials.
#   - Launched into the public subnet with a public IP for SSH access.
# ==============================================================================

resource "oci_core_instance" "linux_ad_instance" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_ocid
  shape               = "VM.Standard.E4.Flex"
  display_name        = local.linux_hostname

  shape_config {
    ocpus         = 1
    memory_in_gbs = 4
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = local.vm_subnet_ocid
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.ssh_nsg.id]
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data = base64encode(templatefile("./scripts/userdata.sh", {
      admin_password    = local.admin_password
      domain_fqdn       = var.dns_zone
      domain_fqdn_upper = upper(var.dns_zone)
      netbios           = var.netbios
      dc_ip             = local.dc_private_ip
    }))
  }
}
