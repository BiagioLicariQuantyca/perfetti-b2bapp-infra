# B2B App Integration – Azure infrastructure

Terraform code for the Azure infrastructure that exposes the APIs used by the B2B mobile app to
read and update business partner data in Salesforce CRM.

## Architecture

```
B2B mobile app ──HTTPS + Bearer token──> API Management ──> Azure Functions (.NET isolated) ──> Salesforce CRM
      │                                        │                    │
      └──OAuth 2.0 / OIDC sign-in──> Entra External ID              ├──> Key Vault (backend credentials)
                                               │                    │
                                               └──────> Application Insights / Log Analytics
```

| Component | Role | Where it is defined |
|---|---|---|
| State storage | Terraform state of every root | `bootstrap/` (Azure CLI script) |
| Log Analytics, Application Insights, alerts | observability of the solution | `platform/` |
| Functions managed identity and its Key Vault access | application identity | `platform/` |
| API Management, Function App and its storage, API definition | API exposure and business logic | `workload/` |
| Test bearer tokens (until Entra External ID is available) | temporary authentication for tests | `tools/test-jwt/` |
| Key Vault, resource group | existing containers | platform team, read through data sources |
| Entra External ID | identity of the business partners | outside this repository |

All resources live in the subscription and resource group of the solution, in West Europe, and
communicate over the public network with Entra ID authentication.

## Repository layout

```
bootstrap/        script that creates the state storage (see bootstrap/README.md)
modules/          local Terraform modules, secure by default (see modules/README.md)
platform/         Terraform root with the shared foundations (see platform/README.md)
workload/         Terraform root with Function App, API Management and the API (see workload/README.md)
tools/test-jwt/   temporary tools to mint test bearer tokens (see tools/test-jwt/README.md)
docs/             guides for the developers of the Functions (development, test tokens)
```

The roots are applied in this order: `bootstrap` (once), `platform`, `workload`.

Each root has its own state (`<root>.tfstate`) in the `tfstate-<environment>` container and
reads the resources of other roots by name, through data sources. Roots can therefore be planned
and applied independently.

## Environment configuration

Environment-specific values live only in the `envs/` folders:

| File | Content |
|---|---|
| `bootstrap/envs/<environment>.env` | tenant, subscription, resource group, state storage account |
| `<root>/envs/<environment>.tfvars` | subscription, resource group, environment, Key Vault and the settings of each root |
| `<root>/envs/backend-<environment>.hcl` | location of the state |

These files contain identifiers and resource names only: credentials and secrets never go into
the repository. Declaring the subscription in the `.tfvars` file is also a safeguard: Terraform
works on that subscription even if the CLI points elsewhere.

## Conventions

- **Naming**: Cloud Adoption Framework scheme `<type>[-<purpose>]-<workload>-<environment>-<region>-<instance>`,
  for example `log-b2bapp-prd-weu-001` or `func-api-b2bapp-prd-weu-001`. Storage accounts, which
  do not allow hyphens, use the compact form `st<purpose><workload><environment><region><instance>`,
  for example `stapib2bappprdweu001`.
- **Tags**: every resource inherits the company tags of the resource group, read at every plan.
  The root overrides only `description`.
- **Secrets**: secret values never go through Terraform, because they would be stored in clear
  text in the state. They are written directly to the Key Vault.
- **Identity**: no credentials in code. Terraform uses the identity of the environment it runs
  in, and the code never grants permissions to the identity that runs it.
- **Versions**: Terraform `>= 1.15, < 2.0`, `azurerm` provider `~> 5.8`. The
  `.terraform.lock.hcl` file is versioned and contains the hashes for macOS, Linux and Windows.

## Prerequisites

- Terraform 1.15 or later, Azure CLI, `jq` (for the bootstrap).
- Permissions of the identity that runs Terraform:

| Permission | Scope | Needed for |
|---|---|---|
| `Contributor` | resource group of the solution | creating resources and Key Vault access policies |
| `Storage Blob Data Contributor` | state storage account | reading and writing the state |

The code creates neither role assignments nor resource locks: they would require
`Microsoft.Authorization/roleAssignments/write` and `Microsoft.Authorization/locks/write`, which
Contributor does not include.

## Authentication

**With a personal account:**

```bash
# Dedicated CLI profile, useful when working on several tenants
export AZURE_CONFIG_DIR="$HOME/.azure-b2bapp"
az login --tenant <tenant-id>

export ARM_TENANT_ID=<tenant-id>
export ARM_SUBSCRIPTION_ID=<subscription-id>
```

The tenant and subscription IDs of each environment are in `bootstrap/envs/<environment>.env`.

**With a service principal**, for example from a pipeline, the code does not change: set the
provider environment variables.
- With a certificate: `ARM_CLIENT_ID`, `ARM_CLIENT_CERTIFICATE_PATH` and
  `ARM_CLIENT_CERTIFICATE_PASSWORD`.
- With a federated credential (OIDC): `ARM_USE_OIDC=true` plus the variables required by the
  CI/CD platform.

The backend uses the same identity.

## Environments

| Environment | Purpose | Notes |
|---|---|---|
| `dev` | development and tests, by the team and by the developers of the mobile app | test tokens; Salesforce sandbox |
| `prd` | production | |

All environments live in the same resource group and use the same Key Vault. Secrets of a
single environment end with its name (for example `salesforce-client-secret-dev` or
`apim-function-key-dev`); the production function key is `apim-function-key`, and the test
signing key `jwt-test-signing-key` is shared by the environments that accept test tokens. Each
environment has its own
state container (`tfstate-<environment>`) in the same state storage account, and its own
resources: names include the environment, for example `apim-b2bapp-dev-weu-001`.

## Usage

Set the environment once and use it for both the backend and the variables, so that they always
match:

```bash
ENV=dev   # or prd
```

**1. State storage**: once per environment.

```bash
./bootstrap/bootstrap-state.sh $ENV
```

**2. `platform` root.**

```bash
cd platform
terraform init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan
terraform apply $ENV.tfplan
```

**3. `workload` root**: same commands from the `workload` folder. The first deployment needs two
applies with manual steps in between (function key and test signing key): see
`workload/README.md`.

Always apply the plan saved with `-out`, after reviewing it: this way exactly what was reviewed
gets applied. State locking is automatic.

> `-reconfigure` switches the folder to the state of `$ENV`. If a plan wants to destroy or replace
> resources of another environment, the backend and the variable file don't match: stop and run
> `terraform init` again.

## Adding an environment

For example `tst`:

1. Create `bootstrap/envs/tst.env` and run `./bootstrap/bootstrap-state.sh tst`, which creates
   the `tfstate-tst` container.
2. In each root, create `envs/tst.tfvars` (with `environment = "tst"`) and
   `envs/backend-tst.hcl` (with `container_name = "tfstate-tst"`).
3. With `ENV=tst`, run the commands of the Usage section.

Resource names include the environment, so different environments can coexist in the same
resource group. A dedicated resource group per environment is still the cleanest separation.

## Updating the provider

In each root (`platform`, `workload`):

```bash
terraform init -upgrade
terraform providers lock -platform=darwin_arm64 -platform=darwin_amd64 \
  -platform=linux_amd64 -platform=linux_arm64 -platform=windows_amd64
```
