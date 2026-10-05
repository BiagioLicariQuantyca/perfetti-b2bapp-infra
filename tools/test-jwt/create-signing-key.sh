#!/usr/bin/env bash
# Creates the RSA key pair that signs test JWTs, stores the private key in Key Vault and
# prints the public key values to configure in API Management (jwt_validation.signing_keys).
#
# The private key never leaves the Key Vault except for the temporary file used while
# signing tokens. To be removed together with the test keys when Entra External ID is used.
#
# Usage:
#   ./create-signing-key.sh --vault <key-vault-name> [--secret-name jwt-test-signing-key]
#
# Requires: az (signed in, with permission to set secrets), openssl.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

VAULT=""
SECRET_NAME="jwt-test-signing-key"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done
[[ -n "$VAULT" ]] || usage
require az openssl

# A new key must use a new secret name and a new kid: overwriting the existing key would
# invalidate every token in circulation without any transition period.
if az keyvault secret show --vault-name "$VAULT" --name "$SECRET_NAME" --query id -o tsv >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists in $VAULT. For a rotation use a new --secret-name and a new kid." >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
chmod 700 "$workdir"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$workdir/private.pem" 2>/dev/null
chmod 600 "$workdir/private.pem"

az keyvault secret set --vault-name "$VAULT" --name "$SECRET_NAME" \
  --file "$workdir/private.pem" --content-type "application/x-pem-file" --output none

modulus="$(openssl rsa -in "$workdir/private.pem" -noout -modulus | cut -d= -f2 | hex_to_bin | b64url)"

cat <<EOF
Private key stored in Key Vault $VAULT, secret $SECRET_NAME.

Public key for API Management (envs/<environment>.tfvars, jwt_validation.signing_keys):
  n = "$modulus"
  e = "AQAB"
EOF
