# Test tokens for the B2B API

Until Entra External ID is available, API Management accepts **test bearer tokens** signed with
a private key kept in Key Vault. This guide explains how the developers of the Functions get a
token and use it to call the API.

API Management validates test tokens exactly as it will validate Entra tokens (RS256 signature,
issuer, audience, expiry), and forwards the `Authorization` header unchanged to the Function
App: the code that reads the token works the same way today and after the switch.

> Test tokens are accepted only by the **dev** environment, connected to the Salesforce sandbox.
> Production accepts only Entra External ID tokens and, until then, rejects every request. Treat
> tokens as credentials anyway and follow the [rules](#rules).

## What a test token contains

| Part | Claim | Value |
|---|---|---|
| Header | `alg`, `typ` | `RS256`, `JWT` |
| Header | `kid` | `test-1`: identifies the signing key configured in API Management |
| Payload | `iss` | `urn:b2bapp:test-issuer` |
| Payload | `aud` | `api://b2bapp-test` |
| Payload | `sub` | user identifier: a random UUID for every token, or the value of `--sub` |
| Payload | `iat`, `nbf`, `exp` | issued at, valid from, expires at (Unix time) |

Test tokens carry **no other claims** unless you add them with `--claim`: no scopes (`scp`), no
`oid`, no email or name. See
[After the switch to Entra External ID](#after-the-switch-to-entra-external-id) for what
changes.

## Prerequisites

1. **The repository**, cloned locally: the scripts are in `tools/test-jwt/`.
2. **Tools**: `bash`, `openssl` and the Azure CLI (`az`); `jq` is optional, to read the claims.
   On Windows, use Git Bash or WSL, and sign in with `az` from the same shell.
3. **Sign-in** to the tenant of the solution with your own account (the tenant ID is in
   `bootstrap/envs/<environment>.env`):

   ```bash
   az login --tenant <tenant-id>
   ```

4. **Read access to the Key Vault secrets**. The Key Vault name is `key_vault_name` in
   `workload/envs/<environment>.tfvars`. Check your access:

   ```bash
   az keyvault secret show --vault-name <key-vault-name> --name jwt-test-signing-key --query id -o tsv
   ```

   - it prints the secret identifier: you're ready;
   - it fails with `Forbidden`: ask for access, sending your object ID
     (`az ad signed-in-user show --query id -o tsv`) to whoever manages the infrastructure
     (see [Granting access](#granting-access)).

   The command prints only the identifier of the secret, never the key.

## Get a token

From the repository root:

```bash
TOKEN=$(tools/test-jwt/mint-token.sh --vault <key-vault-name>)
```

The script reads the private key from Key Vault into a temporary folder, signs the token and
deletes the folder on exit: the key is never stored on your machine.

| Option | Default | Use |
|---|---|---|
| `--hours N` | 8 | lifetime, from 1 to 168 hours (7 days). Keep it as short as your test allows: more than 24 hours only for tokens handed to the developers of the mobile app |
| `--sub VALUE` | random UUID | stable user identifier, to simulate the same user across tokens. Allowed characters: letters, digits and `: / . _ @ -` |
| `--claim NAME=VALUE` | none | additional string claim, repeatable, for example `--claim customer_code=C0001`. Same allowed characters; the standard claims can't be overridden |

`--kid`, `--issuer` and `--audience` exist only to match a different API Management
configuration: don't change them for normal tests.

## Call the API

The base URL of dev is `https://apim-b2bapp-dev-weu-001.azure-api.net/b2bapp/v1` (output
`api_base_url` of the `workload` root). API Management maps every route to the Function App of
the same environment:

```
https://apim-b2bapp-dev-weu-001.azure-api.net/b2bapp/v1/<route>  ──>  https://func-api-b2bapp-dev-weu-001.azurewebsites.net/api/<route>
```

```bash
URL=https://apim-b2bapp-dev-weu-001.azure-api.net/b2bapp/v1
curl -i -H "Authorization: Bearer $TOKEN" "$URL/<route>"
curl -i -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"field":"value"}' "$URL/<route>"
```

- Supported methods: `GET`, `POST`, `PUT`, `PATCH` and `DELETE`.
- Any HTTP client works (Postman, Bruno, the VS Code REST Client…): set the header
  `Authorization: Bearer <token>`. In Postman, use **Authorization → Bearer Token**.
- Keep the default route prefix `api` in `host.json`: API Management forwards to `/api/<route>`.
- The first call after a period of inactivity is slower: the Function App starts from zero
  instances (cold start).

## Use the token when running the Functions locally

With Core Tools (`func start`) requests don't go through API Management and the function key
isn't required. Send the same header to the local endpoint, so that the code reading the claims
gets a realistic token:

```bash
curl -i -H "Authorization: Bearer $TOKEN" http://localhost:7071/api/<route>
```

Locally **nothing validates the token**: authentication can only be tested through API
Management.

## Read the claims

Decode the token locally, for example to check the expiry or the `sub` value:

```bash
jq -R 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson
       | .iat |= todate | .nbf |= todate | .exp |= todate' <<< "$TOKEN"
```

Don't paste tokens into websites that decode JWTs: they are valid credentials.

## Test object-level authorization

The functions must check that the requested record belongs to the user of the token (see the
security requirement in `docs/functions-developer-guide.md`). Two stable identities make this
easy to test:

```bash
TOKEN_A=$(tools/test-jwt/mint-token.sh --vault <key-vault-name> --sub test-user-a \
  --claim customer_code=<customer code A> --hours 1)
TOKEN_B=$(tools/test-jwt/mint-token.sh --vault <key-vault-name> --sub test-user-b \
  --claim customer_code=<customer code B> --hours 1)
```

Verify that each token reads and writes only the record of its own customer code, and that a
token without the claim is rejected.

The claim name `customer_code` is provisional: the final name depends on how Entra External ID
is configured. Read it from an app setting, so that the switch is a configuration change.

## Rules

- **Tokens are credentials**: never commit them, never paste them in chats, tickets or
  documents, never write them to logs.
- **Short lifetime**: use the shortest `--hours` value that works for your test. Tokens for the
  developers of the mobile app can last up to 168 hours (7 days), with a different `--sub` for
  each person.
- **A token can't be revoked on its own**: it stays valid until it expires. If a token leaks,
  tell whoever manages the infrastructure: the only way to invalidate it is to rotate the
  signing key, which invalidates every test token.
- **Never export the private key** from Key Vault: the script reads it only into a temporary
  folder.
- Use test identities (`--sub test-user-…` or the random default), never a real person's name.

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `mint-token.sh` fails with `Forbidden ... does not have secrets get permission` | no access to the Key Vault secrets | ask for access (see [Granting access](#granting-access)) |
| `mint-token.sh` asks to run `az login`, or fails with an `AADSTS` error | not signed in, or signed in to another tenant | `az login --tenant <tenant-id>` |
| `Failed to resolve '<key-vault>.vault.azure.net'` on macOS, while the name resolves with `dig` | stale entry in the macOS DNS cache | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| `401` with body `{ "statusCode": 401, "message": "Unauthorized" }` | API Management rejected the token: header missing, `Bearer ` prefix missing, token expired, or issuer, audience or `kid` different from the configuration | mint a new token; check `exp` by decoding it |
| `401` with an empty body | the Function App rejected the key sent by API Management | infrastructure issue: report it |
| `404` with body `{ "statusCode": 404, "message": "Resource not found" }` | API Management has no matching operation: the path is not under `/b2bapp/v1`, or the method isn't supported | check the URL and the method |
| `404` with an empty body | the Function App has no function for that route: code not deployed, or a different route or route prefix | check the route in the code and the last deployment |
| `429` | more than 20 requests in flight towards the Function App | retry after a short wait |
| Error after about 25 seconds | the function didn't respond within the API Management timeout | make the function faster, or process the work asynchronously |

## Granting access

*For whoever manages the Key Vault.* The vault uses the access policy model: reading the
signing key requires the `Get` permission on secrets.

```bash
# Check whether the user already has an access policy
az keyvault show --name <key-vault-name> --query "properties.accessPolicies[?objectId=='<object-id>'].permissions.secrets"

# No policy yet: add one with Get on secrets
az keyvault set-policy --name <key-vault-name> --object-id <object-id> --secret-permissions get
```

- `az keyvault set-policy` **replaces** the secret permissions of an existing policy: if the
  user already has one, include the permissions they already have.
- An access policy applies to **every secret** of the vault: whoever can mint test tokens can
  also read the other secrets. When that isn't acceptable, mint short-lived tokens
  (`--hours 1`) for them instead.

## After the switch to Entra External ID

- The mobile app gets tokens from the external tenant with MSAL; API Management validates them
  with the tenant's OpenID configuration. Test tokens are then **rejected**: the test signing
  key, the Key Vault secret, `tools/test-jwt/` and this guide are removed.
- Issuer and audience change, and the tokens carry more claims: `oid` and `tid` (user and
  tenant identifiers), `scp` (scopes granted to the app) and the optional claims configured on
  the app registration. `sub` becomes an identifier assigned by the tenant, unique per
  application.
- Read the user identifier in a single place of the code, so that the choice of the claim
  (`sub` or `oid`) can change without touching the business logic.
- If the code validates the token again as a defense in depth, keep issuer, audience and
  signing keys (or the OpenID configuration URL) in app settings, not in code.
- How developers get Entra tokens for their tests (for example a test account in the external
  tenant) will be defined together with the tenant.
