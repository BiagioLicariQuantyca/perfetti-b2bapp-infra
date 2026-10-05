# Shared helpers of the test JWT tools. Sourced, not executed.

# Base64url encoding without padding (RFC 7515).
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Hex string on stdin to binary on stdout.
hex_to_bin() {
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p
  else
    perl -ne 's/\s+//g; s/([0-9a-fA-F]{2})/chr(hex($1))/ge; print'
  fi
}

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
  done
}
