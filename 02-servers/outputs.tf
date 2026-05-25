output "linux_public_ip" {
  description = "Public IP of the Linux AD client instance."
  value       = oci_core_instance.linux_ad_instance.public_ip
}

