# B2B App Integration: guida all'infrastruttura Azure

Guida passo per passo per lavorare sull'infrastruttura Azure della B2B App: accesso ad Azure,
configurazione di Terraform, verifica e modifica dell'infrastruttura, creazione di un ambiente,
token di test e chiamate alle API.

Tutti i comandi sono per una shell Bash e partono dalla radice del repository
dell'infrastruttura, salvo dove indicato. Riferimenti tecnici nel repository: `README.md`,
`platform/README.md`, `workload/README.md`, `docs/functions-developer-guide.md`,
`docs/test-tokens.md`.

**Indice**

1. Prerequisiti
2. Struttura e ambienti
3. Accesso ad Azure
4. Configurare Terraform
5. Modificare l'infrastruttura
6. Creare un ambiente
7. Token di test e chiamate alle API
8. Verifica guidata con lo script
9. Deploy di una Function
10. Problemi frequenti

---

## 1. Prerequisiti

### 1.1 Accessi

| Accesso | Serve per |
|---|---|
| Utenza nel tenant del progetto, con ruolo Contributor sul resource group `weu-ita-lms-rg-p` | accesso ad Azure, deploy delle Functions, token di test |
| Secret del service principal `sp-ita-clk-tf-p` (valido fino al 5/1/2027) | eseguire Terraform con l'identità tecnica |
| Access policy *Get* sui secret del Key Vault `weu-ita-lms-kv` | generare i token di test |

Con il solo secret del service principal si può lavorare con Terraform; i token di test
richiedono la propria utenza.

**Concedere l'accesso ai token di test.** Chi chiede l'accesso ricava il proprio object ID dopo
il login (§3):

```bash
az ad signed-in-user show --query id -o tsv
```

Chi gestisce l'infrastruttura controlla se per quell'ID esiste già un'access policy e, se non
c'è, la crea:

```bash
az keyvault show --name weu-ita-lms-kv \
  --query "properties.accessPolicies[?objectId=='<object-id>'].permissions.secrets"

az keyvault set-policy --name weu-ita-lms-kv --object-id <object-id> --secret-permissions get
```

`set-policy` su un'access policy esistente sostituisce i permessi sui secret: in quel caso vanno
indicati anche i permessi già presenti. Un'access policy vale per tutti i secret del vault.

### 1.2 Strumenti

| Strumento | Versione | Installazione |
|---|---|---|
| Terraform | 1.15 o successiva | developer.hashicorp.com/terraform/install |
| Azure CLI | recente | learn.microsoft.com/cli/azure/install-azure-cli |
| jq | qualsiasi | jqlang.org/download |
| OpenSSL, curl, git | qualsiasi | gestore di pacchetti del sistema |
| Azure Functions Core Tools (solo per il deploy, §9) | 4.x | learn.microsoft.com/azure/azure-functions/functions-run-local |

Controllo:

```bash
terraform version
az version
jq --version
openssl version
```

---

## 2. Struttura e ambienti

### 2.1 Cartelle

| Cartella | Contenuto |
|---|---|
| `bootstrap/` | script che crea lo storage dello state di Terraform e il container di un ambiente |
| `modules/` | moduli Terraform: Function App Flex, API Management, monitoraggio, identità |
| `platform/` | root con le fondamenta: Log Analytics, Application Insights, identità del codice, accessi al Key Vault, alert sul limite dei log |
| `workload/` | root con l'applicazione: API Management, API, policy, Function App e il suo storage, alert sugli errori 5xx |
| `tools/test-jwt/` | script per la chiave dei token di test e per generare i token |
| `docs/` | guide per lo sviluppo delle Functions e per i token di test |

Le root si applicano in quest'ordine: prima `platform`, poi `workload`, che legge per nome le
risorse di `platform`.

### 2.2 File degli ambienti

