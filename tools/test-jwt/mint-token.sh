#!/usr/bin/env bash
# Mints a test JWT (RS256) accepted by API Management while Entra External ID is not available.
# The token is printed on stdout; use it as "Authorization: Bearer <token>".
#
# Usage:
#   ./mint-token.sh --vault <key-vault-name> [options]
#   ./mint-token.sh --key-file <private-key.pem> [options]   # local key, for testing the tool
#
# Options (defaults match the test configuration of API Management):
#   --secret-name NAME   Key Vault secret with the private key (default jwt-test-signing-key)
#   --kid ID             key identifier, must match the API Management signing key (default test-1)
#   --issuer VALUE       iss claim (default urn:b2bapp:test-issuer)
#   --audience VALUE     aud claim (default api://b2bapp-test)
#   --sub VALUE          sub claim (default: a random UUID for every token)
#   --hours N            validity in hours, 1-168 (default 8)
#
# Requires: openssl, and az (signed in, with permission to read secrets) when using --vault.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

VAULT=""
KEY_FILE=""
SECRET_NAME="jwt-test-signing-key"
KID="test-1"
ISSUER="urn:b2bapp:test-issuer"
AUDIENCE="api://b2bapp-test"
SUB=""
HOURS=8

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --key-file) KEY_FILE="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    --kid) KID="$2"; shift 2 ;;
    --issuer) ISSUER="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    --sub) SUB="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done
[[ -n "$VAULT" || -n "$KEY_FILE" ]] || usage
require openssl

[[ "$HOURS" =~ ^[0-9]+$ ]] && (( HOURS >= 1 && HOURS <= 168 )) || { echo "--hours must be between 1 and 168" >&2; exit 1; }

# The default subject is an opaque random identifier, never a person's name.
if [[ -z "$SUB" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    SUB="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    SUB="$(cat /proc/sys/kernel/random/uuid)"
  else
    SUB="$(openssl rand -hex 16)"
  fi
fi

# Claim values are embedded in JSON as they are: allow only characters that need no escaping.
for value in "$KID" "$ISSUER" "$AUDIENCE" "$SUB"; do
  [[ "$value" =~ ^[A-Za-z0-9:/._@-]+$ ]] || { echo "Unsupported characters in claim value: $value" >&2; exit 1; }
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
chmod 700 "$workdir"

if [[ -n "$VAULT" ]]; then
  require az
  az keyvault secret show --vault-name "$VAULT" --name "$SECRET_NAME" --query value -o tsv > "$workdir/private.pem"
  chmod 600 "$workdir/private.pem"
  KEY_FILE="$workdir/private.pem"
fi

now="$(date +%s)"
exp="$(( now + HOURS * 3600 ))"

header="$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$KID" | b64url)"
payload="$(printf '{"iss":"%s","aud":"%s","sub":"%s","iat":%d,"nbf":%d,"exp":%d}' \
  "$ISSUER" "$AUDIENCE" "$SUB" "$now" "$now" "$exp" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY_FILE" -binary | b64url)"

printf '%s.%s.%s\n' "$header" "$payload" "$signature"
