#!/bin/bash
# ==============================================================================
# apply.sh - Mini-AD Infrastructure Deployment (OCI)
# ------------------------------------------------------------------------------
# Purpose:
#   - Provisions the mini-AD environment in two ordered phases:
#       1. Active Directory (Samba 4) deployment via the OCI mini-ad module.
#       2. Dependent OCI compute instances (Linux + Windows clients).
#
# Fast-Fail Behavior:
#   - Script exits immediately on command failure, unset variables,
#     or failed pipelines.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Environment Pre-Check
# ------------------------------------------------------------------------------
echo "NOTE: Running environment validation..."
./check_env.sh

# Resolve compartment — fall back to tenancy OCID if OCI_COMPARTMENT_ID is unset
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
fi
export TF_VAR_compartment_ocid="$OCI_COMPARTMENT_ID"

# Dynamic groups must live in the root tenancy — always extract from config
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
export TF_VAR_tenancy_ocid="$TENANCY_OCID"

# ------------------------------------------------------------------------------
# Phase 1: Active Directory Deployment
# ------------------------------------------------------------------------------
echo "NOTE: Deploying Active Directory resources..."

cd 01-directory || { echo "ERROR: Directory 01-directory not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Phase 2: Client Instances (Linux + Windows)
# ------------------------------------------------------------------------------
echo "NOTE: Deploying client instances..."

cd 02-servers || { echo "ERROR: Directory 02-servers not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

./validate.sh