| File | Contenuto |
|---|---|
| `bootstrap/envs/<ambiente>.env` | tenant, subscription, resource group, storage dello state |
| `platform/envs/<ambiente>.tfvars`, `workload/envs/<ambiente>.tfvars` | variabili di Terraform dell'ambiente |
| `platform/envs/backend-<ambiente>.hcl`, `workload/envs/backend-<ambiente>.hcl` | posizione dello state: storage `sttfb2bappprdweu001`, container `tfstate-<ambiente>` |

| Ambiente | Uso | Token accettati |
|---|---|---|
| `dev` | sviluppo e test | token di test |
| `prd` | produzione | solo token di Entra External ID; fino ad allora ogni richiesta riceve 401 |

---

## 3. Accesso ad Azure

### 3.1 Login

```bash
AZURE_CORE_LOGIN_EXPERIENCE_V2=off az login --tenant 66984d9a-b5aa-41d9-9cf6-12cbc4d18e7b
```

- Si accede con la propria utenza nella pagina che si apre.
- Senza browser disponibile, aggiungi `--use-device-code`: Azure CLI mostra un indirizzo e un
  codice da inserire in una pagina web.
- `AZURE_CORE_LOGIN_EXPERIENCE_V2=off` disattiva, solo per questo comando, il selettore
  interattivo della subscription che Azure CLI mostra dopo il login dalla versione 2.61, come
  indicato da Microsoft per l'accesso a un tenant specifico.

### 3.2 Subscription del progetto

```bash
az account set --subscription 2fca6156-efd9-4da0-8ec1-ee5e8c7223e8
az account show --query "{utenza:user.name, subscription:name}" -o table
```

Atteso: la tua utenza e la subscription **Perfetti Van Melle ICT BV**.

---

## 4. Configurare Terraform

### 4.1 Identità

Tenant e subscription, in ogni caso:

```bash
export ARM_TENANT_ID=66984d9a-b5aa-41d9-9cf6-12cbc4d18e7b
export ARM_SUBSCRIPTION_ID=2fca6156-efd9-4da0-8ec1-ee5e8c7223e8
```

**Service principal** (consigliato):

```bash
export ARM_CLIENT_ID=e463738c-ca4b-4f13-a1ac-c928341f5fa5     # client ID dell'app, non l'ID del secret
read -rs ARM_CLIENT_SECRET && export ARM_CLIENT_SECRET         # incolla il secret e premi Invio
echo ${#ARM_CLIENT_SECRET}                                     # atteso: 40
```

`read -rs` non mostra il valore incollato. Le variabili valgono solo nel terminale corrente.

Verifica del secret:

```bash
printf '%s' "$ARM_CLIENT_SECRET" | curl -s "https://login.microsoftonline.com/$ARM_TENANT_ID/oauth2/v2.0/token" \
  -d grant_type=client_credentials -d client_id="$ARM_CLIENT_ID" --data-urlencode client_secret@- \
  -d scope=https://management.azure.com/.default | jq -r '.error_description // "OK: token ottenuto"'
```

**Utenza personale**: dopo il login della §3, senza `ARM_CLIENT_ID` e `ARM_CLIENT_SECRET`
(`unset ARM_CLIENT_ID ARM_CLIENT_SECRET`), Terraform usa l'accesso di Azure CLI.

### 4.2 Ambiente e state

Lo stesso valore di `ENV` vale per lo state e per le variabili:

```bash
ENV=dev      # oppure prd

terraform -chdir=platform init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform -chdir=workload init -reconfigure -backend-config=envs/backend-$ENV.hcl
```

- `init` scarica il provider `azurerm` e collega ogni root al proprio state
  (`platform.tfstate`, `workload.tfstate`) nel container `tfstate-$ENV`.
- `-reconfigure` cambia lo state collegato: va rieseguito a ogni cambio di ambiente.
- Lo storage dello state accetta solo autenticazione Entra: si usa l'identità della §4.1.

### 4.3 Plan

```bash
terraform -chdir=platform plan -var-file=envs/$ENV.tfvars
terraform -chdir=workload plan -var-file=envs/$ENV.tfvars
```

