#!/usr/bin/env bash
# Configure VerteX after the cluster is up, from system.env: the system console (first-login
# password, activation, domain and TLS, SMTP, proxies, banners, session and password rules,
# admins, backups) and a tenant with its settings and single sign-on.
# Safe to re-run: what is already in place is left as it is or set again to the same value.
#
# Usage: ./configure.sh [-c config.env] [-s system.env] [--url https://host] [--dry-run]
#   -s FILE     the settings (default system.env; copy system.env.example)
#   --url URL   reach VerteX at URL directly (for example https://vertex.example.com from a host
#               inside the VPC) instead of through a forward to the VIP via node 1
#   --dry-run   sign in and check everything, but change nothing
#
# It signs in as the system admin with /v1/auth/syslogin and calls the VerteX API on port 443
# of the VIP (NLB_PRIVATE_IP), through node 1 like ./connect.sh, making the same calls the system
# console makes. Passwords, keys, tokens and activation links are never written to the run log.

set -euo pipefail
SCRIPT_ARGS=("$@")
SYSTEM_ENV="system.env"
API_URL=""
DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="$2"; shift 2 ;;
    -s) SYSTEM_ENV="$2"; shift 2 ;;
    --url) API_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
SYSTEM_ENV_PATH="$(cd "$(dirname "$SYSTEM_ENV")" 2>/dev/null && pwd)/$(basename "$SYSTEM_ENV")"
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_tools curl jq

# --- system.env: load and check everything before changing anything ----------------------------
SYSTEM_ADMINS=(); TENANT_CA_CERTS=()
PROBLEMS=()
problem() { PROBLEMS+=("$*"); }
expand() { local v=$1; printf '%s' "${v/#\~/$HOME}"; }   # a leading ~ in a quoted path

