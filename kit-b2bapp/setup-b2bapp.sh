#!/usr/bin/env bash
# B2B App Integration: verifica guidata della postazione di lavoro.
#
# Uso:
#   bash setup-b2bapp.sh [cartella del repository]
#
# Ogni passo chiede conferma o una scelta:
#   1. strumenti: terraform 1.15 o successivo, az, jq, openssl, curl
#   2. repository: la copia locale, senza clonare né aggiornare
#   3. accesso ad Azure con Azure CLI, sul tenant e sulla subscription del progetto
#   4. identità di Terraform: service principal oppure la propria utenza
#   5. terraform init e plan, in sola lettura, su dev o prd
#   6. token di test e chiamate all'API
#
# Non esegue terraform apply, non modifica il repository, non cambia la configurazione di Azure
# CLI e non salva segreti: il secret del service principal resta in memoria solo durante
# l'esecuzione.

set -uo pipefail

TENANT_ID="66984d9a-b5aa-41d9-9cf6-12cbc4d18e7b"
SUBSCRIPTION_ID="2fca6156-efd9-4da0-8ec1-ee5e8c7223e8"
SP_CLIENT_ID="e463738c-ca4b-4f13-a1ac-c928341f5fa5"    # client ID di sp-ita-clk-tf-p
KEY_VAULT="weu-ita-lms-kv"
SIGNING_SECRET="jwt-test-signing-key"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b2bapp-setup.XXXXXX")"
RESULTS=()
USER_OK=0           # 1 quando Azure CLI ha un accesso valido alla subscription del progetto
TF_AUTH=""          # sp | user
ENV_NAME=""         # dev | prd

# --- Output -------------------------------------------------------------------------------------
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; RESULTS+=("OK    $*"); }
warn() { printf '  \033[33mATT\033[0m  %s\n' "$*"; RESULTS+=("ATT   $*"); }
fail() { printf '  \033[31mKO\033[0m   %s\n' "$*"; RESULTS+=("KO    $*"); }
info() { printf '       %s\n' "$*"; }
net_hint() { info "Se l'errore riguarda la risoluzione dei nomi o la rete, svuota la cache DNS e riprova (GUIDA, Problemi frequenti)."; }
summary() {
  step "Riepilogo"
  local r; for r in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "  $r"; done
  echo; echo "  Log completi: $LOG_DIR"
}
trap summary EXIT

# --- Input --------------------------------------------------------------------------------------
# Legge una riga; termina se l'input non è disponibile.
read_line() {
  local prompt="$1"
  if ! IFS= read -r -p "  ? $prompt" REPLY; then echo; echo "Input non disponibile: interrotto." >&2; exit 1; fi
}

# Domanda sì/no. $2 = risposta predefinita (s o n). Ritorna 0 per sì.
ask_yes_no() {
  local question="$1" default="$2" hint
  [[ "$default" == "s" ]] && hint="[S/n]" || hint="[s/N]"
  while true; do
    read_line "$question $hint "
    case "$(printf '%s' "${REPLY:-$default}" | tr '[:upper:]' '[:lower:]')" in
      s|si|sì|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) info "Rispondi s oppure n." ;;
    esac
  done
}

# Scelta numerata: imposta CHOICE al numero scelto (1 è la predefinita).
choose() {
  local question="$1"; shift
  local i=1 option
  echo "  ? $question"
  for option in "$@"; do printf '      %d) %s\n' "$i" "$option"; i=$((i + 1)); done
  while true; do
    read_line "scelta [1]: "
    CHOICE="${REPLY:-1}"
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= $# )) && return 0
    info "Scegli un numero da 1 a $#."
  done
}

# Valore libero con predefinito: imposta VALUE.
ask_value() {
  local question="$1" default="$2"
  read_line "$question${default:+ [$default]}: "
  VALUE="${REPLY:-$default}"
}

# Azure CLI: output senza ritorni a capo \r, solo errori su stderr.
azq() { az "$@" --only-show-errors 2>&1 | tr -d '\r'; }

# Codice HTTP di una chiamata, con nuovi tentativi se non arriva risposta.
http_code() {
  local code attempt
  for attempt in 1 2 3; do
    code="$(curl -s -m 60 -w '%{http_code}' "$@")"
    [[ "$code" != "000" ]] && break
    sleep 5
  done
  echo "$code"
}

# ================================================================================================
step "1. Strumenti"
missing=0
for tool in terraform az jq openssl curl; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else fail "$tool non trovato"; missing=1; fi
done
if [[ $missing -eq 1 ]]; then
  info "Installa gli strumenti mancanti (GUIDA, Prerequisiti), riapri il terminale e rilancia."
  exit 1