Atteso: `No changes. Your infrastructure matches the configuration.` per entrambe, cioè Azure
coincide con il codice.

| Simbolo nel plan | Significato |
|---|---|
| `+` | risorsa da creare |
| `~` | risorsa da modificare senza ricrearla |
| `-` | risorsa da distruggere |
| `-/+` | risorsa da distruggere e ricreare |

L'ultima riga riassume: `Plan: X to add, Y to change, Z to destroy.` Un plan che vuole
distruggere o sostituire risorse non toccate indica di solito che lo state collegato e il
tfvars appartengono ad ambienti diversi: si ripete la §4.2 con lo stesso `ENV`.

---

## 5. Modificare l'infrastruttura

### 5.1 Flusso

1. Modifica il codice o `<root>/envs/$ENV.tfvars`.
2. Salva il piano e leggilo:

   ```bash
   terraform -chdir=workload plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan
   ```

3. Applica il piano salvato, che esegue esattamente ciò che è stato letto:

   ```bash
   terraform -chdir=workload apply $ENV.tfplan
   ```

4. Rilancia il plan: atteso `No changes`.

Con modifiche su entrambe le root: prima `platform`, poi `workload`. Lo state ha un lock: con un
altro plan o apply in corso sullo stesso ambiente, Terraform attende o segnala
`Error acquiring the state lock`.

Impostazioni delle Functions e policy di API Management sono gestite da Terraform: ciò che si
modifica nel portale viene sovrascritto dal successivo apply.

### 5.2 Operazioni frequenti

**Impostazione della Function App.** In `workload/envs/$ENV.tfvars`:

```hcl
function_app_settings = {
  NOME_IMPOSTAZIONE = "valore"
}
```

Poi il flusso della §5.1 su `workload`.

**Segreto per le Functions.** Il valore va nel Key Vault, l'impostazione contiene il
riferimento.