load_system_env() {
  local name mode v f known
  [[ -f "$SYSTEM_ENV_PATH" ]] || die "$SYSTEM_ENV not found. Copy system.env.example to system.env and fill it in."
  mode=$(file_mode "$SYSTEM_ENV_PATH")
  if [[ "$mode" =~ ^[0-7]+$ ]] && (( 8#$mode & 8#077 )); then
    warn "$SYSTEM_ENV can hold passwords and others can read it (mode $mode). Run: chmod 600 $SYSTEM_ENV"
  fi
  # Unknown names are usually typos: the setting would silently not be applied.
  if [[ -f system.env.example ]]; then
    known=" $(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' system.env.example | tr '\n' ' ') "
    for name in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SYSTEM_ENV_PATH"); do
      if [[ "$known" != *" $name "* ]]; then problem "$SYSTEM_ENV sets $name, which configure.sh doesn't read (a typo?)."; fi
    done
  fi
  # shellcheck disable=SC1090
  source "$SYSTEM_ENV_PATH"
  for f in TLS_CERT_FILE TLS_KEY_FILE TLS_CA_CERT_FILE REVERSE_PROXY_CA_CERT_FILE REVERSE_PROXY_CLIENT_CERT_FILE \
           REVERSE_PROXY_CLIENT_KEY_FILE CLASSIFICATION_BANNER_CONFIG_FILE PASSWORD_BLOCKLIST_FILE \
           TENANT_OIDC_CA_CERT_FILE TENANT_SAML_METADATA_FILE; do
    printf -v "$f" '%s' "$(expand "${!f:-}")"
  done
  logf INFO "Settings from $SYSTEM_ENV_PATH (sha256 $(_sha256 "$SYSTEM_ENV_PATH")); set: $(sed -nE 's/^([A-Z_][A-Z0-9_]*)="?[^"]+.*/\1/p' "$SYSTEM_ENV_PATH" | tr '\n' ' ')"
}

check_bool() { local v; for v in "$@"; do [[ "${!v:-false}" == true || "${!v:-false}" == false ]] || problem "$v '${!v}': use true or false."; done; }
check_int() { local v; for v in "$@"; do [[ -z "${!v:-}" || "${!v}" =~ ^[0-9]+$ ]] || problem "$v '${!v}': use a whole number."; done; }
check_file() {  # setting-name [pem-kind]: the file must exist; for PEM, it must hold that kind of block
  local v=$1 kind=${2:-} f=${!1:-}
  [[ -n "$f" ]] || return 0
  if [[ ! -r "$f" ]]; then problem "$v: can't read $f."; return 0; fi
  if [[ -n "$kind" ]] && ! grep -q -- "-----BEGIN .*$kind" "$f"; then problem "$v: $f has no PEM $kind."; fi
}
check_cert() {  # setting-name [host]: warn if the certificate has expired, or doesn't cover host
  local f=${!1:-} sans
  [[ -n "$f" && -r "$f" ]] && type -P openssl >/dev/null 2>&1 || return 0
  if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
    warn "$1: $f has expired ($(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2))."
  fi
  if [[ -n "${2:-}" ]]; then
    sans=$(openssl x509 -in "$f" -noout -text 2>/dev/null | grep -oE 'DNS:[^,[:space:]]+' | sed 's/DNS://' | tr '\n' ' ')
    case " $sans " in
      *" $2 "*|*" *.${2#*.} "*) logf INFO "$1 covers $2 (names: $sans)" ;;
      *) warn "$1: $f doesn't name $2 (it names: ${sans:-nothing}). Browsers will warn." ;;
    esac
  fi
}

check_system_env() {
  local line role email rest
  [[ -n "${SYSTEM_ADMIN_USERNAME:-}" ]] || problem "SYSTEM_ADMIN_USERNAME is required (admin on a new install)."
  [[ -n "${SYSTEM_ADMIN_PASSWORD:-}" ]] || problem "SYSTEM_ADMIN_PASSWORD is required (admin on a new install)."
  [[ "${SYSTEM_ADMIN_EMAIL:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || problem "SYSTEM_ADMIN_EMAIL '${SYSTEM_ADMIN_EMAIL:-}': the first login sets it, so give an email address."
  check_bool TLS_INSECURE_SKIP_VERIFY SMTP_INSECURE_SKIP_VERIFY LOGIN_BANNER_ENABLED TENANT_LOGIN_BANNER_ENABLED \
             TENANT_ALLOW_NON_FIPS_PACKS TENANT_ALLOW_NON_FIPS_CLUSTER_IMPORT TENANT_ALLOW_NON_FIPS_CLUSTER_FEATURES \
             TENANT_SSO_SYNC_TEAMS TENANT_OIDC_INSECURE_SKIP_VERIFY TENANT_OIDC_USE_USERINFO TENANT_SAML_SINGLE_LOGOUT
  check_int SMTP_PORT REVERSE_PROXY_PORT REVERSE_PROXY_VHOST_PORT SYSTEM_SESSION_MINUTES TENANT_SESSION_MINUTES \
            BACKUP_INTERVAL BACKUP_HOUR_OF_DAY BACKUP_RETENTION \
            SYSTEM_PASSWORD_MIN_LENGTH SYSTEM_PASSWORD_MAX_LENGTH SYSTEM_PASSWORD_MIN_UPPERCASE SYSTEM_PASSWORD_MIN_LOWERCASE \
            SYSTEM_PASSWORD_MIN_DIGITS SYSTEM_PASSWORD_MIN_SPECIAL SYSTEM_PASSWORD_EXPIRY_DAYS \
            SYSTEM_PASSWORD_FIRST_REMINDER_DAYS SYSTEM_PASSWORD_REMINDER_FREQUENCY_DAYS \
            TENANT_PASSWORD_MIN_LENGTH TENANT_PASSWORD_MAX_LENGTH TENANT_PASSWORD_MIN_UPPERCASE TENANT_PASSWORD_MIN_LOWERCASE \
            TENANT_PASSWORD_MIN_DIGITS TENANT_PASSWORD_MIN_SPECIAL TENANT_PASSWORD_EXPIRY_DAYS TENANT_PASSWORD_FIRST_REMINDER_DAYS
  if [[ -n "${BACKUP_HOUR_OF_DAY:-}" && "${BACKUP_HOUR_OF_DAY}" =~ ^[0-9]+$ ]] && (( BACKUP_HOUR_OF_DAY > 23 )); then problem "BACKUP_HOUR_OF_DAY: 0 to 23."; fi
  # Files
  check_file TLS_CERT_FILE CERTIFICATE; check_file TLS_KEY_FILE "PRIVATE KEY"; check_file TLS_CA_CERT_FILE CERTIFICATE
  check_file REVERSE_PROXY_CA_CERT_FILE CERTIFICATE; check_file REVERSE_PROXY_CLIENT_CERT_FILE CERTIFICATE
  check_file REVERSE_PROXY_CLIENT_KEY_FILE "PRIVATE KEY"; check_file TENANT_OIDC_CA_CERT_FILE CERTIFICATE
  check_file CLASSIFICATION_BANNER_CONFIG_FILE; check_file PASSWORD_BLOCKLIST_FILE; check_file TENANT_SAML_METADATA_FILE
  if [[ -n "${CLASSIFICATION_BANNER_CONFIG_FILE:-}" && -r "$CLASSIFICATION_BANNER_CONFIG_FILE" ]] && ! jq -e . "$CLASSIFICATION_BANNER_CONFIG_FILE" >/dev/null 2>&1; then
    problem "CLASSIFICATION_BANNER_CONFIG_FILE: $CLASSIFICATION_BANNER_CONFIG_FILE is not JSON."; fi
  # Settings that need each other
  if [[ -n "${TLS_CERT_FILE:-}" && -z "${TLS_KEY_FILE:-}" ]] || [[ -z "${TLS_CERT_FILE:-}" && -n "${TLS_KEY_FILE:-}" ]]; then
    problem "TLS_CERT_FILE and TLS_KEY_FILE go together."; fi
  if [[ -n "${TLS_CERT_FILE:-}" ]]; then check_cert TLS_CERT_FILE "${DOMAIN_HOST:-}"; fi
  if [[ -n "${SMTP_SERVER:-}" && ! "${SMTP_FROM:-}" =~ @ ]]; then problem "SMTP_FROM: the sender address SMTP needs."; fi
  if [[ -n "${REVERSE_PROXY_SERVER:-}" && "${REVERSE_PROXY_PROTOCOL:-https}" != http && "${REVERSE_PROXY_PROTOCOL:-https}" != https ]]; then
    problem "REVERSE_PROXY_PROTOCOL: http or https."; fi
  case "${BACKUP_TARGET:-}" in
    "") ;;
    s3) for v in BACKUP_S3_BUCKET BACKUP_S3_REGION BACKUP_S3_ACCESS_KEY; do [[ -n "${!v:-}" ]] || problem "BACKUP_TARGET=s3 needs $v."; done ;;
    ftp) [[ -n "${BACKUP_FTP_SERVER:-}" ]] || problem "BACKUP_TARGET=ftp needs BACKUP_FTP_SERVER." ;;
    *) problem "BACKUP_TARGET '${BACKUP_TARGET}': s3, ftp, or empty." ;;
  esac
  for line in ${SYSTEM_ADMINS[@]+"${SYSTEM_ADMINS[@]}"}; do
    read -r role email rest <<<"$line"
    [[ "$role" == AccountAdmin || "$role" == OperationAdmin ]] || problem "SYSTEM_ADMINS '$line': the role is AccountAdmin or OperationAdmin."
    [[ "$email" == *@* && "$rest" == *" "* ]] || problem "SYSTEM_ADMINS '$line': use \"<role> <email> <first name> <last name>\"."
  done
  if [[ -n "${TENANT_ORG_NAME:-}" ]]; then
    [[ "${TENANT_ADMIN_EMAIL:-}" == *@* ]] || problem "TENANT_ADMIN_EMAIL: the tenant's first admin needs an email address."
    [[ -n "${TENANT_ADMIN_FIRST_NAME:-}" && -n "${TENANT_ADMIN_LAST_NAME:-}" ]] || problem "TENANT_ADMIN_FIRST_NAME and TENANT_ADMIN_LAST_NAME are required with TENANT_ORG_NAME."
    [[ "${TENANT_LOGIN_MODE:-devops}" == devops || "${TENANT_LOGIN_MODE:-devops}" == dev ]] || problem "TENANT_LOGIN_MODE: devops or dev."
  fi
  for line in ${TENANT_CA_CERTS[@]+"${TENANT_CA_CERTS[@]}"}; do
    read -r email rest <<<"$line"; rest=$(expand "$rest")
    if [[ -z "$rest" || ! -r "$rest" ]] || ! grep -q -- '-----BEGIN CERTIFICATE' "$rest"; then problem "TENANT_CA_CERTS '$line': use \"<name> <certificate.pem>\" with a readable PEM file."; fi
  done
  case "${TENANT_SSO:-}" in
    "") ;;
    oidc) [[ -n "${TENANT_OIDC_ISSUER_URL:-}" && -n "${TENANT_OIDC_CLIENT_ID:-}" ]] || problem "TENANT_SSO=oidc needs TENANT_OIDC_ISSUER_URL and TENANT_OIDC_CLIENT_ID." ;;
    saml) [[ -n "${TENANT_SAML_METADATA_FILE:-}" ]] || problem "TENANT_SSO=saml needs TENANT_SAML_METADATA_FILE." ;;
    *) problem "TENANT_SSO '${TENANT_SSO}': oidc, saml, or empty." ;;
  esac
  if [[ -z "${TENANT_ORG_NAME:-}" && -n "${TENANT_SSO:-}${TENANT_SESSION_MINUTES:-}${TENANT_PASSWORD_MIN_LENGTH:-}" ]]; then
    problem "Tenant settings are set but TENANT_ORG_NAME is empty."; fi
  local p
  for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do warn "$p"; done
  [[ ${#PROBLEMS[@]} -eq 0 ]] || die "Fix the settings above in $SYSTEM_ENV, then re-run. Nothing was changed."
  ok "Settings in $SYSTEM_ENV"
}

ask_secret() {  # variable prompt: read a password into the variable if it is empty (twice for a new one)
  local v=$1 again=""
  [[ -z "${!v:-}" ]] || return 0
  [[ -t 0 ]] || die "$v is empty and there is no terminal to ask for it; set it in $SYSTEM_ENV."
  read -r -s -p "$2: " "$v"; echo >&2
  if [[ "${3:-}" == confirm ]]; then
    read -r -s -p "Again: " again; echo >&2
    [[ "${!v}" == "$again" ]] || die "The two entries for $v differ."
  fi
  [[ -n "${!v}" ]] || die "$v is empty."
}

# --- The VerteX API ------------------------------------------------------------------------------
API_BASE=""; CONNECT_TO=""; API_TOKEN=""; API_STATUS=""; API_BODY=""
REDACT_JQ='def r: if type == "object" then with_entries(if (.key | test("pass|secret|token|authorization|key|cert|federation|link"; "i")) and (.value | type) == "string" then .value = "<redacted, \(.value | length) chars>" else .value |= r end) elif type == "array" then map(r) else . end; r'
redact_json() {  # text: JSON with every secret-looking string replaced, or a short note for anything else
  [[ -n "$1" ]] || return 0
  jq -c "$REDACT_JQ" <<<"$1" 2>/dev/null || printf '(%s bytes, not JSON)\n' "${#1}"
}
log_path() { printf '%s' "$1" | sed -E 's#/password/[^/]+/(activate|reset)#/password/<token>/\1#'; }   # tokens out of the log
api() {  # method path [json-body]: sets API_STATUS and API_BODY; 0 on HTTP 2xx. Logged without secrets.
  local method=$1 path=$2 body=${3:-} out rc=0 t0 errf lp
  lp=$(log_path "$2")
  local args=(-sS -k --connect-timeout 15 --max-time 120 -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  if [[ -n "$API_TOKEN" ]]; then args+=(-H "Authorization: $API_TOKEN"); fi
  if [[ -n "$CONNECT_TO" ]]; then args+=(--connect-to "$CONNECT_TO"); fi
  errf=$(mktemp "$_LOG_TMP/curl.XXXXXX"); t0=$(_clock)
  if [[ -n "$body" ]]; then
    out=$(curl "${args[@]}" --data-binary @- "$API_BASE$path" <<<"$body" 2>"$errf") || rc=$?
  else
    out=$(curl "${args[@]}" "$API_BASE$path" 2>"$errf") || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    API_STATUS="000"; API_BODY="$(tr '\n' ' ' <"$errf")"; rm -f "$errf"
    logf WARN "VerteX $method $lp: no answer (curl exit $rc after $(_took "$t0")): $API_BODY"
    return 1
  fi
  rm -f "$errf"
  API_STATUS=${out##*$'\n'}; API_BODY=${out%$'\n'*}
  logf DEBUG "VerteX $method $lp -> HTTP $API_STATUS in $(_took "$t0")"
  log_text req "$(redact_json "$body")"
  log_text res "$(redact_json "$API_BODY")"
  [[ "$API_STATUS" =~ ^2 ]]
}
api_error() {  # why the last call failed, from VerteX's error message
  local m
  m=$(jq -r '.message // empty' <<<"$API_BODY" 2>/dev/null | head -c 300) || m=""
  printf 'HTTP %s%s' "$API_STATUS" "${m:+: $m}"
}
b64() { base64 <"$1" | tr -d '\n'; }   # a file as one line of base64

APPLIED=0; FAILED=0; SKIPPED=0; NEXT=()
apply() {  # label method path [body]: one change; a check when VerteX takes it, a "!" (and carry on) if not
  if [[ "$DRY_RUN" == true ]]; then
    printf '  - %s (dry run: not changed)\n' "$1"; logf INFO "dry run, not sent: $2 $(log_path "$3")"; return 0
  fi
  if api "$2" "$3" "${4:-}"; then ok "$1"; APPLIED=$((APPLIED + 1)); return 0; fi
  warn "$1: not applied ($(api_error))"; FAILED=$((FAILED + 1)); return 1
}

vertex_up() {  # wait_until check: VerteX answers on port 443 (any API answer, even "sign in first")
  if api GET /v1/auth/sso/providers; then WAIT_STATE="answering"; return 0; fi
  case "$API_STATUS" in
    000) WAIT_STATE="no answer yet" ;;
    401|403) WAIT_STATE="answering"; return 0 ;;
    *) WAIT_STATE="HTTP $API_STATUS" ;;
  esac
  return 1
}
open_api() {  # set API_BASE (and CONNECT_TO): directly with --url, else a forward to the VIP's 443 via node 1
  local port fwd_out=""
  if [[ -n "$API_URL" ]]; then
    API_BASE=${API_URL%/}; ok "VerteX at $API_BASE"
  else
    [[ -n "$NLB_PRIVATE_IP" ]] || die "NLB_PRIVATE_IP is not set in $CONFIG."
    [[ -n "$(nlb_arn)" ]] || die "No NLB yet: run ./deploy.sh after Deploy Cluster, or use --url."
    # shellcheck disable=SC2207
    IDS=($(node_ids)); IPS=($(node_ips))
    [[ ${#IDS[@]} -gt 0 ]] || die "No running nodes for $NAME_PREFIX."
    port=$(free_port 18443); KILL_JOBS_ON_EXIT=true
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_opts
      fwd_out="$_LOG_TMP/ssh-vertex-forward.bg"
      ssh "${EICE_OPTS[@]}" -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L "$port:$NLB_PRIVATE_IP:443" \
          "$SSH_USER@${IDS[0]}" 2>>"$fwd_out" &
      logf INFO "forward (pid $!): localhost:$port -> $NLB_PRIVATE_IP:443 through node 1 (${IDS[0]})"
    else
      SSM_QUIET=true; ssm_forward "$NLB_PRIVATE_IP" 443 "$port"; fwd_out="$_LOG_TMP/ssm-localhost-$port.bg"
    fi
    wait_port "$port" "$fwd_out"
    API_BASE="https://$NLB_PRIVATE_IP"; CONNECT_TO="$NLB_PRIVATE_IP:443:127.0.0.1:$port"
  fi
  wait_until "Waiting for VerteX at $API_BASE" "VerteX answering at $API_BASE" 300 5 vertex_up \
    || die "VerteX does not answer at $API_BASE (${WAIT_STATE}). Is port 443 healthy? ./status.sh"
}

# --- System admin: sign in, and set the password and email on first login ------------------------
syslogin() {  # password: sign in as SYSTEM_ADMIN_USERNAME; sets API_TOKEN and PASSWORD_IS_SET
  local body
  body=$(U="$SYSTEM_ADMIN_USERNAME" P="$1" jq -cn '{username: env.U, password: env.P}')
  API_TOKEN=""
  api POST "/v1/auth/syslogin?setCookie=false" "$body" || return 1
  API_TOKEN=$(jq -r '.Authorization // empty' <<<"$API_BODY")
  PASSWORD_IS_SET=$(jq -r 'if .IsPasswordReset == false then "false" else "true" end' <<<"$API_BODY")
  [[ -n "$API_TOKEN" ]]
}
sign_in() {
  # Try the new password first (set by an earlier run), then the current one: two attempts at most,
  # well under the console's lockout.
  local typed=""
  if [[ "${SYSTEM_ADMIN_NEW_PASSWORD:-}" == "$SYSTEM_ADMIN_PASSWORD" ]]; then SYSTEM_ADMIN_NEW_PASSWORD=""; fi
  if [[ -n "${SYSTEM_ADMIN_NEW_PASSWORD:-}" && "$SYSTEM_ADMIN_NEW_PASSWORD" != "$SYSTEM_ADMIN_PASSWORD" ]] \
     && syslogin "$SYSTEM_ADMIN_NEW_PASSWORD"; then
    ok "Signed in as $SYSTEM_ADMIN_USERNAME (new password already set)"; return 0
  fi
  if ! syslogin "$SYSTEM_ADMIN_PASSWORD"; then
    die "Could not sign in as $SYSTEM_ADMIN_USERNAME with SYSTEM_ADMIN_PASSWORD$([[ -n "${SYSTEM_ADMIN_NEW_PASSWORD:-}" ]] && echo " or SYSTEM_ADMIN_NEW_PASSWORD") ($(api_error))."
  fi
  ok "Signed in as $SYSTEM_ADMIN_USERNAME"
  # First login (VerteX says so, or the password is still the default admin), or a new password
  # asked for: set the email and the new password.
  if [[ "$PASSWORD_IS_SET" != true || "$SYSTEM_ADMIN_PASSWORD" == admin || -n "${SYSTEM_ADMIN_NEW_PASSWORD:-}" ]]; then
    logf INFO "Setting the system admin password (first login: $([[ "$PASSWORD_IS_SET" != true ]] && echo yes || echo "not flagged"))"
    if [[ -z "${SYSTEM_ADMIN_NEW_PASSWORD:-}" ]]; then typed=1; fi
    ask_secret SYSTEM_ADMIN_NEW_PASSWORD "New password for the system admin $SYSTEM_ADMIN_USERNAME" confirm
    [[ "$SYSTEM_ADMIN_NEW_PASSWORD" != "$SYSTEM_ADMIN_PASSWORD" ]] || die "SYSTEM_ADMIN_NEW_PASSWORD must differ from SYSTEM_ADMIN_PASSWORD."
    if [[ "$DRY_RUN" == true ]]; then printf '  - Set the admin password and email (dry run: not changed)\n'; return 0; fi
    local body
    body=$(E="$SYSTEM_ADMIN_EMAIL" O="$SYSTEM_ADMIN_PASSWORD" N="$SYSTEM_ADMIN_NEW_PASSWORD" \
           jq -cn '{email: env.E, oldPassword: env.O, newPassword: env.N}')
    api PATCH /v1/system/admin/password/reset "$body" \
      || die "VerteX did not take the new admin password ($(api_error)). Check it against the password rules."
    syslogin "$SYSTEM_ADMIN_NEW_PASSWORD" \
      || die "The password change was accepted, but the new password does not sign in ($(api_error))."
    ok "System admin password and email ($SYSTEM_ADMIN_EMAIL) set; signed in with the new password"
    if [[ -n "$typed" ]]; then NEXT+=("Set SYSTEM_ADMIN_PASSWORD in $SYSTEM_ENV to the new password before you re-run."); fi
  fi
}

# --- System console settings ---------------------------------------------------------------------
configure_activation() {
  local state uid
  api GET /v1/system/activation || { warn "Could not read the activation state ($(api_error))"; return 0; }
  state=$(jq -r '.status.state // "unknown"' <<<"$API_BODY"); uid=$(jq -r '.spec.systemUid // empty' <<<"$API_BODY")
  if [[ "$state" == Active ]]; then ok "VerteX is activated"; return 0; fi
  if [[ -n "${ACTIVATION_KEY:-}" ]]; then
    apply "Activated VerteX with ACTIVATION_KEY" POST /v1/system/activate "$(K="$ACTIVATION_KEY" jq -cn '{activationKey: env.K}')"
  else
    warn "VerteX is not activated (state $state): 30-day trial. Send support the product ID from Administration > Activation${uid:+ (system UID $uid)}, then set ACTIVATION_KEY."
  fi
}

configure_domain() {
  local body
  if [[ -n "${TLS_CERT_FILE:-}" ]]; then
    local root=${DOMAIN_HOST:-}
    if [[ -z "$root" ]] && api GET /v1/system/config/domain; then root=$(jq -r '.rootDomain // empty' <<<"$API_BODY"); fi
    body=$(jq -cn --arg d "$root" --arg c "$(b64 "$TLS_CERT_FILE")" --arg k "$(b64 "$TLS_KEY_FILE")" \
             --arg a "$([[ -n "${TLS_CA_CERT_FILE:-}" ]] && b64 "$TLS_CA_CERT_FILE")" --argjson s "${TLS_INSECURE_SKIP_VERIFY:-false}" \
             '{rootDomain: $d, certificates: {certificateBase64: $c, keyBase64: $k, caCertificateBase64: $a, insecureSkipVerify: $s}}')
    apply "Domain ${root:-(unchanged)} with the TLS certificate from $(basename "$TLS_CERT_FILE")" PUT /v1/system/config/domain/certificates "$body" || return 0
  elif [[ -n "${DOMAIN_HOST:-}" ]]; then
    apply "Domain $DOMAIN_HOST" PATCH /v1/system/config/domain "$(jq -cn --arg h "$DOMAIN_HOST" '{host: $h}')" || return 0
  else
    return 0
  fi
  [[ "$DRY_RUN" == true ]] && return 0
  # The ingress reloads its certificate; wait until the API answers again.
  sleep 5
  wait_until "Waiting for VerteX after the domain change" "VerteX answering again" 300 5 vertex_up \
    || warn "VerteX hasn't answered since the domain change; the remaining settings may fail."
  if [[ -n "${DOMAIN_HOST:-}" ]]; then NEXT+=("Point DNS for $DOMAIN_HOST at the VIP${NLB_PRIVATE_IP:+ $NLB_PRIVATE_IP}; then use https://$DOMAIN_HOST/system."); fi
}

configure_smtp() {
  [[ -n "${SMTP_SERVER:-}" ]] || return 0
  if [[ -n "${SMTP_USERNAME:-}" ]]; then ask_secret SMTP_PASSWORD "Password for SMTP user $SMTP_USERNAME"; fi
  apply "SMTP $SMTP_SERVER:${SMTP_PORT:-587}, from $SMTP_FROM" PUT /v1/system/config/smtp "$(
    S="$SMTP_SERVER" F="$SMTP_FROM" U="${SMTP_USERNAME:-}" P="${SMTP_PASSWORD:-}" \
    jq -cn --argjson port "${SMTP_PORT:-587}" --argjson skip "${SMTP_INSECURE_SKIP_VERIFY:-false}" \
      '{smtpServer: env.S, smtpPort: $port, fromEmailId: env.F, userName: env.U, password: env.P, insecureSkipVerifyTls: $skip}')" || true
}

configure_proxies() {
  if [[ -n "${SYSTEM_HTTP_PROXY:-}${SYSTEM_HTTPS_PROXY:-}${SYSTEM_NO_PROXY:-}" ]]; then
    apply "Outbound proxy${SYSTEM_HTTPS_PROXY:+ $SYSTEM_HTTPS_PROXY}${SYSTEM_HTTP_PROXY:+ (HTTP $SYSTEM_HTTP_PROXY)}" PUT /v1/system/config/proxy \
      "$(jq -cn --arg h "${SYSTEM_HTTP_PROXY:-}" --arg s "${SYSTEM_HTTPS_PROXY:-}" --arg n "${SYSTEM_NO_PROXY:-}" '{httpProxy: $h, httpsProxy: $s, noProxy: $n}')" || true
  fi
  if [[ -n "${REVERSE_PROXY_SERVER:-}" ]]; then
    apply "Reverse proxy ${REVERSE_PROXY_PROTOCOL:-https}://$REVERSE_PROXY_SERVER:${REVERSE_PROXY_PORT:-443}" PUT /v1/system/config/reverseproxy "$(
      jq -cn --arg server "$REVERSE_PROXY_SERVER" --argjson port "${REVERSE_PROXY_PORT:-443}" --arg protocol "${REVERSE_PROXY_PROTOCOL:-https}" \
        --argjson vhost "${REVERSE_PROXY_VHOST_PORT:-443}" \
        --arg ca "$([[ -n "${REVERSE_PROXY_CA_CERT_FILE:-}" ]] && b64 "$REVERSE_PROXY_CA_CERT_FILE")" \
        --arg cert "$([[ -n "${REVERSE_PROXY_CLIENT_CERT_FILE:-}" ]] && b64 "$REVERSE_PROXY_CLIENT_CERT_FILE")" \
        --arg key "$([[ -n "${REVERSE_PROXY_CLIENT_KEY_FILE:-}" ]] && b64 "$REVERSE_PROXY_CLIENT_KEY_FILE")" \
        '{server: $server, port: $port, protocol: $protocol, vHostPort: $vhost, caCert: $ca, clientCert: $cert, clientKey: $key}')" || true
  fi
}

banner() {  # label path enabled title message: set a login banner unless it is already exactly that
  local want
  want=$(jq -cn --argjson e "$3" --arg t "$4" --arg m "$5" '{isEnabled: $e, title: $t, Message: $m}')
  if api GET "$2" && [[ "$(jq -c '{isEnabled: (.isEnabled // false), title: (.title // ""), Message: (.Message // "")}' <<<"$API_BODY" 2>/dev/null)" == "$want" ]]; then
    ok "$1 already $([[ "$3" == true ]] && echo "on: $4" || echo off)"; return 0
  fi
  apply "$1 $([[ "$3" == true ]] && echo "on: $4" || echo off)" PUT "$2" "$want" || true
}

password_policy() {  # label get-path set-method set-path prefix (SYSTEM or TENANT): merge the set rules into the current policy
  local cur new p=$5 v
  local args=()
  for v in MIN_LENGTH:minLength MAX_LENGTH:maxLength MIN_UPPERCASE:minNumOfBlockLetters MIN_LOWERCASE:minNumOfSmallLetters \
           MIN_DIGITS:minNumOfDigits MIN_SPECIAL:minNumOfSpecialCharacters EXPIRY_DAYS:expiryDurationInDays \
           FIRST_REMINDER_DAYS:firstReminderInDays REMINDER_FREQUENCY_DAYS:reminderFrequency; do
    local name="${p}_PASSWORD_${v%%:*}"
    if [[ -n "${!name:-}" ]]; then args+=("${v#*:}=${!name}"); fi
  done
  local regex_name="${p}_PASSWORD_REGEX"
  [[ ${#args[@]} -gt 0 || -n "${!regex_name:-}" ]] || return 0
  if api GET "$2"; then cur=$API_BODY; else cur='{}'; fi
  new=$(jq -c 'del(.creationTimestamp, .updateTimestamp)' <<<"$cur")
  for v in ${args[@]+"${args[@]}"}; do new=$(jq -c --arg k "${v%%=*}" --argjson n "${v#*=}" '.[$k] = $n' <<<"$new"); done
  if [[ -n "${!regex_name:-}" ]]; then new=$(jq -c --arg r "${!regex_name}" '.isRegex = true | .regex = $r' <<<"$new"); fi
  apply "$1" "$3" "$4" "$new" || true
}

configure_security() {
  if [[ -n "${SYSTEM_SESSION_MINUTES:-}" ]]; then
    apply "System console sessions last $SYSTEM_SESSION_MINUTES minutes" PUT /v1/system/authTokenSettings \
      "$(jq -cn --argjson m "$SYSTEM_SESSION_MINUTES" '{expiryTimeMinutes: $m}')" || true
  fi
  password_policy "System password rules" /v1/system/password/policy/default PUT /v1/system/password/policy/default SYSTEM
  if [[ -n "${PASSWORD_BLOCKLIST_FILE:-}" ]]; then
    apply "Password blocklist: $(grep -c . "$PASSWORD_BLOCKLIST_FILE" | tr -d ' ') passwords from $(basename "$PASSWORD_BLOCKLIST_FILE")" \
      PATCH /v1/system/passwords/blocklist "$(jq -R -s -c '{spec: {passwords: (split("\n") | map(select(length > 0)))}}' "$PASSWORD_BLOCKLIST_FILE")" || true
  fi
}

configure_banners() {
  if [[ "${LOGIN_BANNER_ENABLED:-false}" == true || -n "${LOGIN_BANNER_TITLE:-}" ]]; then
    banner "System login banner" /v1/system/loginBanner "${LOGIN_BANNER_ENABLED:-false}" "${LOGIN_BANNER_TITLE:-}" "${LOGIN_BANNER_MESSAGE:-}"
  fi
  if [[ -n "${CLASSIFICATION_BANNER_CONFIG_FILE:-}" ]]; then
    apply "Classification banner from $(basename "$CLASSIFICATION_BANNER_CONFIG_FILE")" PUT /v1/system/classificationBanner \
      "$(jq -c '{config: (. | tojson)}' "$CLASSIFICATION_BANNER_CONFIG_FILE")" || true
  fi
}

configure_admins() {
  local line role email first last existing
  [[ ${#SYSTEM_ADMINS[@]} -gt 0 ]] || return 0
  if api GET /v1/system/admins; then existing=" $(jq -r '[.items[]?.spec.emailId] | join(" ")' <<<"$API_BODY") "; else existing=" "; fi
  for line in "${SYSTEM_ADMINS[@]}"; do
    read -r role email first last <<<"$line"
    if [[ "$existing" == *" $email "* ]]; then ok "System admin $email exists"; continue; fi
    apply "System admin $email ($role) created; VerteX emails them a link to set a password" POST /v1/system/admins "$(
      jq -cn --arg r "$role" --arg e "$email" --arg f "$first" --arg l "$last" \
        '{metadata: {name: $e}, spec: {adminType: $r, emailId: $e, firstName: $f, lastName: $l}}')" || true
  done
}

configure_backups() {
  local spec
  [[ -n "${BACKUP_TARGET:-}" ]] || return 0
  spec=$(jq -cn --arg i "${BACKUP_INTERVAL:-}" --arg h "${BACKUP_HOUR_OF_DAY:-}" --arg r "${BACKUP_RETENTION:-}" \
    '{interval: $i, hourOfTheDay: $h, retentionPeriod: $r} | with_entries(select(.value != "") | .value |= tonumber)')
  if [[ "$BACKUP_TARGET" == s3 ]]; then
    ask_secret BACKUP_S3_SECRET_KEY "Secret key for $BACKUP_S3_ACCESS_KEY (backups)"
    apply "Database backups to s3://$BACKUP_S3_BUCKET/${BACKUP_S3_FOLDER:-}" PUT /v1/system/config/database/backup/s3 "$(
      B="$BACKUP_S3_BUCKET" R="$BACKUP_S3_REGION" F="${BACKUP_S3_FOLDER:-}" A="$BACKUP_S3_ACCESS_KEY" S="$BACKUP_S3_SECRET_KEY" \
      jq -cn --argjson spec "$spec" '{backupSpec: $spec, s3: {bucket: env.B, region: env.R, folder: env.F, accessKey: env.A, secretKey: env.S}}')" || true
  else
    if [[ -n "${BACKUP_FTP_USERNAME:-}" ]]; then ask_secret BACKUP_FTP_PASSWORD "FTP password for $BACKUP_FTP_USERNAME (backups)"; fi
    apply "Database backups to ftp://$BACKUP_FTP_SERVER/${BACKUP_FTP_DIR:-}" PUT /v1/system/config/database/backup/ftp "$(
      H="$BACKUP_FTP_SERVER" D="${BACKUP_FTP_DIR:-}" U="${BACKUP_FTP_USERNAME:-}" P="${BACKUP_FTP_PASSWORD:-}" \
      jq -cn --argjson spec "$spec" '{backupSpec: $spec, ftp: {server: env.H, dir: env.D, username: env.U, password: env.P}}')" || true
  fi
}

# --- The tenant ----------------------------------------------------------------------------------
TENANT_UID=""; SYSTEM_TOKEN=""; TENANT_TOKEN=""; AS_TENANT=""   # AS_TENANT: the system admin was refused once
tenant_token() {  # sign in as the tenant admin (for settings the system admin may not change); 0 if it worked
  [[ -n "$TENANT_TOKEN" ]] && return 0
  [[ -n "${TENANT_ADMIN_PASSWORD:-}" ]] || return 1
  local saved=$API_TOKEN
  API_TOKEN=""
  if api POST /v1/auth/authenticate "$(E="$TENANT_ADMIN_EMAIL" O="$TENANT_ORG_NAME" P="$TENANT_ADMIN_PASSWORD" \
       jq -cn '{emailId: env.E, org: env.O, password: env.P}')"; then
    TENANT_TOKEN=$(jq -r '.Authorization // empty' <<<"$API_BODY")
  fi
  API_TOKEN=$saved
  [[ -n "$TENANT_TOKEN" ]]
}
tenant_apply() {  # label method path [body]: as the system admin; if VerteX says no, as the tenant admin
  if [[ "$DRY_RUN" == true ]]; then apply "$@"; return 0; fi
  if [[ -z "$AS_TENANT" ]]; then
    if api "$2" "$3" "${4:-}"; then ok "$1"; APPLIED=$((APPLIED + 1)); return 0; fi
  else
    API_STATUS=403
  fi
  if [[ "$API_STATUS" == 401 || "$API_STATUS" == 403 ]] && tenant_token; then
    API_TOKEN=$TENANT_TOKEN
    if api "$2" "$3" "${4:-}"; then
      ok "$1 (as the tenant admin)"; APPLIED=$((APPLIED + 1)); API_TOKEN=$SYSTEM_TOKEN; AS_TENANT=1; return 0
    fi
    API_TOKEN=$SYSTEM_TOKEN
  fi
  if [[ "$API_STATUS" == 401 || "$API_STATUS" == 403 ]]; then
    warn "$1: needs the tenant admin. Once they have set a password, put it in TENANT_ADMIN_PASSWORD and re-run."
    SKIPPED=$((SKIPPED + 1)); return 1
  fi
  warn "$1: not applied ($(api_error))"; FAILED=$((FAILED + 1)); return 1
}
tenant_get() {  # path: GET as the system admin, else as the tenant admin; 0 if either worked
  if [[ -z "$AS_TENANT" ]]; then api GET "$1" && return 0; else API_STATUS=403; fi
  if [[ "$API_STATUS" == 401 || "$API_STATUS" == 403 ]] && tenant_token; then
    API_TOKEN=$TENANT_TOKEN; local rc=0; api GET "$1" || rc=1; API_TOKEN=$SYSTEM_TOKEN; return $rc
  fi
  return 1
}

configure_tenant() {
  local active
  [[ -n "${TENANT_ORG_NAME:-}" ]] || return 0
  log "Tenant $TENANT_ORG_NAME"
  SYSTEM_TOKEN=$API_TOKEN
  api GET "/v1/tenants?limit=500" || die "Could not list tenants ($(api_error))."
  TENANT_UID=$(O="$TENANT_ORG_NAME" jq -r '[.items[]? | select(.spec.orgName == env.O)][0].metadata.uid // empty' <<<"$API_BODY")
  active=$(O="$TENANT_ORG_NAME" jq -r '[.items[]? | select(.spec.orgName == env.O)][0].status.isActive // false' <<<"$API_BODY")
  if [[ -n "$TENANT_UID" ]]; then
    ok "Tenant $TENANT_ORG_NAME exists ($TENANT_UID)"
  else
    apply "Created tenant $TENANT_ORG_NAME with admin $TENANT_ADMIN_EMAIL" POST /v1/tenants "$(
      O="$TENANT_ORG_NAME" E="$TENANT_ADMIN_EMAIL" F="$TENANT_ADMIN_FIRST_NAME" L="$TENANT_ADMIN_LAST_NAME" M="${TENANT_LOGIN_MODE:-devops}" \
      jq -cn '{metadata: {name: env.O}, spec: {orgName: env.O, emailId: env.E, firstName: env.F, lastName: env.L, loginMode: env.M}}')" || return 0
    [[ "$DRY_RUN" == true ]] && return 0
    TENANT_UID=$(jq -r '.uid // empty' <<<"$API_BODY")
    [[ -n "$TENANT_UID" ]] || { warn "VerteX created the tenant but returned no UID; re-run to apply its settings."; return 0; }
  fi
  [[ "$DRY_RUN" == true && -z "$TENANT_UID" ]] && return 0
  if [[ "$active" != true ]]; then activate_tenant; fi
  local skipped_before=$SKIPPED
  configure_tenant_settings
  if [[ $SKIPPED -gt $skipped_before ]]; then
    NEXT+=("Then put the tenant admin's password in TENANT_ADMIN_PASSWORD and re-run ./configure.sh to apply the $((SKIPPED - skipped_before)) skipped tenant setting(s).")
  fi
}

fips_mode() { if [[ "$1" == true ]]; then echo nonFipsEnabled; else echo nonFipsDisabled; fi; }
allowed() { if [[ "$1" == true ]]; then echo allowed; else echo blocked; fi; }
activate_tenant() {
  # What the console's Activate does: fetch the tenant's one-time activation link, which has the
  # admin set a password. With TENANT_ADMIN_PASSWORD, set it here; otherwise print the link.
  local link token
  if ! api GET "/v1/users/$TENANT_UID/activationlink"; then
    warn "Could not get tenant $TENANT_ORG_NAME's activation link ($(api_error)); use the console's Activate."; return 0
  fi
  link=$(jq -r '.activationLink // empty' <<<"$API_BODY")
  if [[ -z "$link" ]]; then ok "Tenant $TENANT_ORG_NAME is already active"; return 0; fi
  token=$(sed -nE 's#.*/password/([^/?#]+)/activate.*#\1#p' <<<"$link")
  if [[ -n "${TENANT_ADMIN_PASSWORD:-}" && -n "$token" ]]; then
    if [[ "$DRY_RUN" == true ]]; then printf '  - Set the tenant admin password and activate %s (dry run: not changed)\n' "$TENANT_ORG_NAME"; return 0; fi
    local saved=$API_TOKEN; API_TOKEN=""   # the activation link works without signing in
    if api PATCH "/v1/auth/password/$token/activate" "$(P="$TENANT_ADMIN_PASSWORD" jq -cn '{password: env.P}')"; then
      ok "Tenant $TENANT_ORG_NAME activated: $TENANT_ADMIN_EMAIL's password set from TENANT_ADMIN_PASSWORD"; APPLIED=$((APPLIED + 1))
    else
      warn "Could not set $TENANT_ADMIN_EMAIL's password ($(api_error)); check it against the password rules."; FAILED=$((FAILED + 1))
    fi
    API_TOKEN=$saved; return 0
  fi
  # Shown on the console only, never logged: the link sets the tenant admin's password.
  logf INFO "Tenant $TENANT_ORG_NAME's activation link shown on the console (not logged)"
  printf '\n  Activation link for %s (%s); open it once to set their password:\n    %s\n' "$TENANT_ORG_NAME" "$TENANT_ADMIN_EMAIL" "$link"
  if [[ "$link" =~ ^https?://[^/]+(/.*)$ ]]; then
    printf '  Through ./connect.sh console:\n    https://localhost:8443%s\n\n' "${BASH_REMATCH[1]}"
  fi
  NEXT+=("Open the activation link above to set $TENANT_ADMIN_EMAIL's password (or set TENANT_ADMIN_PASSWORD and re-run to have configure.sh set it).")
}

configure_tenant_settings() {
  local t="/v1/tenants/$TENANT_UID"
  local p=${TENANT_ALLOW_NON_FIPS_PACKS:-false} i=${TENANT_ALLOW_NON_FIPS_CLUSTER_IMPORT:-false} f=${TENANT_ALLOW_NON_FIPS_CLUSTER_FEATURES:-false}
  tenant_apply "Tenant FIPS: non-FIPS packs $(allowed "$p"), cluster import $(allowed "$i"), cluster features $(allowed "$f")" \
    PUT "$t/preferences/fips" "$(jq -cn --arg p "$(fips_mode "$p")" --arg i "$(fips_mode "$i")" --arg f "$(fips_mode "$f")" \
      '{fipsPackConfig: {mode: $p}, fipsClusterImportConfig: {mode: $i}, fipsClusterFeatureConfig: {mode: $f}}')" || true
  if [[ -n "${TENANT_SESSION_MINUTES:-}" ]]; then
    tenant_apply "Tenant sessions last $TENANT_SESSION_MINUTES minutes" PUT "$t/authTokenSettings" \
      "$(jq -cn --argjson m "$TENANT_SESSION_MINUTES" '{expiryTimeMinutes: $m}')" || true
  fi
  # Password rules: merge into the current policy (read as either admin).
  local cur new v args=()
  for v in MIN_LENGTH:minLength MAX_LENGTH:maxLength MIN_UPPERCASE:minNumOfBlockLetters MIN_LOWERCASE:minNumOfSmallLetters \
           MIN_DIGITS:minNumOfDigits MIN_SPECIAL:minNumOfSpecialCharacters EXPIRY_DAYS:expiryDurationInDays FIRST_REMINDER_DAYS:firstReminderInDays; do
    local name="TENANT_PASSWORD_${v%%:*}"
    if [[ -n "${!name:-}" ]]; then args+=("${v#*:}=${!name}"); fi
  done
  if [[ ${#args[@]} -gt 0 || -n "${TENANT_PASSWORD_REGEX:-}" ]]; then
    if tenant_get "$t/password/policy"; then cur=$API_BODY; else cur='{}'; fi
    new=$(jq -c 'del(.creationTimestamp, .updateTimestamp)' <<<"$cur")
    for v in ${args[@]+"${args[@]}"}; do new=$(jq -c --arg k "${v%%=*}" --argjson n "${v#*=}" '.[$k] = $n' <<<"$new"); done
    if [[ -n "${TENANT_PASSWORD_REGEX:-}" ]]; then new=$(jq -c --arg r "$TENANT_PASSWORD_REGEX" '.isRegex = true | .regex = $r' <<<"$new"); fi
    tenant_apply "Tenant password rules" POST "$t/password/policy" "$new" || true
  fi
  if [[ "${TENANT_LOGIN_BANNER_ENABLED:-false}" == true || -n "${TENANT_LOGIN_BANNER_TITLE:-}" ]]; then
    tenant_apply "Tenant login banner $([[ "${TENANT_LOGIN_BANNER_ENABLED:-false}" == true ]] && echo "on: ${TENANT_LOGIN_BANNER_TITLE:-}" || echo off)" PUT "$t/loginBanner" \
      "$(jq -cn --argjson e "${TENANT_LOGIN_BANNER_ENABLED:-false}" --arg ti "${TENANT_LOGIN_BANNER_TITLE:-}" --arg m "${TENANT_LOGIN_BANNER_MESSAGE:-}" \
         '{isEnabled: $e, title: $ti, Message: $m}')" || true
  fi
  # CA certificates: add the ones not there yet (by name).
  local line name file have=" "
  if [[ ${#TENANT_CA_CERTS[@]} -gt 0 ]]; then
    if tenant_get "$t/assets/certs"; then have=" $(jq -r '[.items[]?.metadata.name] | join(" ")' <<<"$API_BODY") "; fi
    for line in "${TENANT_CA_CERTS[@]}"; do
      read -r name file <<<"$line"; file=$(expand "$file")
      if [[ "$have" == *" $name "* ]]; then ok "Tenant certificate $name exists"; continue; fi
      tenant_apply "Tenant certificate $name from $(basename "$file")" POST "$t/assets/certs" \
        "$(jq -cn --arg n "$name" --rawfile c "$file" '{metadata: {name: $n}, spec: {certificate: $c, isCA: true}}')" || true
    done
  fi
  configure_tenant_sso "$t"
}

configure_tenant_sso() {
  local t=$1 teams body callback
  teams=$(jq -cn --arg t "${TENANT_SSO_DEFAULT_TEAMS:-}" '$t | split(" ") | map(select(length > 0))')
  case "${TENANT_SSO:-}" in
    oidc)
      ask_secret TENANT_OIDC_CLIENT_SECRET "Client secret for OIDC client $TENANT_OIDC_CLIENT_ID"
      body=$(I="$TENANT_OIDC_ISSUER_URL" C="$TENANT_OIDC_CLIENT_ID" S="$TENANT_OIDC_CLIENT_SECRET" L="${TENANT_OIDC_LOGOUT_URL:-}" \
        jq -cn --argjson teams "$teams" --argjson sync "${TENANT_SSO_SYNC_TEAMS:-false}" \
          --arg scopes "${TENANT_OIDC_SCOPES:-openid profile email}" \
          --arg ca "$([[ -n "${TENANT_OIDC_CA_CERT_FILE:-}" ]] && b64 "$TENANT_OIDC_CA_CERT_FILE")" \
          --argjson skip "${TENANT_OIDC_INSECURE_SKIP_VERIFY:-false}" --argjson userinfo "${TENANT_OIDC_USE_USERINFO:-false}" \
          --arg e "${TENANT_OIDC_CLAIM_EMAIL:-email}" --arg f "${TENANT_OIDC_CLAIM_FIRST_NAME:-given_name}" \
          --arg l "${TENANT_OIDC_CLAIM_LAST_NAME:-family_name}" --arg g "${TENANT_OIDC_CLAIM_TEAMS:-groups}" '
          {Email: $e, FirstName: $f, LastName: $l, SpectroTeam: $g} as $claims
          | {issuerUrl: env.I, clientId: env.C, clientSecret: env.S, logoutUrl: env.L,
             scopes: ($scopes | split(" ") | map(select(length > 0))), scopesDelimiter: " ",
             issuerTls: {caCertificateBase64: $ca, insecureSkipVerify: $skip},
             requiredClaims: $claims, userInfo: {useUserInfo: $userinfo, claims: $claims},
             defaultTeams: $teams, syncSsoTeams: $sync, isSsoEnabled: true}')
      tenant_apply "Tenant sign-on: OIDC with $TENANT_OIDC_ISSUER_URL" POST "$t/oidc/config" "$body" || return 0
      if [[ "$DRY_RUN" != true ]] && tenant_get "$t/oidc/config"; then
        callback=$(jq -r '.callbackUrl // empty' <<<"$API_BODY")
        if [[ -n "$callback" ]]; then NEXT+=("Register this redirect URI for client $TENANT_OIDC_CLIENT_ID at the identity provider: $callback"); fi
      fi ;;
    saml)
      body=$(P="${TENANT_SAML_IDENTITY_PROVIDER:-}" N="${TENANT_SAML_NAME_ID_FORMAT:-}" \
        jq -cn --rawfile md "$TENANT_SAML_METADATA_FILE" --argjson teams "$teams" --argjson sync "${TENANT_SSO_SYNC_TEAMS:-false}" \
          --argjson slo "${TENANT_SAML_SINGLE_LOGOUT:-false}" \
          '{federationMetadata: $md, identityProvider: env.P, nameIdFormat: env.N, isSingleLogoutEnabled: $slo,
            defaultTeams: $teams, syncSsoTeams: $sync, isSsoEnabled: true}')
      tenant_apply "Tenant sign-on: SAML from $(basename "$TENANT_SAML_METADATA_FILE")" POST "$t/saml/config" "$body" || true ;;
  esac
}

# --- Run -----------------------------------------------------------------------------------------
log "Settings"
load_system_env
check_system_env
if [[ "$DRY_RUN" == true ]]; then warn "Dry run: signing in and reading only; nothing will change."; fi

log "Reaching VerteX"
open_api
sign_in

log "System console"
configure_activation
configure_domain
configure_smtp
configure_proxies
configure_banners
configure_security
configure_admins
configure_backups

configure_tenant

log "Done: $APPLIED applied, $FAILED not applied, $SKIPPED waiting on the tenant admin$([[ "$DRY_RUN" == true ]] && echo " (dry run)")"
for n in ${NEXT[@]+"${NEXT[@]}"}; do printf '  \033[1m→\033[0m %s\n' "$n"; logf INFO "next: $n"; done
[[ $FAILED -eq 0 ]] || exit 1
