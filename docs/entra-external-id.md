# Switching production to Entra External ID

What to change in this repository, and in which order, once the external tenant and its app
registrations exist. Until then production rejects every request with 401
(`jwt_validation = null` in `workload/envs/prd.tfvars`).

Three changes, applied one after the other, each on dev first:

1. **Token validation**: API Management accepts the access tokens issued by the external tenant
   for the B2B API.
2. **Customer code from the token**: API Management forwards the customer code read from the
   validated token, never a value sent by the app.
3. **Sign-up webhook**: during sign-up, Entra calls an API that checks the submitted data in
   Salesforce.

## What Entra must provide

Whoever configures Entra creates the items below in the external tenant. Each value ends up in an
environment file of this repository or in the mobile app.

| Value | Where it comes from | Where it goes |
|---|---|---|
| Tenant ID and tenant subdomain (`<subdomain>.ciamlogin.com`) | the external tenant | `jwt_validation.openid_config_url` |
| Client ID of the API app registration | app registration that exposes the B2B API | `jwt_validation.audiences` |
| Scope names (for example `profile.read`) | the same app registration, **Expose an API** | scope check |
| Name of the customer code claim (for example `customer_code`) | custom user attribute mapped to a token claim | customer code policy |
| Client ID of the custom authentication extension app registration | created with the extension | webhook API policy |
| Client ID of the mobile app registration, authority `https://<subdomain>.ciamlogin.com/`, scopes `<Application ID URI of the API>/<scope>` | app registration of the mobile app | mobile app (not this repository) |

Settings that the API side depends on:

- **Access tokens in version 2**: `accessTokenAcceptedVersion = 2` in the manifest of the API app
  registration (and of the extension app registration). Version 2 tokens carry `aud` = client ID
  and `azp` = calling application; without it, validation against the tenant keys fails.
- **Customer code in the access token**: custom user attribute of type String, collected by the
  sign-up user flow, added as a claim in **Attributes & Claims** of the API application (source
  *Directory schema extension*, `b2c-extensions-app`), with `acceptMappedClaims = true` in its
  manifest. Check with a test user that the claim is in the **access token**, not only in the ID
  token.
- **Browser-delegated sign-in** in the mobile app (MSAL with the system browser): the sign-up
  webhook runs only on the Microsoft-hosted pages, not with native authentication.
- Microsoft recommends a **separate external tenant for test environments**: dev then validates
  the tokens of the test tenant, prd those of the production tenant.

