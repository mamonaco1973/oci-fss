# ==============================================================================
# SSH Key Pair
# Generated fresh each deploy — private key written to keys/ (gitignored)
# ==============================================================================

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "./keys/Private_Key"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "./keys/Private_Key.pub"
  file_permission = "0644"
}

# ==============================================================================
# AD Account Passwords
# Passwords are generated here and passed to the DC via the module's user_data.
# They are also output (sensitive) so 02-servers can read them via remote state.
# ==============================================================================

resource "random_password" "admin_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

resource "random_password" "jsmith_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

resource "random_password" "edavis_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

resource "random_password" "rpatel_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

resource "random_password" "akumar_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

resource "random_password" "windows_local_admin_password" {
  length           = 23
  special          = true
  min_numeric      = 2
  min_special      = 2
  override_special = "_-"
}

locals {
  admin_password               = "A${random_password.admin_password.result}"
  windows_local_admin_password = "A${random_password.windows_local_admin_password.result}"
  jsmith_password              = "A${random_password.jsmith_password.result}"
  edavis_password              = "A${random_password.edavis_password.result}"
  rpatel_password              = "A${random_password.rpatel_password.result}"
  akumar_password              = "A${random_password.akumar_password.result}"
}
