#!/usr/bin/env bash
# Reach the private nodes from your workstation through the deployment's ACCESS_METHOD.
#
# Usage: ./connect.sh [-c config.env] <command>
#   localui      forward every node's Local UI: node N -> https://localhost:<5079+N>
#   link         link nodes 2..N to node 1 through the Local UI API, no clicking; signs in as
#                the user and password in USER_DATA_FILE (LOCALUI_USER, LOCALUI_PASSWORD override);
#                then checks each node's data drive (as disks does)
#   disks        each node's data drive: the value for Storage Pool Drive in the cluster profile
#   wait         wait until every node's Local UI answers (25-30 minutes after launch), then show
#                the next steps (./deploy.sh --no-nlb does this itself)
#   ssh [N]      shell on node N (default 1) as SSH_USER
#   console [port]  forward the VIP's 443, VerteX's system console and tenant UI, to
#                https://localhost:<port> (default 8443): sign in at /system, or at / for a tenant
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
SCRIPT_ARGS=("$@")
[[ "${1:-}" == "-c" ]] && { CONFIG="$2"; shift 2; }
CMD="${1:-}"; ARG="${2:-1}"
cd "$(dirname "$0")"
case "$CMD" in
  nodes|localui|link|disks|wait|console|ssh|api|kubeconfig) LOG_NAME="connect-$CMD" ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
# shellcheck source=lib.sh
source ./lib.sh
require_aws

