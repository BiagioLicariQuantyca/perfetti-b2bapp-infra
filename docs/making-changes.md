# Making changes to the infrastructure

What to run after changing a file of this repository: which root, for which environment, in
which order. Authentication and permissions are described in the main README.

## Environments

The code is the same for every environment; the values are not. Each root (`platform`,
`workload`) has two files per environment in its `envs/` folder:

| File | Content |
|---|---|
| `envs/<environment>.tfvars` | the values of the environment: names, sizes, settings |
| `envs/backend-<environment>.hcl` | where its state is: the `tfstate-<environment>` container |

A run works on one environment at a time, chosen with `ENV`, which selects both files:

```bash
ENV=dev    # or prd
terraform init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan
```

Run `init -reconfigure` every time you change `ENV` or folder. With the backend of one
environment and the values of the other, the plan would replace the resources of the first with
those of the second.

What differs between dev and prd today:

| Setting | dev | prd |
|---|---|---|
| Function App (`function_hosting`) | `flex`: Flex Consumption, scales to zero | `premium`: Elastic Premium `EP1`, one instance always ready |
| Bearer tokens (`jwt_validation`) | test tokens | `null`: every request gets 401 until Entra External ID |
| Function key secret (`function_key_secret_name`) | `apim-function-key-dev` | `apim-function-key` |

Everything else, `platform` included, has the same values with the environment in the names.

**dev first, then prd.** A change that applies to every environment is planned and applied on
dev, verified, and only then planned and applied on prd, from the same commit.

## Which root to run

| Changed file | Root to plan and apply | Environments |
|---|---|---|
| `platform/*.tf` | `platform` | all: dev, then prd |
| `platform/envs/<environment>.tfvars` | `platform` | that environment only |
| `workload/*.tf`, `workload/policies/*` | `workload` | all: dev, then prd |
| `workload/envs/<environment>.tfvars` | `workload` | that environment only |
| `modules/<module>/*` | the roots that use the module (below) | all: dev, then prd |
| `<root>/envs/backend-<environment>.hcl` | none: it only says where the state is; change it only to move the state | – |
| `bootstrap/*` | none: the script runs once, when an environment is created | – |
| `tools/*`, `docs/*`, `README.md` files | none | – |

| Module | Used by |
|---|---|
| `log-analytics-workspace`, `application-insights`, `user-assigned-identity` | `platform` |
| `api-management`, `function-app-flex`, `function-app-premium` | `workload` |

A module may be used only in some environments: `function-app-flex` only where
`function_hosting = "flex"`, `function-app-premium` only where it is `"premium"`. Plan every
environment anyway: where the module isn't used, the expected result is **No changes**.

**Both roots changed:** `platform` first, then `workload`, because `workload` reads the
`platform` resources by name. When removing a `platform` resource that `workload` uses, the
order is reversed: first remove its use from `workload`, then the resource.

## Steps

1. Check the code, from the root folder:

   ```bash
   terraform fmt -recursive ..
   terraform init -reconfigure -backend-config=envs/backend-$ENV.hcl
   terraform validate
   ```

2. Plan and save the plan:

   ```bash
   terraform plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan
   ```

3. Read the plan (next section). If it contains anything you don't expect, don't apply.
4. Apply exactly the saved plan:

   ```bash
   terraform apply $ENV.tfplan
   ```

5. Verify: on dev, call the API with a test token (`docs/test-tokens.md`); on prd, check the
   resources in the portal and the responses of the API.
6. Repeat from step 1 with `ENV=prd`, when the change applies to every environment.

## Reading the plan

The last line sums it up: `Plan: X to add, Y to change, Z to destroy`. Each resource is marked:

| Symbol | Meaning | Attention |
|---|---|---|
| `+` | create | |
| `~` | update in place | |
| `-` | destroy | data and configuration of the resource are lost |
| `-/+` or `must be replaced` | destroy and create again | new identifiers and keys, the resource is unavailable in between |
| `<=` | read a data source | nothing changes in Azure |

Stop and look for the cause when:

- a destroy or a replace that the change doesn't explain appears: the line `# forces replacement`
  shows which attribute causes it;
- resource names belong to another environment: backend and values don't match, run `init
  -reconfigure` again;
- changes appear that nobody made in the code: someone changed the resource from the portal or the
  CLI. Either bring the change into the code, or let the apply restore the code values;
- in an environment the change doesn't target, anything other than **No changes** appears.

Changes to outputs only (`Changes to Outputs`) touch nothing in Azure: the apply just saves them in
the state.

## Errors during plan and apply

| Message | Cause | What to do |
|---|---|---|
| `Error acquiring the state lock` | another plan or apply on the same root and environment | wait for it to finish. Only if the run was interrupted and nobody else is working: `terraform force-unlock <lock ID>` |
| `Saved plan is stale` | the state changed after the plan | plan again |
| `Backend initialization required` or `Module not installed` | new module, new provider or new folder | `terraform init -reconfigure -backend-config=envs/backend-$ENV.hcl` |
| `403` on the state storage account | the identity lacks `Storage Blob Data Contributor` on the state account | see Prerequisites in the main README |
| `no such host`, `dial tcp` | name resolution or network | run again; check the DNS of the network in use |

## What doesn't go through Terraform

- **Secret values**: written to Key Vault with `az keyvault secret set` and referenced in the app
  settings (`workload/README.md`, Common operations).
- **Function keys**: created with `az functionapp keys set` and stored in Key Vault.
- **Function code**: deployed with Core Tools or the Azure CLI (`docs/functions-developer-guide.md`).
  Plan and apply don't touch the deployed code.

Changes made from the portal to resources managed by Terraform are overwritten at the next apply.

## Commit and apply

Apply from committed code: the state then always matches the repository. Commit code and
environment files together; plan files, state and `.terraform` folders are excluded by
`.gitignore`. Secrets never go into the repository.

## Examples

| Change | Files | Runs |
|---|---|---|
| Add an app setting in prd | `workload/envs/prd.tfvars` | `workload` prd |
| Change the API policy | `workload/policies/api.xml.tftpl` | `workload` dev, test, `workload` prd |
| Change the log retention everywhere | `platform/envs/dev.tfvars`, `platform/envs/prd.tfvars` | `platform` dev, `platform` prd |
| Change the Flex Consumption module | `modules/function-app-flex/*` | `workload` dev (changes), `workload` prd (No changes) |
| Resize the Premium plan | `function_premium` in `workload/envs/prd.tfvars` | `workload` prd: update in place |
| Change the hosting plan of an environment | `function_hosting` in `workload/envs/<environment>.tfvars` | `workload` for that environment, following "Change the hosting plan" in `workload/README.md` |
| Add an environment | new files in `bootstrap/envs/` and in the `envs/` folders | "Adding an environment" in the main README |
