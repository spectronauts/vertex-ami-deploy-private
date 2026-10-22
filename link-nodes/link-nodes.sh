#!/usr/bin/env bash
# link-nodes.sh: link VerteX appliance nodes through the Local UI API.
#
# Nodes 2..N join node 1 (the leader), the way the Local UI Linked Edge Hosts page does it. The
# script then waits until node 1 lists every node Ready, Synced and Healthy. Safe to run again:
# nodes that are already linked are skipped.
#
# Usage: ./link-nodes.sh -u <user> <node1> <node2> [<node3> ...]
#   <nodeN>  how this machine reaches node N's Local UI: an IP address or host name, with an
#            optional :port (default 5080). Node 1 is the leader. IPv6: [fd00::10]:5080
#   -u user  the Local UI user (the user in the nodes' user data)
#   -h       this help
# The password is read from the LOCALUI_PASSWORD environment variable, or asked for.
#
# Needs bash, curl and jq. Local UI uses a self-signed certificate, so the certificate is not
# verified. Each run writes link-nodes-<time>.log in the current folder, without the password
# or any token.

set -euo pipefail

USER_NAME=""
while getopts ":u:h" opt; do
  case "$opt" in
    u) USER_NAME=$OPTARG ;;
    h) sed -n '2,17p' "$0"; exit 0 ;;
    *) sed -n '2,17p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 2 ]] || { sed -n '2,17p' "$0" >&2; exit 2; }

# --- Output and log -----------------------------------------------------------------------------
LOG="link-nodes-$(date -u +%Y%m%dT%H%M%SZ).log"
(umask 077; : >"$LOG")
logf() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >>"$LOG"; }
say()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; logf "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; logf "OK $*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; logf "WARN $*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; logf "ERROR $*"; printf '  Log: %s\n' "$LOG" >&2; exit 1; }
trap 'printf "\n"; logf "Interrupted"; exit 130' INT TERM