# shellcheck disable=SC2207
IDS=($(node_ids)); IPS=($(node_ips))
[[ ${#IDS[@]} -gt 0 ]] || die "No running nodes for $NAME_PREFIX."

# --- Data drives: what Storage Pool Drive in the cluster profile must name ------------------------
data_drives() {  # find each node's data volume (attached as /dev/sdb) on the node; save the common name
  local i vol out dev bytes vg first="" same=1
  log "Data drive on each node (Storage Pool Drive in the cluster profile)"
  for i in "${!IDS[@]}"; do
    vol=$(none_to_empty "$(aws_q ec2 describe-instances --instance-ids "${IDS[$i]}" \
        --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/sdb'].Ebs.VolumeId | [0]")")
    if [[ -z "$vol" ]]; then warn "node $((i + 1)) (${IPS[$i]}): no data volume attached as /dev/sdb"; same=0; continue; fi
    out=$(node_ssh "$i" "$(data_drive_script "$vol")") || out=""
    dev=""; bytes=0; vg="-"
    read -r dev bytes vg <<<"$out" || true
    if [[ -z "$dev" || "$dev" == none ]]; then
      warn "node $((i + 1)) (${IPS[$i]}): couldn't find $vol on the node (is it up? see the log)"; same=0; continue
    fi
    ok "node $((i + 1)) (${IPS[$i]}) data drive $dev: $((bytes / 1073741824)) GB ($vol$([[ "$vg" == - ]] || echo ", volume group $vg"))"
    first=${first:-$dev}
    if [[ "$dev" != "$first" ]]; then same=0; fi
  done
  if [[ $same -eq 1 && -n "$first" ]]; then
    ok "Storage Pool Drive for the cluster profile: $first"
    save_output DATA_DRIVE "$first"
  else
    warn "The nodes' data drives differ or couldn't all be read; Storage Pool Drive takes one name for every node."
  fi
}

# --- Local UI API: the calls Local UI's own pages make, on a node's port 5080 ------------------
LINK_API=/v1/edge-mgmt/edgehosts/current/link
ui_api() {  # local-port method path [json-body] -> response body; AUTH (a login JWT) from the environment
  # Returns 4 on HTTP 404 (quietly) and 1 on any other failure. The body goes on stdin, so a
  # password in it never shows in the process list. Each call is logged, secrets masked.
  local port=$1 method=$2 path=$3 body=${4:-} out code rc=0 t0 errf
  local args=(-sS -k --connect-timeout 10 --max-time 120 -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  if [[ -n "${AUTH:-}" ]]; then args+=(-H "Authorization: $AUTH"); fi
  errf=$(mktemp "$_LOG_TMP/curl.XXXXXX")
  t0=$(_clock)
  if [[ -n "$body" ]]; then
    out=$(curl "${args[@]}" --data-binary @- "https://localhost:$port$path" <<<"$body" 2>"$errf") || rc=$?
  else
    out=$(curl "${args[@]}" "https://localhost:$port$path" 2>"$errf") || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    logf WARN "Local UI $method $path on localhost:$port: curl exit $rc after $(_took "$t0"): $(tr '\n' ' ' <"$errf")"
    rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  code=${out##*$'\n'}; out=${out%$'\n'*}
  logf DEBUG "Local UI $method $path on localhost:$port${AUTH:+ (signed in)} -> HTTP $code in $(_took "$t0")"
  if [[ "$path" == */login* ]]; then
    log_text req "$(jq -c '.password = "<redacted>"' <<<"$body" 2>/dev/null || echo '(sign-in request)')"
  else
    log_text req "$body"
  fi
  log_text res "$out"
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
  local form="none"
  if [[ "$ud_pass" == \$* ]]; then form="hashed (can't sign in with it)"; elif [[ -n "$ud_pass" ]]; then form="plain text"; fi
  logf DEBUG "$USER_DATA_FILE: first user '${ud_user:-none}', passwd ${form}; LOCALUI_USER '${LOCALUI_USER}'"
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
      if [[ -n "$t" ]]; then logf INFO "Signed in to node $((i + 1)) (${IPS[$i]}, localhost:$((base + i))) on try $try"; break; fi
      logf WARN "Sign-in to node $((i + 1)) (${IPS[$i]}) failed on try $try of 3"
      sleep 5
    done
    [[ -n "$t" ]] || die "Could not sign in to Local UI on node $((i + 1)) as $LOCALUI_USER (wrong password, or Local UI not up yet: it starts 25-30 minutes after launch)."
    tok+=("$t")
  done
  ok "Signed in to Local UI on all $n nodes as $LOCALUI_USER"

  for ((i = 1; i < n; i++)); do
    p=$((base + i)); label="node $((i + 1)) (${IPS[$i]})"
    st=$(AUTH=${tok[$i]} ui_api "$p" GET "$LINK_API/status" | jq -r '.status // empty') || st=""
    logf INFO "$label link status before linking: ${st:-none (not linked)}"
    if [[ "$st" == Completed ]]; then check_line "$label already linked"; continue; fi
    # A link token holds node 1's IP and a one-time password that lasts two minutes: get a fresh one.
    lt=$(AUTH=${tok[0]} ui_api "$base" POST "$LINK_API/generate-token" | jq -r '.token // empty') || lt=""
    [[ -n "$lt" ]] || die "Node 1 did not return a link token."
    logf INFO "Node 1 issued a link token for $label (${#lt} characters, good for about two minutes)"
    AUTH=${tok[$i]} ui_api "$p" POST "$LINK_API" "$(jq -cn --arg t "$lt" '{token: $t}')" >/dev/null \
      || die "$label did not accept node 1's link token."
    logf INFO "$label accepted the link token; waiting for its link status to be Completed"
    st=""
    for ((tick = 0; tick < 1200; tick++)); do          # up to 5 minutes, in quarter seconds
      if (( tick % 20 == 0 )); then                    # ask every 5 seconds
        res=$(AUTH=${tok[$i]} ui_api "$p" GET "$LINK_API/status") || res='{}'
        st=$(jq -r '.status // empty' <<<"$res")
        logf DEBUG "$label link status: ${st:-unknown} after $((tick / 4))s"
        if [[ "$st" == Completed ]]; then break; fi
        if [[ "$st" == Failed ]]; then
          end_line; die "Linking $label failed: $(jq -r '.errorMessage // "no message"' <<<"$res")"
        fi
      fi
      spin_line "$tick" "$label linking${st:+ ($st)}"
      sleep 0.25
    done
    if [[ "$st" != Completed ]]; then end_line; die "$label link still ${st:-pending} after 5 minutes."; fi
    check_line "$label linked after $((tick / 4))s"
  done
  wait_synced "$base" "$n" "${tok[0]}"
}
wait_synced() {  # base-port node-count leader-jwt: one line per node until node 1 shows it Ready, Synced, Healthy
  local base=$1 n=$2 jwt=$3 i tick res state s c h all drawn=0
  local text=() ready=() shown=() logged=()
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
        if [[ "${logged[$i]:-}" != "${text[$i]}" ]]; then logf INFO "${text[$i]} (after $((tick / 4))s)"; logged[$i]=${text[$i]}; fi
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
      QUIET_EXIT=true
      eice_ssh -N "${fwd[@]}" "$SSH_USER@${IDS[0]}"
    else
      KILL_JOBS_ON_EXIT=true; QUIET_EXIT=true
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
    KILL_JOBS_ON_EXIT=true
    fwd_out=""
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      fwd=(-L "$base:localhost:5080")
      for ((i = 1; i < ${#IPS[@]}; i++)); do fwd+=(-L "$((base + i)):${IPS[$i]}:5080"); done
      eice_opts
      fwd_out="$_LOG_TMP/ssh-forward.bg"   # ssh -v: connection details for the log
      ssh "${EICE_OPTS[@]}" -v -N -o ExitOnForwardFailure=yes "${fwd[@]}" "$SSH_USER@${IDS[0]}" 2>"$fwd_out" &
      logf INFO "ssh forward (pid $!): ssh $(_quote_args "${EICE_OPTS[@]}" -v -N -o ExitOnForwardFailure=yes "${fwd[@]}" "$SSH_USER@${IDS[0]}")"
    else
      SSM_QUIET=true
      for i in "${!IPS[@]}"; do ssm_forward "${IPS[$i]}" 5080 "$((base + i))"; done
    fi
    for i in "${!IPS[@]}"; do wait_port "$((base + i))" "${fwd_out:-$_LOG_TMP/ssm-localhost-$((base + i)).bg}"; done
    log "Linking nodes 2-${#IDS[@]} to node 1 (${IPS[0]}) through the Local UI API"
    link_nodes "$base" "${#IPS[@]}"
    data_drives ;;

  disks)
    data_drives ;;

  wait)
    wait_local_ui || exit 1
    next_steps nodes ;;

  ssh)
    [[ "$ARG" =~ ^[0-9]+$ && $ARG -ge 1 && $ARG -le ${#IDS[@]} ]] || die "Node must be 1-${#IDS[@]}."
    n=$((ARG - 1))
    QUIET_EXIT=true   # the session's own exit code is not a script failure
    logf INFO "Shell on node $ARG (${IDS[$n]}, ${IPS[$n]}) as $SSH_USER"
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh "$SSH_USER@${IDS[$n]}"
    else
      need_key
      KILL_JOBS_ON_EXIT=true
      ssm_forward "${IPS[$n]}" 22 2222; wait_port 2222 "$_LOG_TMP/ssm-localhost-2222.bg"
      logf INFO "ssh -i $SSH_KEY_FILE -p 2222 $SSH_USER@localhost"
      rc=0; ssh -i "$SSH_KEY_FILE" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@localhost" || rc=$?
      logf INFO "ssh exited $rc"; exit $rc
    fi ;;

  kubeconfig)
    # Copy node 1's admin kubeconfig and point it at the ./connect.sh api forward. The API
    # certificate lists "kubernetes" and the VIP but not localhost, hence tls-server-name.
    out="${2:-kubeconfig-$NAME_PREFIX}"
    require_tools kubectl
    umask 077
    errf="$_LOG_TMP/ssh-kubeconfig.err"; rc=0
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh "$SSH_USER@${IDS[0]}" 'sudo cat /etc/kubernetes/admin.conf' > "$out" 2>"$errf" || rc=$?
    else
      need_key
      KILL_JOBS_ON_EXIT=true
      ssm_forward "${IPS[0]}" 22 2222; wait_port 2222 "$_LOG_TMP/ssm-localhost-2222.bg"
      logf INFO "ssh -i $SSH_KEY_FILE -p 2222 $SSH_USER@localhost 'sudo cat /etc/kubernetes/admin.conf'"
      ssh -i "$SSH_KEY_FILE" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "$SSH_USER@localhost" 'sudo cat /etc/kubernetes/admin.conf' > "$out" 2>"$errf" || rc=$?
    fi
    log_file err "$errf"
    logf INFO "ssh exited $rc; $out is $(wc -c <"$out" | tr -d ' ') bytes (contents not logged: cluster-admin credentials)"
    grep -q 'certificate-authority-data' "$out" \
      || die "Could not read /etc/kubernetes/admin.conf from node 1 (is the cluster created?). $(tail -2 "$errf" | tr '\n' ' ')"
    cluster=$(kubectl --kubeconfig "$out" config view -o jsonpath='{.clusters[0].name}')
    logf INFO "kubeconfig cluster '$cluster', server was $(kubectl --kubeconfig "$out" config view -o jsonpath='{.clusters[0].cluster.server}')"
    kubectl --kubeconfig "$out" config set-cluster "$cluster" --server=https://localhost:6443 --tls-server-name=kubernetes >/dev/null
    logf INFO "pointed cluster '$cluster' at https://localhost:6443 with tls-server-name kubernetes"
    echo "Wrote $out (cluster-admin credentials; keep it private)."
    echo "Keep ./connect.sh api running in another terminal, then: kubectl --kubeconfig $out get nodes" ;;

  console)
    # The VerteX UI on the VIP's 443, at https://localhost:<port>. A normal user can't listen on
    # ports below 1024 (macOS refuses it on the loopback address too), hence 8443.
    port="${2:-8443}"
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || die "Port must be a number, for example 8443."
    [[ -n "$NLB_PRIVATE_IP" ]] || die "NLB_PRIVATE_IP is not set in $CONFIG."
    [[ -n "$(nlb_arn)" ]] || die "No NLB yet: VerteX is reached on the VIP, which the NLB provides (./deploy.sh after Deploy Cluster)."
    if [[ $port -lt 1024 && $(id -u) -ne 0 ]]; then
      die "Only root can listen on localhost:$port. Use a port from 1024 up: ./connect.sh console 8443"
    fi
    if port_open localhost "$port"; then die "Something already listens on localhost:$port (another forward?). Pick another port: ./connect.sh console <port>"; fi
    KILL_JOBS_ON_EXIT=true; QUIET_EXIT=true
    url="https://localhost:$port"; [[ $port -eq 443 ]] && url="https://localhost"
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_opts
      fwd_out="$_LOG_TMP/ssh-console-forward.bg"
      ssh "${EICE_OPTS[@]}" -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L "$port:$NLB_PRIVATE_IP:443" \
          "$SSH_USER@${IDS[0]}" 2>>"$fwd_out" &
      logf INFO "console forward (pid $!): localhost:$port -> $NLB_PRIVATE_IP:443 through node 1 (${IDS[0]})"
    else
      SSM_QUIET=true; ssm_forward "$NLB_PRIVATE_IP" 443 "$port"; fwd_out="$_LOG_TMP/ssm-localhost-$port.bg"
    fi
    fwd_pid=$!
    wait_port "$port" "$fwd_out"
    code=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "https://localhost:$port/v1/auth/sso/providers" || true)
    logf INFO "VerteX API check through the forward: HTTP ${code:-none}"
    case "$code" in
      2*|401|403) ok "VerteX answers on the VIP $NLB_PRIVATE_IP:443" ;;
      *) warn "VerteX did not answer yet (HTTP ${code:-none}); is port 443 healthy? ./status.sh" ;;
    esac
    echo
    echo "  System console:  $url/system     (admin; a new install's password is admin)"
    echo "  Tenant console:  $url/           (a tenant's users, after it is activated)"
    echo "  Accept the certificate warning until VerteX has your certificate. Ctrl-C to stop."
    domain=""   # DOMAIN_HOST from system.env, if there is one
    if [[ -f system.env ]]; then domain=$(sed -nE 's/^DOMAIN_HOST="?([^"]*)"?.*/\1/p' system.env | head -1) || domain=""; fi
    if [[ -n "$domain" ]]; then
      echo "  To use $domain (its certificate): add \"127.0.0.1 $domain\" to /etc/hosts, then open"
      echo "  https://$domain$([[ $port -eq 443 ]] || echo ":$port")/system"
    fi
    echo
    wait "$fwd_pid" || true
    if [[ -s "$fwd_out" ]] && grep -qiE 'error|denied|refused|closed' "$fwd_out"; then
      warn "The forward stopped: $(grep -iE 'error|denied|refused|closed' "$fwd_out" | tail -1)"; exit 1
    fi ;;

  api)
    [[ -n "$NLB_PRIVATE_IP" ]] || die "NLB_PRIVATE_IP is not set."
    echo "Kubernetes API at https://localhost:6443 (kubeconfig: server https://localhost:6443, tls-server-name: kubernetes)."
    QUIET_EXIT=true
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      eice_ssh -N -L "6443:$NLB_PRIVATE_IP:6443" "$SSH_USER@${IDS[0]}"
    else
      KILL_JOBS_ON_EXIT=true
      ssm_forward "$NLB_PRIVATE_IP" 6443 6443; wait
    fi ;;

  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
