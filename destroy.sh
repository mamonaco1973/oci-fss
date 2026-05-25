#!/bin/bash
# ==============================================================================
# destroy.sh - Mini-AD Infrastructure Teardown (OCI)
# ------------------------------------------------------------------------------
# Purpose:
#   - Destroys the mini-AD environment in controlled order:
#       1. Client compute instances (02-servers).
#       2. Active Directory resources and networking (01-directory).
#
# WARNING:
#   - This action is destructive and irreversible.
# ==============================================================================

set -euo pipefail

# Resolve compartment — fall back to tenancy OCID if OCI_COMPARTMENT_ID is unset
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
fi
export TF_VAR_compartment_ocid="$OCI_COMPARTMENT_ID"

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
export TF_VAR_tenancy_ocid="$TENANCY_OCID"

# ------------------------------------------------------------------------------
# Phase 1: Destroy Client Instances
# ------------------------------------------------------------------------------
echo "NOTE: Destroying OCI client compute instances..."

cd 02-servers || { echo "ERROR: Directory 02-servers not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Phase 2: Destroy Active Directory Infrastructure
# ------------------------------------------------------------------------------
echo "NOTE: Destroying Active Directory resources and networking..."

cd 01-directory || { echo "ERROR: Directory 01-directory not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd ..

# Remove generated key pair so next apply produces a fresh one
rm -f 01-directory/keys/Private_Key 01-directory/keys/Private_Key.pub

echo "NOTE: Infrastructure destruction complete."
