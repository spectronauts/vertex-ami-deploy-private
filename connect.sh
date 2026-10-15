#!/usr/bin/env bash
# Reach the private nodes from your workstation through the deployment's ACCESS_METHOD.
#
# Usage: ./connect.sh [-c config.env] <command>
#   localui      forward every node's Local UI: node N -> https://localhost:<5079+N>
#   link         link nodes 2..N to node 1 through the Local UI API, no clicking; signs in as
#                the user and password in USER_DATA_FILE (LOCALUI_USER, LOCALUI_PASSWORD override)
#   ssh [N]      shell on node N (default 1) as SSH_USER
#   api          forward the VIP's Kubernetes API to https://localhost:6443 (for kubectl)
#   kubeconfig [file]  copy node 1's admin kubeconfig, pointed at the api forward
#                (default file: kubeconfig-<NAME_PREFIX>)
#   nodes        list the nodes and their private IPs
# Forwards run until you press Ctrl-C.
#
# eice: SSH through the EC2 Instance Connect Endpoint (needs SSH_KEY_FILE); Local UI and the
#       API ride ssh -L through node 1, so they rely on node-to-node traffic.
# ssm:  port forwarding through the jump host with aws ssm start-session (needs
#       session-manager-plugin); SSH uses a forwarded port 22 on localhost:2222.

set -euo pipefail
[[ "${1:-}" == "-c" ]] && { CONFIG="$2"; shift 2; }
CMD="${1:-}"; ARG="${2:-1}"
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
case "$CMD" in
  nodes|localui|link|ssh|api|kubeconfig) require_aws ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac

# shellcheck disable=SC2207
IDS=($(node_ids)); IPS=($(node_ips))
[[ ${#IDS[@]} -gt 0 ]] || die "No running nodes for $NAME_PREFIX."

need_key() {
  require_tools ssh
  [[ -n "$SSH_KEY_FILE" ]] || die "Set SSH_KEY_FILE in $CONFIG to the private key for $KEY_NAME."
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH_KEY_FILE in $CONFIG points to $SSH_KEY_FILE, which doesn't exist."
}
eice_opts() {  # sets EICE_OPTS: the ssh options that reach a node through the endpoint
  need_key
  EICE_OPTS=(-i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
             -o ProxyCommand="aws ec2-instance-connect open-tunnel --region $REGION --instance-id %h")
}
eice_ssh() {  # extra ssh options... -> ssh to a node through the endpoint
  eice_opts
  ssh "${EICE_OPTS[@]}" "$@"
}
ssm_forward() {  # remote-host remote-port local-port  (runs in the background)
  local jump
  require_tools session-manager-plugin
  jump=$(instance_id jump); [[ -n "$jump" ]] || die "No jump host for $NAME_PREFIX (ACCESS_METHOD=ssm)."
  aws ssm start-session --target "$jump" --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"$2\"],\"localPortNumber\":[\"$3\"]}" >/dev/null &
}
wait_port() {  # local-port: wait until something listens on it
  local i
  for i in $(seq 1 30); do port_open localhost "$1" && return 0; sleep 1; done
  die "Nothing listening on localhost:$1 after 30 seconds."
}

# --- Local UI API: the calls Local UI's own pages make, on a node's port 5080 ------------------
LINK_API=/v1/edge-mgmt/edgehosts/current/link
ui_api() {  # local-port method path [json-body] -> response body; AUTH (a login JWT) from the environment
  # Returns 4 on HTTP 404 (quietly) and 1 on any other failure. The body goes on stdin, so a
  # password in it never shows in the process list.
  local port=$1 method=$2 path=$3 body=${4:-} out code
  local args=(-sk -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  if [[ -n "${AUTH:-}" ]]; then args+=(-H "Authorization: $AUTH"); fi
  if [[ -n "$body" ]]; then
    out=$(curl "${args[@]}" --data-binary @- "https://localhost:$port$path" <<<"$body") || return 1
  else
    out=$(curl "${args[@]}" "https://localhost:$port$path") || return 1
  fi
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ "$code" == 404 ]]; then return 4; fi
  if [[ ! "$code" =~ ^2 ]]; then
    warn "$method $path: HTTP $code $(jq -r '.message // empty' <<<"$out" 2>/dev/null || true)"
    return 1
  fi
  printf '%s\n' "$out"
}
userdata_login() {  # user-data-file -> "user<TAB>passwd" for the first user under users:
  awk -v q="'" '
    /^[[:space:]]*-?[[:space:]]*users:[[:space:]]*$/ { inusers = 1; uind = -1; next }
    inusers && /^[[:space:]]*$/ { next }
    inusers {
      match($0, /^[[:space:]]*/); ind = RLENGTH
      if (uind < 0) {
        if ($0 !~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/) exit
        uind = ind; user = $0; gsub(/[[:space:]:]/, "", user); next
      }
      if (ind <= uind) exit                     # the next user, or the end of the block
      if ($0 ~ /^[[:space:]]*passwd:/) {
        pw = $0; sub(/^[[:space:]]*passwd:[[:space:]]*/, "", pw)
        c = substr(pw, 1, 1); out = ""
        if (c == q) {                           # single-quoted: '' is a literal quote
          for (i = 2; i <= length(pw); i++) {
            ch = substr(pw, i, 1)
            if (ch == q) { if (substr(pw, i + 1, 1) == q) { out = out q; i++ } else break }
            else out = out ch
          }
          pw = out
        } else if (c == "\"") {                 # double-quoted: \" and \\ are escapes
          for (i = 2; i <= length(pw); i++) {
            ch = substr(pw, i, 1)
            if (ch == "\\") { i++; out = out substr(pw, i, 1) }
            else if (ch == "\"") break
            else out = out ch
          }
          pw = out
        } else sub(/[[:space:]]+#.*$/, "", pw)
      }
    }
    END { if (user != "") printf "%s\t%s\n", user, pw }
  ' "$1"
}
localui_credentials() {  # sets LOCALUI_USER, LOCALUI_PASS and LOCALUI_FROM (where the password came from)
  local ud_user="" ud_pass=""
  if [[ -f "$USER_DATA_FILE" ]]; then
    IFS=$'\t' read -r ud_user ud_pass < <(userdata_login "$USER_DATA_FILE") || true
  fi
  LOCALUI_USER="${LOCALUI_USER:-${ud_user:-fusion}}"
  LOCALUI_PASS="${LOCALUI_PASSWORD:-}"; LOCALUI_FROM="LOCALUI_PASSWORD"
  # A hashed passwd ($6$...) can't be used to sign in; nor can another user's.
  if [[ -z "$LOCALUI_PASS" && -n "$ud_pass" && "$ud_pass" != \$* && "$LOCALUI_USER" == "$ud_user" ]]; then
    LOCALUI_PASS=$ud_pass; LOCALUI_FROM="$USER_DATA_FILE"
  fi
  if [[ -z "$LOCALUI_PASS" ]]; then
    read -r -s -p "Local UI password for $LOCALUI_USER: " LOCALUI_PASS; echo >&2; LOCALUI_FROM="prompt"
  fi
  [[ -n "$LOCALUI_PASS" ]] || die "No Local UI password for $LOCALUI_USER."
}
ui_login() {  # local-port -> a login JWT for LOCALUI_USER, password in LOCALUI_PASS
  local body
  body=$(LOCALUI_USER="$LOCALUI_USER" LOCALUI_PASS="$LOCALUI_PASS" \
         jq -cn '{username: env.LOCALUI_USER, password: env.LOCALUI_PASS}')
  AUTH="" ui_api "$1" POST '/v1/users/default/login?extendedSession=true' "$body" | jq -r '.Token.Authorization // empty'
}
peer_state() {  # link-status-json ip -> "status<TAB>content<TAB>health", empty if node 1 doesn't list ip
  jq -r --arg ip "$2" '[.peers[]? | select(.ip == $ip)][0] // empty
    | "\(.status // "-")\t\(.contentSyncStatus // "-")\t\(.health.status // "-")"' <<<"$1"
}
peer_ready() {  # status content health -> 0 once the node is Ready, Synced and Healthy
  [[ "$(lower "$1")" == ready && "$(lower "$3")" == healthy ]] || return 1
  case "$(lower "$2")" in synced|completed|success|succeeded|done) return 0 ;; esac
  return 1
}
link_nodes() {  # base-port node-count: node N's Local UI is forwarded to localhost:<base-port + N - 1>
  local base=$1 n=$2 i p t st res lt try tick label
  local tok=()
  for ((i = 0; i < n; i++)); do
    t=""
    for try in 1 2 3; do
      t=$(ui_login $((base + i))) || t=""
      if [[ -n "$t" ]]; then break; fi
      sleep 5
    done
    [[ -n "$t" ]] || die "Could not sign in to Local UI on node $((i + 1)) as $LOCALUI_USER (wrong password, or Local UI not up yet: it starts 25-30 minutes after launch)."
    tok+=("$t")
  done
  ok "Signed in to Local UI on all $n nodes as $LOCALUI_USER"

  for ((i = 1; i < n; i++)); do
    p=$((base + i)); label="node $((i + 1)) (${IPS[$i]})"
    st=$(AUTH=${tok[$i]} ui_api "$p" GET "$LINK_API/status" | jq -r '.status // empty') || st=""
    if [[ "$st" == Completed ]]; then check_line "$label already linked"; continue; fi
    # A link token holds node 1's IP and a one-time password that lasts two minutes: get a fresh one.
    lt=$(AUTH=${tok[0]} ui_api "$base" POST "$LINK_API/generate-token" | jq -r '.token // empty') || lt=""
    [[ -n "$lt" ]] || die "Node 1 did not return a link token."
    AUTH=${tok[$i]} ui_api "$p" POST "$LINK_API" "$(jq -cn --arg t "$lt" '{token: $t}')" >/dev/null \
      || die "$label did not accept node 1's link token."
    st=""
    for ((tick = 0; tick < 1200; tick++)); do          # up to 5 minutes, in quarter seconds
      if (( tick % 20 == 0 )); then                    # ask every 5 seconds
        res=$(AUTH=${tok[$i]} ui_api "$p" GET "$LINK_API/status") || res='{}'
        st=$(jq -r '.status // empty' <<<"$res")
        if [[ "$st" == Completed ]]; then break; fi
        if [[ "$st" == Failed ]]; then
          end_line; die "Linking $label failed: $(jq -r '.errorMessage // "no message"' <<<"$res")"
        fi
      fi
      spin_line "$tick" "$label linking${st:+ ($st)}"
      sleep 0.25
    done
    if [[ "$st" != Completed ]]; then end_line; die "$label link still ${st:-pending} after 5 minutes."; fi
    check_line "$label linked"
  done
  wait_synced "$base" "$n" "${tok[0]}"
}
wait_synced() {  # base-port node-count leader-jwt: one line per node until node 1 shows it Ready, Synced, Healthy
  local base=$1 n=$2 jwt=$3 i tick res state s c h all drawn=0
  local text=() ready=() shown=()
  log "Waiting for node 1 to show every node Ready, Synced and Healthy"
  for ((tick = 0; tick < 2400; tick++)); do            # up to 10 minutes, in quarter seconds
    if (( tick % 20 == 0 )); then
      res=$(AUTH=$jwt ui_api "$base" GET "$LINK_API/status") || res='{}'
      all=1
      for ((i = 0; i < n; i++)); do
        state=$(peer_state "$res" "${IPS[$i]}")
        if [[ -z "$state" ]]; then
          ready[$i]=0
          if [[ $i -eq 0 ]]; then ready[$i]=1; text[$i]="node 1 (${IPS[0]}) leader"
          else text[$i]="node $((i + 1)) (${IPS[$i]}) not listed by node 1 yet"; fi
        else
          IFS=$'\t' read -r s c h <<<"$state"
          text[$i]="node $((i + 1)) (${IPS[$i]}) $s, $c, $h"
          if peer_ready "$s" "$c" "$h"; then ready[$i]=1; else ready[$i]=0; fi
        fi
        if [[ ${ready[$i]} -eq 0 ]]; then all=0; fi
      done
    fi
    if [[ -t 1 ]]; then                                # redraw the lines in place
      if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$n"; fi
      for ((i = 0; i < n; i++)); do
        if [[ ${ready[$i]} -eq 1 ]]; then printf '\r\033[K  %s %s\n' "$GREEN_CHECK" "${text[$i]}"
        else printf '\r\033[K  %s %s\n' "${SPIN[$((tick % 4))]}" "${text[$i]}"; fi
      done
      drawn=1
    elif (( tick % 20 == 0 )); then                    # not a terminal: print what changed
      for ((i = 0; i < n; i++)); do
        if [[ "${shown[$i]:-}" != "${text[$i]}" ]]; then
          if [[ ${ready[$i]} -eq 1 ]]; then echo "  ✓ ${text[$i]}"; else echo "  … ${text[$i]}"; fi
          shown[$i]=${text[$i]}
        fi
      done
    fi
    if [[ $all -eq 1 ]]; then ok "All $n nodes are linked: Ready, Synced and Healthy"; return 0; fi
    sleep 0.25
  done
  die "After 10 minutes not every node is Ready, Synced and Healthy. Node 1 lists: $(jq -r '[.peers[]? | .ip // "?"] | join(", ")' <<<"$res")"
}

case "$CMD" in
  nodes)
    for i in "${!IDS[@]}"; do echo "node $((i + 1))  ${IDS[$i]}  ${IPS[$i]}"; done ;;

  localui)
    # Browsers share cookies across ports on one host name, so give each node its own
    # name for the loopback address; otherwise signing in to one node signs you out of another.
    hosts=(localhost 127.0.0.1 "[::1]")
    echo "Local UI (accept the certificate warning; node 1 is the leader):"
    for i in "${!IPS[@]}"; do
      if [[ $i -lt ${#hosts[@]} ]]; then
        echo "  node $((i + 1)) (${IPS[$i]}): https://${hosts[$i]}:$((5080 + i))"
      else
        echo "  node $((i + 1)) (${IPS[$i]}): https://localhost:$((5080 + i))  (in a private window)"
      fi
    done
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      fwd=(-L 5080:localhost:5080)
      for ((i = 1; i < ${#IPS[@]}; i++)); do fwd+=(-L "$((5080 + i)):${IPS[$i]}:5080"); done
      echo "Forwarding through node 1 (${IDS[0]}); Ctrl-C to stop."
      eice_ssh -N "${fwd[@]}" "$SSH_USER@${IDS[0]}"
    else
      trap 'kill $(jobs -p) 2>/dev/null' EXIT
      for i in "${!IPS[@]}"; do ssm_forward "${IPS[$i]}" 5080 "$((5080 + i))"; done
      echo "Forwarding through the jump host; Ctrl-C to stop."
      wait
    fi ;;

  link)
    # Link nodes 2..N to node 1 the way Local UI's Linked Edge Hosts page does, then wait until
    # node 1 lists every node Ready, Synced and Healthy. Safe to re-run: linked nodes are skipped.
    [[ ${#IDS[@]} -ge 2 ]] || die "Linking needs at least two nodes."
    require_tools curl jq
    localui_credentials
    ok "Local UI user $LOCALUI_USER, password from $LOCALUI_FROM"
    base=15080   # local ports clear of ./connect.sh localui's, so both can run at once
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      fwd=(-L "$base:localhost:5080")
      for ((i = 1; i < ${#IPS[@]}; i++)); do fwd+=(-L "$((base + i)):${IPS[$i]}:5080"); done
      eice_opts
      ssh "${EICE_OPTS[@]}" -N -o ExitOnForwardFailure=yes "${fwd[@]}" "$SSH_USER@${IDS[0]}" &
    else
      for i in "${!IPS[@]}"; do ssm_forward "${IPS[$i]}" 5080 "$((base + i))"; done
    fi
    for i in "${!IPS[@]}"; do wait_port "$((base + i))"; done
    log "Linking nodes 2-${#IDS[@]} to node 1 (${IPS[0]}) through the Local UI API"
    link_nodes "$base" "${#IPS[@]}" ;;

  ssh)
    [[ "$ARG" =~ ^[0-9]+$ && $ARG -ge 1 && $ARG -le ${#IDS[@]} ]] || die "Node must be 1-${#IDS[@]}."
    n=$((ARG - 1))
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh "$SSH_USER@${IDS[$n]}"
    else
      need_key
      trap 'kill $(jobs -p) 2>/dev/null' EXIT
      ssm_forward "${IPS[$n]}" 22 2222; wait_port 2222
      ssh -i "$SSH_KEY_FILE" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@localhost"
    fi ;;

  kubeconfig)
    # Copy node 1's admin kubeconfig and point it at the ./connect.sh api forward. The API
    # certificate lists "kubernetes" and the VIP but not localhost, hence tls-server-name.
    out="${2:-kubeconfig-$NAME_PREFIX}"
    require_tools kubectl
    umask 077
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh "$SSH_USER@${IDS[0]}" 'sudo cat /etc/kubernetes/admin.conf' > "$out"
    else
      need_key
      trap 'kill $(jobs -p) 2>/dev/null' EXIT
      ssm_forward "${IPS[0]}" 22 2222; wait_port 2222
      ssh -i "$SSH_KEY_FILE" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "$SSH_USER@localhost" 'sudo cat /etc/kubernetes/admin.conf' > "$out"
    fi
    grep -q 'certificate-authority-data' "$out" || die "Could not read /etc/kubernetes/admin.conf from node 1 (is the cluster created?)."
    cluster=$(kubectl --kubeconfig "$out" config view -o jsonpath='{.clusters[0].name}')
    kubectl --kubeconfig "$out" config set-cluster "$cluster" --server=https://localhost:6443 --tls-server-name=kubernetes >/dev/null
    echo "Wrote $out (cluster-admin credentials; keep it private)."
    echo "Keep ./connect.sh api running in another terminal, then: kubectl --kubeconfig $out get nodes" ;;

  api)
    [[ -n "$NLB_PRIVATE_IP" ]] || die "NLB_PRIVATE_IP is not set."
    echo "Kubernetes API at https://localhost:6443 (kubeconfig: server https://localhost:6443, tls-server-name: kubernetes)."
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh -N -L "6443:$NLB_PRIVATE_IP:6443" "$SSH_USER@${IDS[0]}"
    else
      trap 'kill $(jobs -p) 2>/dev/null' EXIT
      ssm_forward "$NLB_PRIVATE_IP" 6443 6443; wait
    fi ;;

  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