References on Microsoft Learn: [external tenant overview](https://learn.microsoft.com/entra/external-id/customers/overview-customers-ciam),
[tokens and issuers](https://learn.microsoft.com/entra/identity-platform/security-tokens#token-endpoints-and-issuers),
[add user attributes to token claims](https://learn.microsoft.com/entra/external-id/customers/how-to-add-attributes-to-token),
[custom authentication extensions](https://learn.microsoft.com/entra/identity-platform/custom-extension-overview).

## 1. Token validation

In `workload/envs/<environment>.tfvars`:

```hcl
jwt_validation = {
  openid_config_url = "https://<subdomain>.ciamlogin.com/<tenant-id>/v2.0/.well-known/openid-configuration"
  audiences         = ["<API client ID>"]
  required_claims   = [{ name = "scp", values = ["<scope>"], match = "any", separator = " " }]
}
```

API Management reads the issuer and the signing keys from the configuration endpoint and
refreshes them every hour: nothing else changes when Entra rotates its keys.

Plan: the only change is an in-place update of `azurerm_api_management_policy.global`. Then apply.

**dev during the transition.** The developers need tokens for their tests. Until they have test
accounts in the external tenant, dev can accept both kinds of token: keep `signing_keys` next to
`openid_config_url`, and list both issuers and both audiences:

```hcl
jwt_validation = {
  openid_config_url = "https://<subdomain>.ciamlogin.com/<tenant-id>/v2.0/.well-known/openid-configuration"
  issuers           = ["https://<tenant-id>.ciamlogin.com/<tenant-id>/v2.0", "urn:b2bapp:test-issuer"]
  audiences         = ["<API client ID>", "api://b2bapp-test"]
  signing_keys      = [{ id = "test-1", n = "<modulus>" }]
}
```

Test tokens carry no `scp`, so dev keeps `required_claims` empty until the test tokens are
removed. Production never accepts test tokens.

### What the call looks like

| Item | Value |
|---|---|
| Method and body | `POST`, JSON with the event and the submitted attributes |
| Authentication | `Authorization: Bearer <token>` issued by the external tenant with client credentials |
| `aud` of the token | client ID of the extension app registration |
| `azp` of the token (`appid` in version 1 tokens) | `99045fe1-7639-4a75-9d4a-577b6ca3810f`: the Entra authentication events service |
| Response | HTTP 200, `Content-Type: application/json`, one action of type `microsoft.graph.attributeCollectionSubmit.*` |
| Time limit | at most 2 seconds, including the Salesforce lookup; at most one retry |
| Target URL and app registration | the Application ID URI of the extension app registration must be `api://<host of the target URL>/<its client ID>` |

Response schema and actions: [OnAttributeCollectionSubmit reference](https://learn.microsoft.com/entra/identity-platform/custom-extension-onattributecollectionsubmit-retrieve-return-data).

### Why the policies must change

The global policy accepts the audiences listed in `jwt_validation` for **every** API, and today
it also requires the `scp` scope. The webhook token has a different audience and no scope, so:

- the scope requirement moves from the global policy to the policy of the B2B API;
- the global policy accepts both audiences;
- each API checks that the token is meant for it. Without these checks, a token of the mobile
  app could call the webhook, and the webhook token could call the B2B API.

### Changes to the code

1. `envs/<environment>.tfvars`: add the extension client ID to `jwt_validation.audiences` and
   remove `required_claims`. Compare the `iss` of a real webhook token with the `issuer` of the
   OpenID configuration: if they differ, list both in `jwt_validation.issuers`.
2. `policies/api.xml.tftpl` (B2B API), after `<base />`: reject with 403 the tokens without the
   API audience or without the scope.

   ```xml
   <choose>
     <when condition="@(!((Jwt)context.Variables[&quot;jwt&quot;]).Audiences.Contains(&quot;${api_audience}&quot;) || !((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;scp&quot;, &quot;&quot;).Split(' ').Contains(&quot;${api_scope}&quot;))">
       <return-response>
         <set-status code="403" reason="Forbidden" />
       </return-response>
     </when>
   </choose>
   ```

3. A new API in `api.tf`, separate from the versioned B2B API (for example path `b2bapp-auth`,
   operation `POST /attribute-collection-submit`, HTTPS only, no subscription key), with the
   `func-api` backend and its own policy template. After `<base />`, the policy accepts only the
   Entra authentication events service and the extension audience:

   ```xml
   <choose>
     <when condition="@(((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, &quot;&quot;)) != &quot;99045fe1-7639-4a75-9d4a-577b6ca3810f&quot; || !((Jwt)context.Variables[&quot;jwt&quot;]).Audiences.Contains(&quot;${extension_audience}&quot;))">
       <return-response>
         <set-status code="403" reason="Forbidden" />
       </return-response>
     </when>
   </choose>
   ```

4. Template variables (`api_audience`, `api_scope`, `extension_audience`) declared in
   `variables.tf` and set in `envs/<environment>.tfvars`.
5. In the Function App, an HTTP function for the webhook (authorization level Function, like the
   others) that answers within the time limit: keep the Salesforce access token in cache and log
   the duration of the lookup.

The policies only need `<base />` first in every section, as described in `workload/README.md`.
Test the XML on dev: changes go through plan and apply, never through the portal.

### Response time

- prd runs on Elastic Premium with one instance always ready: no cold start.
- dev runs on Flex Consumption and scales to zero: while testing the webhook, set
  `function_always_ready_http_instances = 1` in `workload/envs/dev.tfvars`, otherwise the first
  sign-up after a pause can exceed the time limit.
- The 2 seconds include API Management. If the measured times are too close to the limit, the
  extension can call the Function App directly, protected by App Service authentication
  configured with the external tenant, as in the Microsoft guides.

Errors of the extension (timeout, invalid response) appear in the sign-in logs of the external
tenant, **Authentication Events** tab.

## Order and verification

For each step: dev, verify, then prd from the same commit (see `docs/making-changes.md`).

| Check | Expected result |
|---|---|
| Request without token | 401 |
| Token of another tenant, or expired | 401 |
| Valid token without the scope | 401 while the scope is checked in the global policy, 403 once the check moves to the API policy |
| Valid token without the customer code claim | 403 |
| Valid token of a test user | 200 with the data of that user's customer only |
| Webhook token on the B2B API, or mobile app token on the webhook API | 403 |
| Sign-up of a test user with valid data | the account is created |
| Sign-up with data not found in Salesforce | the validation error is shown and no account is created |

To close production again at any time: `jwt_validation = null` in `workload/envs/prd.tfvars`,
plan and apply. Every request then gets 401.

## Removing the test tokens

When no environment accepts test tokens any more:

1. remove `signing_keys`, the test issuer and the test audience from `workload/envs/dev.tfvars`,
   then plan and apply;
2. delete the `jwt-test-signing-key` secret from the Key Vault;
3. delete `tools/test-jwt/` and `docs/test-tokens.md`, and the references to them in the README
   files.