fi
tf_version="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null)"
if [[ "$tf_version" =~ ^([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 15) )); then
  ok "terraform $tf_version"
else
  fail "terraform ${tf_version:-sconosciuto}: serve la versione 1.15 o successiva"
  exit 1
fi

# ================================================================================================
step "2. Repository"
# Una cartella è il repository se contiene le due root e gli script dei token di test.
is_repo() { [[ -f "$1/platform/terraform.tf" && -f "$1/workload/terraform.tf" && -f "$1/tools/test-jwt/mint-token.sh" ]]; }
DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  if is_repo "."; then DIR="."; elif is_repo "./perfetti-b2bapp-infra"; then DIR="./perfetti-b2bapp-infra"; fi
fi
while [[ -z "$DIR" ]] || ! is_repo "$DIR"; do
  [[ -n "$DIR" ]] && warn "$DIR non è il repository dell'infrastruttura"
  ask_value "Percorso della copia locale del repository (vuoto per uscire)" ""
  [[ -z "$VALUE" ]] && exit 1
  DIR="$VALUE"
done
DIR="$(cd "$DIR" && pwd)"
ok "repository: $DIR"
if command -v git >/dev/null 2>&1 && git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  info "commit: $(git -C "$DIR" log -1 --format='%h %s' 2>/dev/null)"
  [[ -z "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]] || info "ci sono modifiche locali: il plan le include"
fi

# ================================================================================================
step "3. Accesso ad Azure con Azure CLI"
sub_name() { azq account show --subscription "$SUBSCRIPTION_ID" --query name -o tsv; }

current_name="$(sub_name)"
if [[ $? -eq 0 && -n "$current_name" ]]; then
  current_user="$(azq account show --subscription "$SUBSCRIPTION_ID" --query user.name -o tsv)"
  info "Accesso attivo: $current_user, subscription \"$current_name\"."
  ask_yes_no "Usare questo accesso?" s && USER_OK=1
fi

while [[ $USER_OK -eq 0 ]]; do
  if ! ask_yes_no "Accedere ora ad Azure con la tua utenza? (serve per il token di test e per Terraform senza service principal)" s; then
    warn "nessun accesso con la tua utenza: Terraform userà il service principal, token di test saltato"
    break
  fi
  choose "Come vuoi accedere?" "nel browser" "con un codice da inserire in una pagina web (se il browser non si apre)"
  # Senza --only-show-errors: il codice di accesso e l'indirizzo arrivano come avvisi di az.
  login_args=(login --tenant "$TENANT_ID" --output none)
  [[ "$CHOICE" == "2" ]] && login_args+=(--use-device-code)
  # Il selettore interattivo della subscription di az login è disattivato solo per questo comando.
  if AZURE_CORE_LOGIN_EXPERIENCE_V2=off az "${login_args[@]}"; then
    current_name="$(sub_name)"
    if [[ $? -eq 0 && -n "$current_name" ]]; then
      USER_OK=1
    else
      fail "accesso riuscito, ma la tua utenza non vede la subscription del progetto"
      info "Servono l'accesso al tenant e il ruolo sul resource group del progetto."
      break
    fi
  else
    fail "accesso non riuscito"
    net_hint
  fi
done
if [[ $USER_OK -eq 1 ]]; then
  ok "utenza: $(azq account show --subscription "$SUBSCRIPTION_ID" --query user.name -o tsv), subscription \"$current_name\""
fi

# ================================================================================================
step "4. Identità di Terraform"
export ARM_TENANT_ID="$TENANT_ID" ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

# Verifica il secret ottenendo un token per Azure Resource Manager con il flusso client credentials.
sp_check() {
  local response
  response="$(printf '%s' "$ARM_CLIENT_SECRET" | curl -s "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
    -d grant_type=client_credentials -d client_id="$SP_CLIENT_ID" --data-urlencode client_secret@- \
    -d scope=https://management.azure.com/.default)"
  if jq -e '.access_token' >/dev/null 2>&1 <<< "$response"; then return 0; fi
  fail "service principal non autenticato: $(jq -r '.error_description // "nessuna risposta"' <<< "$response" 2>/dev/null | head -1 | cut -c1-160)"
  return 1
}

if [[ $USER_OK -eq 1 ]]; then
  choose "Con quale identità deve lavorare Terraform?" "service principal sp-ita-clk-tf-p (consigliato)" "la tua utenza di Azure CLI"
  [[ "$CHOICE" == "1" ]] && TF_AUTH="sp" || TF_AUTH="user"
else
  TF_AUTH="sp"
fi

while [[ "$TF_AUTH" == "sp" ]]; do
  export ARM_CLIENT_ID="$SP_CLIENT_ID"
  info "Incolla il secret del service principal (dal password manager) e premi Invio."
  info "Non viene mostrato e non viene salvato."
  if ! IFS= read -rs -p "  ? secret: " ARM_CLIENT_SECRET; then echo; exit 1; fi
  echo
  ARM_CLIENT_SECRET="$(printf '%s' "$ARM_CLIENT_SECRET" | tr -d '\r\n ')"
  export ARM_CLIENT_SECRET
  [[ ${#ARM_CLIENT_SECRET} -eq 40 ]] || warn "il secret ha ${#ARM_CLIENT_SECRET} caratteri invece di 40: va copiato il valore, non l'ID"
  if sp_check; then
    ok "Terraform usa il service principal"
    break
  fi
  if [[ $USER_OK -eq 1 ]]; then
    choose "Come procedere?" "riprovare con il secret" "usare la tua utenza" "uscire"
    case "$CHOICE" in 2) TF_AUTH="user" ;; 3) exit 1 ;; esac
  else
    choose "Come procedere?" "riprovare con il secret" "uscire"
    [[ "$CHOICE" == "2" ]] && exit 1
  fi
done
if [[ "$TF_AUTH" == "user" ]]; then
  unset ARM_CLIENT_ID ARM_CLIENT_SECRET
  ok "Terraform usa la tua utenza di Azure CLI"
fi

# ================================================================================================
step "5. Terraform: init e plan in sola lettura"
choose "Su quale ambiente?" "dev" "prd"
[[ "$CHOICE" == "1" ]] && ENV_NAME="dev" || ENV_NAME="prd"
for f in "platform/envs/$ENV_NAME.tfvars" "platform/envs/backend-$ENV_NAME.hcl" "workload/envs/$ENV_NAME.tfvars" "workload/envs/backend-$ENV_NAME.hcl"; do
  [[ -f "$DIR/$f" ]] || { fail "manca $f"; exit 1; }
done

if ask_yes_no "Eseguire terraform init e plan di platform e workload su $ENV_NAME?" s; then
  for root in platform workload; do
    log="$LOG_DIR/$root-$ENV_NAME.log"
    info "$root: init e plan in corso..."
    if ! terraform -chdir="$DIR/$root" init -input=false -no-color -reconfigure \
         -backend-config="envs/backend-$ENV_NAME.hcl" >"$log" 2>&1; then
      fail "$root: init non riuscito"; grep -m3 -E 'Error|error' "$log" | cut -c1-200 | sed 's/^/       /'; net_hint; continue
    fi
    terraform -chdir="$DIR/$root" plan -input=false -no-color -lock-timeout=120s \
      -var-file="envs/$ENV_NAME.tfvars" -detailed-exitcode >>"$log" 2>&1
    case $? in
      0) ok "$root: nessuna differenza tra codice e Azure" ;;
      2) warn "$root: il plan propone modifiche ($(grep -m1 '^Plan:' "$log")); il dettaglio è nel log" ;;
      *) fail "$root: plan non riuscito"; grep -m3 -E 'Error|error' "$log" | cut -c1-200 | sed 's/^/       /'; net_hint ;;
    esac
  done
  info "Le cartelle platform e workload ora puntano allo state di $ENV_NAME."
else
  warn "plan saltato"
fi

# ================================================================================================
step "6. Token di test e chiamate all'API di $ENV_NAME"
if [[ $USER_OK -eq 0 ]]; then
  warn "token saltato: serve l'accesso con la tua utenza (passo 3)"
  exit 0
fi
[[ "$ENV_NAME" == "prd" ]] && info "Su prd i token di test devono essere rifiutati: la verifica attesa è 401."
if ! ask_yes_no "Generare un token di test e chiamare l'API?" s; then
  warn "token saltato"
  exit 0
fi

# Identificativo dell'utente (claim sub): vuoto = generato da mint-token.sh come UUID casuale.
SUB=""
while true; do
  ask_value "Identificativo dell'utente (sub), vuoto per generarlo" ""
  [[ -z "$VALUE" || "$VALUE" =~ ^[A-Za-z0-9:/._@-]+$ ]] && { SUB="$VALUE"; break; }
  info "Caratteri ammessi: lettere, cifre e : / . _ @ -"
done

# Claim aggiuntivi nel formato NOME=VALORE, passati a mint-token.sh con --claim.
claim_args=()
claim_list=()
if ask_yes_no "Aggiungere claim al token? (formato NOME=VALORE, per esempio ruolo=tester)" n; then
  while true; do
    ask_value "Claim NOME=VALORE, vuoto per terminare" ""
    [[ -z "$VALUE" ]] && break
    name="${VALUE%%=*}"; value="${VALUE#*=}"
    if [[ "$VALUE" != *=* || ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ || ! "$value" =~ ^[A-Za-z0-9:/._@-]+$ ]]; then
      info "Formato NOME=VALORE: il nome inizia con una lettera o _, il valore usa lettere, cifre e : / . _ @ -"
      continue
    fi
    case "$name" in
      iss|aud|sub|iat|nbf|exp|kid|alg|typ) info "$name è un claim standard e non si può sostituire."; continue ;;
    esac
    claim_args+=(--claim "$VALUE")
    claim_list+=("$VALUE")
    info "aggiunto: $VALUE"
  done