COLS=$( { stty size 2>/dev/null </dev/tty || echo "0 80"; } 2>/dev/null | awk '{print $2}' )
[[ "$COLS" =~ ^[0-9]+$ && $COLS -ge 40 ]] || COLS=80
SPIN=('|' '/' '-' '\')
CHECK=$'\033[1;32m✓\033[0m'
fit() { local t=$1; if (( ${#t} > COLS - 6 )); then t="${t:0:$((COLS - 7))}~"; fi; printf '%s' "$t"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required. Install it (for example: brew install $tool, apt-get install $tool or dnf install $tool) and run again."
done

# --- Nodes --------------------------------------------------------------------------------------
N=$#
URLS=()
for a in "$@"; do
  if [[ "$a" == \[*\]:* || ( "$a" != \[* && "$a" == *:* ) ]]; then URLS+=("https://$a")
  else URLS+=("https://$a:5080"); fi
done
label() { printf 'node %d (%s)' $(($1 + 1)) "${URLS[$1]#https://}"; }
logf "link-nodes.sh: $N nodes: ${URLS[*]}; user ${USER_NAME:-<asked>}"

if [[ -z "$USER_NAME" ]]; then read -r -p "Local UI user: " USER_NAME; fi
[[ -n "$USER_NAME" ]] || die "No Local UI user given (-u)."
PASS=${LOCALUI_PASSWORD:-}
if [[ -z "$PASS" ]]; then read -r -s -p "Local UI password for $USER_NAME: " PASS; echo; fi
[[ -n "$PASS" ]] || die "No password given."

# --- Local UI API -------------------------------------------------------------------------------
API_STATUS=""; API_BODY=""
api() {  # node-index method path [json-body]: sets API_STATUS and API_BODY; 0 on HTTP 2xx
  local i=$1 method=$2 path=$3 body=${4:-} out rc=0
  local args=(-sS -k --connect-timeout 10 --max-time 120 -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  if [[ -n "${AUTH:-}" ]]; then args+=(-H "Authorization: $AUTH"); fi
  if [[ -n "$body" ]]; then
    out=$(curl "${args[@]}" --data-binary @- "${URLS[$i]}$path" <<<"$body" 2>&1) || rc=$?
  else
    out=$(curl "${args[@]}" "${URLS[$i]}$path" 2>&1) || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    API_STATUS=000; API_BODY=$out
    logf "node $((i + 1)) $method $path: no answer (curl $rc): ${out//$'\n'/ }"
    return 1
  fi
  API_STATUS=${out##*$'\n'}; API_BODY=${out%$'\n'*}
  # The log gets the status and the response with every password, token and key masked.
  logf "node $((i + 1)) $method $path -> HTTP $API_STATUS $(jq -c 'def r: if type == "object" then with_entries(if (.key | test("pass|token|authorization|key|secret"; "i")) and (.value | type) == "string" then .value = "<redacted>" else .value |= r end) elif type == "array" then map(r) else . end; r' <<<"$API_BODY" 2>/dev/null || echo "(${#API_BODY} bytes)")"
  [[ "$API_STATUS" =~ ^2 ]]
}
api_error() { printf 'HTTP %s%s' "$API_STATUS" "$( { jq -r '.message // empty' <<<"$API_BODY" 2>/dev/null || true; } | head -c 200 | sed 's/^/: /')"; }

LINK=/v1/edge-mgmt/edgehosts/current/link
TOKENS=(); IDS=(); IPS=()

# --- 1. Sign in to every node -------------------------------------------------------------------
say "Signing in to Local UI on $N nodes as $USER_NAME"
body=$(U="$USER_NAME" P="$PASS" jq -cn '{username: env.U, password: env.P}')
for ((i = 0; i < N; i++)); do
  t=""
  for try in 1 2 3; do
    if AUTH="" api "$i" POST '/v1/users/default/login?extendedSession=true' "$body"; then
      t=$(jq -r '.Token.Authorization // empty' <<<"$API_BODY")
      if [[ -n "$t" ]]; then break; fi
    fi
    logf "sign-in to node $((i + 1)) failed (try $try of 3): $(api_error)"
    # A refused password isn't retried: failed sign-ins count toward Local UI's lockout.
    if [[ "$API_STATUS" == 401 || "$API_STATUS" == 403 ]]; then break; fi
    sleep 5
  done
  [[ -n "$t" ]] || die "Could not sign in to $(label "$i") as $USER_NAME ($(api_error)). Check the address, the user and the password; Local UI answers about 25-30 minutes after a node starts."
  TOKENS[$i]=$t
  # Who the node is, so node 1's list of linked nodes can be matched to it: its edge host ID
  # and its IP addresses.
  IDS[$i]=""; IPS[$i]=" "
  if AUTH=$t api "$i" GET /v1/edge-mgmt/edgehosts/current; then
    IDS[$i]=$(jq -r '.metadata.id // empty' <<<"$API_BODY")
    IPS[$i]=" $(jq -r '[.spec.networkInfo[]?.ip // empty] | join(" ")' <<<"$API_BODY") "
  fi
  host=${URLS[$i]#https://}; host=${host%:*}; host=${host#[}; host=${host%]}
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "${IPS[$i]}" != *" $host "* ]]; then IPS[$i]+="$host "; fi
  ok "$(label "$i") signed in${IDS[$i]:+: edge host ${IDS[$i]}}"
done

# --- 2. Link nodes 2..N to node 1 ---------------------------------------------------------------
link_one() {  # node-index
  local i=$1 st="" res lt tick
  AUTH=${TOKENS[$i]} api "$i" GET "$LINK/status" || true
  st=$(jq -r '.status // empty' <<<"$API_BODY" 2>/dev/null || true)
  if [[ "$API_STATUS" =~ ^2 && "$st" == Completed ]]; then ok "$(label "$i") already linked"; return 0; fi
  # A link token holds node 1's address and a one-time password valid for two minutes: get a
  # fresh one for each node.
  AUTH=${TOKENS[0]} api 0 POST "$LINK/generate-token" || die "Node 1 did not give a link token ($(api_error))."
  lt=$(jq -r '.token // empty' <<<"$API_BODY"); [[ -n "$lt" ]] || die "Node 1 gave an empty link token."
  AUTH=${TOKENS[$i]} api "$i" POST "$LINK" "$(jq -cn --arg t "$lt" '{token: $t}')" \
    || die "$(label "$i") did not accept node 1's link token ($(api_error))."
  for ((tick = 0; tick < 1200; tick++)); do                 # up to 5 minutes
    if (( tick % 20 == 0 )); then                           # ask every 5 seconds
      if AUTH=${TOKENS[$i]} api "$i" GET "$LINK/status"; then res=$API_BODY; else res='{}'; fi
      st=$(jq -r '.status // empty' <<<"$res" 2>/dev/null || true)
      if [[ "$st" == Completed ]]; then break; fi
      if [[ "$st" == Failed ]]; then
        [[ -t 1 ]] && printf '\n'
        die "Linking $(label "$i") failed: $(jq -r '.errorMessage // "no message"' <<<"$res")"
      fi
    fi
    if [[ -t 1 ]]; then printf '\r\033[K  %s %s' "${SPIN[$((tick % 4))]}" "$(fit "$(label "$i") linking${st:+ ($st)}  $((tick / 4))s")"; fi
    sleep 0.25
  done
  [[ -t 1 ]] && printf '\r\033[K'
  [[ "$st" == Completed ]] || die "$(label "$i") is still ${st:-pending} after 5 minutes."
  ok "$(label "$i") linked"
}
say "Linking nodes 2-$N to node 1 (${URLS[0]#https://})"
for ((i = 1; i < N; i++)); do link_one "$i"; done

# --- 3. Wait until node 1 shows every node Ready, Synced and Healthy ----------------------------
peer_of() {  # status-json node-index: "status<TAB>content<TAB>health" of that node in node 1's list
  jq -r --arg id "${IDS[$2]}" --arg ips "${IPS[$2]}" '
    [.peers[]? | . as $p | select(($id != "" and $p.id == $id) or ($p.ip != null and ($ips | contains(" " + $p.ip + " "))))][0] // empty
    | "\(.status // "-")\t\(.contentSyncStatus // "-")\t\(.health.status // "-")"' <<<"$1"
}
ready() {  # status content health
  [[ "$(lower "$1")" == ready && "$(lower "$3")" == healthy ]] || return 1
  case "$(lower "$2")" in synced|completed|success|succeeded|done) return 0 ;; esac
  return 1
}
say "Waiting for node 1 to show every node Ready, Synced and Healthy"
text=(); done_=(); shown=(); drawn=0; res='{}'
for ((tick = 0; tick < 3600; tick++)); do                   # up to 15 minutes
  if (( tick % 20 == 0 )); then
    if AUTH=${TOKENS[0]} api 0 GET "$LINK/status"; then res=$API_BODY; else res='{}'; fi
    all=1
    for ((i = 0; i < N; i++)); do
      state=$(peer_of "$res" "$i")
      if [[ -z "$state" ]]; then
        if [[ $i -eq 0 ]]; then done_[$i]=1; text[$i]="$(label 0): the leader"
        else done_[$i]=0; text[$i]="$(label "$i"): not in node 1's list yet"; fi
      else
        IFS=$'\t' read -r s c h <<<"$state"
        text[$i]="$(label "$i"): $s, $c, $h"
        if ready "$s" "$c" "$h"; then done_[$i]=1; else done_[$i]=0; fi
      fi
      [[ ${done_[$i]} -eq 1 ]] || all=0
      if [[ "${shown[$i]:-}" != "${text[$i]}" ]]; then
        logf "${text[$i]}"; shown[$i]=${text[$i]}
        if [[ ! -t 1 ]]; then echo "  ${text[$i]}"; fi
      fi
    done
  fi
  if [[ -t 1 ]]; then                                       # one line per node, redrawn in place
    if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$N"; fi
    for ((i = 0; i < N; i++)); do
      if [[ ${done_[$i]} -eq 1 ]]; then printf '\r\033[K  %s %s\n' "$CHECK" "$(fit "${text[$i]}")"
      else printf '\r\033[K  %s %s\n' "${SPIN[$((tick % 4))]}" "$(fit "${text[$i]}")"; fi
    done
    drawn=1
  fi
  if [[ $all -eq 1 ]]; then
    ok "All $N nodes are linked: Ready, Synced and Healthy"
    echo
    echo "  Next, in Local UI on node 1 (${URLS[0]}):"
    echo "    Cluster > Create cluster, with all $N nodes in Node Config."
    echo "  Log: $LOG"
    exit 0
  fi
  sleep 0.25
done
die "After 15 minutes not every node is Ready, Synced and Healthy. Node 1 lists: $(jq -r '[.peers[]? | "\(.ip // "?") \(.status // "-")/\(.contentSyncStatus // "-")/\(.health.status // "-")"] | join(", ")' <<<"$res")"
