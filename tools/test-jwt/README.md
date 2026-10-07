# Test JWT tools

Temporary tooling to call the B2B API through API Management with a bearer token while the
Entra External ID tenant is not available. API Management validates these tokens exactly as it
will validate Entra tokens (RS256 signature, issuer, audience, expiry), so the mobile app and
the Functions can already use the final authentication flow.

> **Remove this folder, the test signing key in API Management and the Key Vault secret when
> switching to Entra External ID** (see `workload/README.md`).

> Test tokens are accepted only by the environments configured for them: today only dev, which
> uses the Salesforce sandbox. Share them only within the team and with the developers of the
> mobile app, and keep their lifetime short.

This page describes the tools and their administration. The developers' guide to getting and
using test tokens is `docs/test-tokens.md`.

## How it works

| Element | Where it lives |
|---|---|
| Private key (RSA 2048) | Key Vault secret `jwt-test-signing-key`, never in the repository or in Terraform |
| Public key (modulus `n`, exponent `e`) | `jwt_validation.signing_keys` in `workload/envs/<environment>.tfvars`; not a secret |
| Tokens | minted on demand by `mint-token.sh`, which reads the private key from Key Vault |

Default claims:

| Claim | Value |
|---|---|
| `iss` | `urn:b2bapp:test-issuer` |
| `aud` | `api://b2bapp-test` |
| `sub` | random UUID for every token (override with `--sub`) |
| `iat`, `nbf`, `exp` | now, now, now + 8 hours (1-168 hours with `--hours`) |
| header `kid` | `test-1`, matching the key id configured in API Management |

## Prerequisites

- `az`, signed in to the tenant of the solution, with access to the secrets of the Key Vault.
- `openssl` and `bash`. On Windows, use Git Bash or WSL.

## One-time setup: create the signing key

```bash
./create-signing-key.sh --vault <key-vault-name>
```

The script stores the private key in Key Vault and prints the modulus `n`. Add it to
`workload/envs/<environment>.tfvars`:

```hcl
jwt_validation = {
  issuers      = ["urn:b2bapp:test-issuer"]
  audiences    = ["api://b2bapp-test"]
  signing_keys = [{ id = "test-1", n = "<modulus printed by the script>" }]
}
```

Then run plan and apply on the `workload` root.

## Mint a token

```bash
TOKEN=$(./mint-token.sh --vault <key-vault-name>)
curl -H "Authorization: Bearer $TOKEN" https://<api-management>.azure-api.net/b2bapp/v1/<route>
```

Options: `--sub <value>` for a stable subject across tokens, `--hours <1-168>` for the
lifetime, `--claim <name>=<value>` (repeatable) for additional string claims such as a customer
code, `--kid`, `--issuer`, `--audience` to match a different configuration.

`--key-file <private-key.pem>` mints a token with a local key, without Key Vault: useful only to
test the tool itself.

## Rotate the key

Create a new key with a new secret name and a new id, keep both public keys in API Management
during the transition, then remove the old one:

```bash
./create-signing-key.sh --vault <key-vault-name> --secret-name jwt-test-signing-key-2
# tfvars: signing_keys = [{ id = "test-1", n = "..." }, { id = "test-2", n = "<new modulus>" }]
./mint-token.sh --vault <key-vault-name> --secret-name jwt-test-signing-key-2 --kid test-2
```