1. Caricamento del valore, da un file senza ritorno a capo finale (`az keyvault secret set
   --file` salva il contenuto così com'è):

   ```bash
   tmp=$(mktemp)
   read -rs VALORE && printf '%s' "$VALORE" > "$tmp" && unset VALORE      # incolla il valore e premi Invio
   az keyvault secret set --vault-name weu-ita-lms-kv --name nome-segreto-$ENV --file "$tmp" --output none
   rm -f "$tmp"
   ```

2. Riferimento in `function_app_settings`:

   ```hcl
   NOME_SEGRETO = "@Microsoft.KeyVault(SecretUri=https://weu-ita-lms-kv.vault.azure.net/secrets/nome-segreto-dev)"
   ```

3. Flusso della §5.1 su `workload`. Il codice legge `NOME_SEGRETO` come variabile d'ambiente.
   Una nuova versione del secret viene letta entro 24 ore, o subito dopo una modifica della
   configurazione.

**Notifiche degli alert.**

1. In `platform/envs/$ENV.tfvars`: `alert_email_receivers = ["indirizzo@dominio.it"]`. Il flusso
   della §5.1 su `platform` crea l'action group `ag-b2bapp-$ENV-weu-001`, collegato all'alert sul
   limite giornaliero dei log.
2. In `workload/envs/$ENV.tfvars`: `alert_action_group_name = "ag-b2bapp-<ambiente>-weu-001"`. Il
   flusso della §5.1 su `workload` collega l'alert sugli errori 5xx.

**Istanza sempre attiva.** `function_always_ready_http_instances = 1` elimina l'attesa della
prima chiamata dopo un periodo di inattività, al costo di circa 21 $ al mese per un'istanza da
2048 MB.

**Timeout e concorrenza verso le Functions.** `api_backend_timeout_seconds` (1-29, oggi 25) e
`api_max_concurrency` (oggi 20) in `workload/envs/$ENV.tfvars`.

**Policy di API Management.** Template `workload/policies/global.xml.tftpl` (tutte le API) e
`workload/policies/api.xml.tftpl` (API `b2bapp-v1`). Nella policy dell'API i nuovi elementi vanno
dopo `<base />`, che resta il primo elemento di ogni sezione. Esempio completo in
`workload/README.md`, sezione "Customer code from the token".

**Rotazione della function key usata da API Management**, senza interruzioni:

```bash
RG=weu-ita-lms-rg-p; KV=weu-ita-lms-kv
APP=func-api-b2bapp-$ENV-weu-001; SECRET=apim-function-key-$ENV     # in prd: apim-function-key
tmp=$(mktemp)
az functionapp keys set -g "$RG" -n "$APP" --key-type functionKeys --key-name apim-2 --output none
az functionapp keys list -g "$RG" -n "$APP" --query '"functionKeys"."apim-2"' -o tsv | tr -d '\r\n' > "$tmp"
az keyvault secret set --vault-name "$KV" --name "$SECRET" --file "$tmp" --output none
rm -f "$tmp"
```

API Management legge la nuova versione entro 4 ore, o subito con "Refresh" sul named value
`func-api-key` nel portale. Poi:

```bash
az functionapp keys delete -g "$RG" -n "$APP" --key-type functionKeys --key-name apim
```

---

## 6. Creare un ambiente

Esempio con l'ambiente `tst`; `dev` e `prd` seguono la stessa procedura.

### 6.1 File dell'ambiente

```bash
cp bootstrap/envs/dev.env bootstrap/envs/tst.env
for root in platform workload; do
  cp $root/envs/dev.tfvars $root/envs/tst.tfvars
  sed 's/tfstate-dev/tfstate-tst/' $root/envs/backend-dev.hcl > $root/envs/backend-tst.hcl
done
```

Nei due `tst.tfvars`: `environment = "tst"`. In `workload/envs/tst.tfvars`:
`function_key_secret_name = null`; il blocco `jwt_validation` copiato da dev accetta i token di
test, `jwt_validation = null` risponde 401 a tutto.

### 6.2 Container dello state

Con la tua utenza (§3):

```bash
./bootstrap/bootstrap-state.sh tst
```

Lo script verifica il tenant, riallinea le impostazioni dello storage dello state e crea il
container `tfstate-tst`. La creazione del lock termina con un avviso: il ruolo Contributor non
la consente.

### 6.3 Root platform

```bash
ENV=tst
terraform -chdir=platform init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform -chdir=platform plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan     # atteso: 5 to add
terraform -chdir=platform apply $ENV.tfplan
```

Crea Log Analytics, Application Insights, identità del codice, alert sul limite dei log e
access policy dell'identità sul Key Vault.

### 6.4 Root workload, primo apply

```bash
terraform -chdir=workload init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform -chdir=workload plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan     # atteso: 21 to add
terraform -chdir=workload apply $ENV.tfplan
```

Crea Function App e storage, API Management (alcuni minuti), API, policy, accessi al Key Vault e
alert sui 5xx.

### 6.5 Chiave della Function nel Key Vault

```bash
RG=weu-ita-lms-rg-p; KV=weu-ita-lms-kv
APP=func-api-b2bapp-$ENV-weu-001; SECRET=apim-function-key-$ENV
tmp=$(mktemp)
az functionapp keys set -g "$RG" -n "$APP" --key-type functionKeys --key-name apim --output none
az functionapp keys list -g "$RG" -n "$APP" --query functionKeys.apim -o tsv | tr -d '\r\n' > "$tmp"
az keyvault secret set --vault-name "$KV" --name "$SECRET" --file "$tmp" --output none
rm -f "$tmp"
```

Controllo, le due lunghezze coincidono:

```bash
az functionapp keys list -g "$RG" -n "$APP" --query "length(functionKeys.apim)" -o tsv
az keyvault secret show --vault-name "$KV" --name "$SECRET" --query "length(value)" -o tsv
```

La chiave di firma dei token di test (`jwt-test-signing-key`) è condivisa dagli ambienti che
accettano i token di test.

### 6.6 Root workload, secondo apply

In `workload/envs/tst.tfvars`: `function_key_secret_name = "apim-function-key-tst"`.

```bash
terraform -chdir=workload plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan     # atteso: 1 to add, 1 to change
terraform -chdir=workload apply $ENV.tfplan
```

Crea il named value `func-api-key`, che legge la chiave dal Key Vault, e lo collega al backend.

### 6.7 Verifica

```bash
terraform -chdir=platform plan -var-file=envs/$ENV.tfvars      # No changes
terraform -chdir=workload plan -var-file=envs/$ENV.tfvars      # No changes
curl -i "$(terraform -chdir=workload output -raw api_base_url)/test"     # 401 da API Management
```

Con un token di test (§7) la richiesta arriva alla Function.

---

## 7. Token di test e chiamate alle API

Fino all'arrivo di Entra External ID, `dev` accetta token firmati con una chiave privata
conservata nel Key Vault. API Management li valida come quelli di Entra: firma, emittente,
audience e scadenza.

### 7.1 Accesso alla chiave

Con la tua utenza (§3):

```bash
az keyvault secret show --vault-name weu-ita-lms-kv --name jwt-test-signing-key --query id -o tsv
```

Stampa l'identificativo del secret se l'accesso c'è; `Forbidden` se manca l'access policy (§1.1).

### 7.2 Generare un token

```bash
TOKEN=$(bash tools/test-jwt/mint-token.sh --vault weu-ita-lms-kv --hours 1)
```

| Opzione | Predefinito | Uso |
|---|---|---|
| `--sub VALORE` | UUID casuale, diverso a ogni token | identificativo dell'utente; lo stesso valore simula lo stesso utente |
| `--claim NOME=VALORE` | nessuno | claim aggiuntivo, ripetibile: per esempio `--claim ruolo=tester` |
| `--hours N` | 8 | durata, da 1 a 168 ore |

Caratteri ammessi nei valori: lettere, cifre e `: / . _ @ -`. I claim standard (`iss`, `aud`,
`sub`, `iat`, `nbf`, `exp`) non si sostituiscono con `--claim`.

Esempio con identificativo e due claim:

```bash
TOKEN=$(bash tools/test-jwt/mint-token.sh --vault weu-ita-lms-kv --sub utente-a \
  --claim ruolo=tester --claim area=nord --hours 1)
```

Lo script legge la chiave privata dal Key Vault in una cartella temporanea, firma il token e
cancella la cartella.

### 7.3 Chiamare l'API

```bash
URL=https://apim-b2bapp-dev-weu-001.azure-api.net/b2bapp/v1

curl -i "$URL/<route>"                                       # senza token
curl -i -H "Authorization: Bearer $TOKEN" "$URL/<route>"     # con token
curl -i -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"campo":"valore"}' "$URL/<route>"
```

`/b2bapp/v1/<route>` arriva alla funzione con route `<route>` della Function App dello stesso
ambiente. Metodi: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`.

| Risposta | Da chi | Significato |
|---|---|---|
| 401 con `{"statusCode": 401, "message": "Unauthorized"}` | API Management | token mancante, scaduto o non accettato dall'ambiente |
| 404 con `{"statusCode": 404, "message": "Resource not found"}` | API Management | percorso fuori da `/b2bapp/v1` o metodo non supportato |
| 404 senza corpo | Function App | nessuna funzione per quella route |
| 401 senza corpo | Function App | chiave tra API Management e Function non coincidente |
| 429 | API Management | più di 20 richieste contemporanee verso la Function |
| 200 o altro codice | Function App | la richiesta è arrivata al codice |

La prima chiamata dopo un periodo di inattività è più lenta: la Function App parte da zero
istanze.

### 7.4 Client HTTP

Autorizzazione di tipo **Bearer Token** con il valore di `$TOKEN` (`echo "$TOKEN"`).

### 7.5 Leggere un token

```bash
jq -R 'split(".") | {header: (.[0] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson),
                     payload: (.[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson)}
       | .payload.iat |= todate | .payload.exp |= todate' <<< "$TOKEN"
```

### 7.6 Com'è fatto un JWT

Tre parti separate da punti: `<header>.<payload>.<firma>`. Header e payload sono JSON codificati
in **base64url** (base64 con `-` e `_` al posto di `+` e `/`, senza `=` finali): leggibili da
chiunque, non modificabili senza invalidare la firma.

| Parte | Contenuto nei token di test |
|---|---|
| Header | `{"alg":"RS256","typ":"JWT","kid":"test-1"}`: algoritmo di firma e identificativo della chiave |
| Payload | `iss` (`urn:b2bapp:test-issuer`), `aud` (`api://b2bapp-test`), `sub` (l'utente), `iat`/`nbf`/`exp` (emesso, valido da, scade; secondi dal 1/1/1970), più i claim aggiunti |
| Firma | RS256: hash SHA-256 di `header.payload`, firmato con la chiave privata RSA |

Controlli di API Management:

1. con `kid` sceglie la chiave pubblica (modulo `n` ed esponente `e`, in
   `jwt_validation.signing_keys`);
2. verifica la firma;
3. controlla `iss`, `aud`, `nbf` ed `exp`;
4. se tutto torna inoltra la richiesta con il token invariato, altrimenti risponde 401.

### 7.7 Comporre un JWT a mano

Gli stessi passi di `mint-token.sh`, con una chiave di prova locale: il token risultante è ben
formato ma API Management lo rifiuta, perché accetta solo la chiave del Key Vault.

```bash
openssl genrsa -out demo-private.pem 2048
openssl rsa -in demo-private.pem -pubout -out demo-public.pem

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

HEADER='{"alg":"RS256","typ":"JWT","kid":"test-1"}'
NOW=$(date +%s); EXP=$((NOW + 3600))
PAYLOAD=$(printf '{"iss":"urn:b2bapp:test-issuer","aud":"api://b2bapp-test","sub":"utente-a","ruolo":"tester","iat":%d,"nbf":%d,"exp":%d}' "$NOW" "$NOW" "$EXP")

H=$(printf '%s' "$HEADER" | b64url)
P=$(printf '%s' "$PAYLOAD" | b64url)
SIG=$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -sign demo-private.pem -binary | b64url)
DEMO_TOKEN="$H.$P.$SIG"
```

Verifica della firma con la chiave pubblica:

```bash
pad() { local s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; printf '%s' "$s"; }
printf '%s.%s' "$H" "$P" > signed-part.txt
pad "$SIG" | tr -- '-_' '+/' | openssl base64 -d -A > signature.bin
openssl dgst -sha256 -verify demo-public.pem -signature signature.bin signed-part.txt    # Verified OK
rm -f demo-private.pem demo-public.pem signed-part.txt signature.bin
```

### 7.8 Con Entra External ID

Stesso formato, con tre differenze:

- la firma è di Entra, con chiavi che API Management legge dalla configurazione OpenID del
  tenant e aggiorna da solo;
- `iss` e `aud` sono quelli del tenant e dell'API registrata;
- il payload contiene più claim, per esempio `oid`, `tid` e `scp`.

In Terraform cambia il blocco `jwt_validation`: procedura in `workload/README.md`, sezione
"Test tokens → Entra External ID".

---

## 8. Verifica guidata con lo script

`setup-b2bapp.sh` percorre le sezioni 3, 4 e 7 chiedendo conferme e scelte, senza modificare il
repository e senza eseguire `apply`.

```bash
bash setup-b2bapp.sh <cartella del repository>
```

Lanciato dalla radice del repository, l'argomento si può omettere. Invio conferma la risposta
predefinita, tra parentesi quadre.

| Passo | Cosa fa e cosa chiede |
|---|---|
| 1. Strumenti | controlla Terraform (1.15 o successivo), Azure CLI, jq, OpenSSL e curl |
| 2. Repository | lo individua, altrimenti chiede il percorso |
| 3. Accesso ad Azure | propone l'accesso già attivo; altrimenti chiede se accedere, nel browser o con un codice |
| 4. Identità di Terraform | service principal o utenza; con il service principal chiede il secret e lo verifica |
| 5. Plan | ambiente (dev o prd) e se eseguire `init` e `plan` delle due root |
| 6. Token di test | identificativo dell'utente (vuoto: generato), claim facoltativi nel formato `NOME=VALORE`, durata; poi chiama l'API e chiede se mostrare il token |

Risultato atteso su dev:

```
OK    platform: nessuna differenza tra codice e Azure
OK    workload: nessuna differenza tra codice e Azure
OK    accesso alla chiave dei token di test
OK    token generato: sub <identificativo>, valido 1 ora
OK    senza token: 401, API Management protegge l'API
OK    con token: 404 dalla Function, il token è accettato (la route di prova non esiste)
```

`OK` è a posto, `ATT` va letto, `KO` è un errore con la spiegazione sotto; i log completi sono
nella cartella indicata alla fine.

---

## 9. Deploy di una Function

Con la tua utenza (§3), dalla cartella del progetto delle Functions:

```bash
func azure functionapp publish func-api-b2bapp-dev-weu-001
```

- Piano Flex Consumption, runtime .NET 10 isolated: il deploy sostituisce l'intero pacchetto.
- Funzioni con `AuthorizationLevel.Function`: la chiave la aggiunge API Management.
- Prefisso delle route `api` (predefinito in `host.json`): API Management inoltra a
  `/api/<route>`.
- Dopo il deploy la chiamata con token (§7.3) risponde con il codice della funzione invece di
  404.

Configurazione, sviluppo in locale e rollback: `docs/functions-developer-guide.md`.

---

## 10. Problemi frequenti

| Sintomo | Causa | Soluzione |
|---|---|---|
| `no such host`, `Failed to resolve`, `Could not resolve host` | il DNS locale risponde a tratti con un errore sui nomi Azure | svuota la cache DNS del sistema e riprova; con errori frequenti usa DNS pubblici |
| `az login` non completa l'accesso | browser non disponibile o selettore della subscription | `AZURE_CORE_LOGIN_EXPERIENCE_V2=off` e, se serve, `--use-device-code` (§3.1) |
| La subscription del progetto non compare | utenza senza accesso al tenant o al resource group | verifica gli accessi (§1.1) |
| `AADSTS7000215: Invalid client secret` | usato l'ID del secret invece del valore, o caratteri in più | ricarica il valore; `echo ${#ARM_CLIENT_SECRET}` deve dare 40 |
| `Forbidden ... does not have secrets get permission` | manca l'access policy sul Key Vault | §1.1 |
| `Error acquiring the state lock` | un altro plan o apply in corso sullo stesso ambiente | attendi e riprova |
| Il plan vuole distruggere risorse non toccate | state e tfvars di ambienti diversi | §4.2 con lo stesso `ENV` |
| 401 con corpo JSON | token mancante, scaduto o non valido per l'ambiente | nuovo token; controlla `exp` (§7.5) |
| 401 senza corpo | chiave tra API Management e Function diversa | §6.5 o rotazione (§5.2) |
| 404 senza corpo | nessuna funzione per quella route | route e deploy (§9) |
| 403 | il token non ha un claim richiesto dal codice, o il dato non appartiene all'utente | aggiungi il claim (`--claim`) o usa il token giusto |
| Progetto .NET 10 non apribile | ambiente di sviluppo senza supporto a .NET 10 | Visual Studio 2026, oppure SDK .NET 10 con VS Code o riga di comando |