fi

while true; do
  ask_value "durata in ore, da 1 a 168" "1"
  [[ "$VALUE" =~ ^[0-9]+$ ]] && (( VALUE >= 1 && VALUE <= 168 )) && { HOURS="$VALUE"; break; }
  info "Inserisci un numero da 1 a 168."
done

kv_out=""
for attempt in 1 2 3; do
  kv_out="$(azq keyvault secret show --vault-name "$KEY_VAULT" --name "$SIGNING_SECRET" --query id -o tsv)"
  [[ "$kv_out" == https://* ]] && break
  grep -qiE 'resolve|name or service' <<< "$kv_out" && sleep 5 || break
done
if [[ "$kv_out" != https://* ]]; then
  if grep -qi 'forbidden' <<< "$kv_out"; then
    fail "la tua utenza non può leggere i secret di $KEY_VAULT"
    info "Chiedi un'access policy Get sui secret indicando il tuo object ID:"
    info "  $(azq ad signed-in-user show --query id -o tsv)"
  else
    fail "Key Vault non raggiungibile: $(head -1 <<< "$kv_out" | cut -c1-160)"
    net_hint
  fi
  exit 1
fi
ok "accesso alla chiave dei token di test"

sub_args=()
[[ -n "$SUB" ]] && sub_args=(--sub "$SUB")
TOKEN="$(bash "$DIR/tools/test-jwt/mint-token.sh" --vault "$KEY_VAULT" --hours "$HOURS" \
  ${sub_args[@]+"${sub_args[@]}"} ${claim_args[@]+"${claim_args[@]}"} 2>"$LOG_DIR/token.log")"
if [[ -z "$TOKEN" ]]; then
  fail "token non generato (dettaglio in $LOG_DIR/token.log)"
  exit 1
fi
# Il sub effettivo si legge dal payload del token (base64url).
token_sub="$(jq -rR 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | .sub' <<< "$TOKEN" 2>/dev/null)"
hours_label="$HOURS ore"; [[ "$HOURS" == "1" ]] && hours_label="1 ora"
claims_label=""
(( ${#claim_list[@]} > 0 )) && claims_label=", claim ${claim_list[*]}"
ok "token generato: sub ${token_sub:-sconosciuto}${claims_label}, valido $hours_label"

url="https://apim-b2bapp-$ENV_NAME-weu-001.azure-api.net/b2bapp/v1/setup-check"
no_token="$(http_code -o /dev/null "$url")"
with_token="$(http_code -o "$LOG_DIR/response.txt" -H "Authorization: Bearer $TOKEN" "$url")"
if [[ "$no_token" == "401" ]]; then ok "senza token: 401, API Management protegge l'API"
else fail "senza token: $no_token, atteso 401"; [[ "$no_token" == "000" ]] && net_hint; fi
if [[ "$ENV_NAME" == "prd" ]]; then
  case "$with_token" in
    401) ok "con token di test: 401, prd accetta solo i token di Entra" ;;
    000) fail "con token di test: nessuna risposta"; net_hint ;;
    *)   warn "con token di test: $with_token, su prd è atteso 401" ;;
  esac
else
  case "$with_token" in
    401) if [[ -s "$LOG_DIR/response.txt" ]]; then fail "con token: 401 da API Management, token rifiutato"
         else fail "con token: 401 dalla Function, la chiave tra API Management e Function non coincide"; fi ;;
    000) fail "con token: nessuna risposta"; net_hint ;;
    404) ok "con token: 404 dalla Function, il token è accettato (la route di prova non esiste)" ;;
    *)   ok "con token: $with_token, la richiesta arriva alla Function" ;;
  esac
fi

if ask_yes_no "Mostrare il token per usarlo in un client HTTP? È una credenziale: non condividerlo" n; then
  echo; echo "$TOKEN"; echo
fi
unset TOKEN
