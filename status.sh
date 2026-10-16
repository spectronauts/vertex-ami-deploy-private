#!/usr/bin/env bash
# What deploy.sh built: instances, the access path, the NLB (VIP) and target health.
#
# Usage: ./status.sh [-c config.env] [--watch [--no-repair]]
#   --watch      keep checking the NLB and each port's target health: one updating line each,
#                with the elapsed time, until the NLB is active and every port is healthy on
#                every node (Ctrl-C to stop). It also watches the install on node 1 and repairs
#                two known failures if they occur and persist:
#                  storage  the piraeus-cluster chart lost a race with cert-manager, so there
#                           are no LINSTOR storage classes (zot's volume stays Pending, 30003
#                           never turns healthy)
#                  mongodb  mongo.key in hubble-system/spectro-mongodb-replicaset-key is empty,
#                           so mongo-0 waits in Init (443 never turns healthy)
#                The install checks need SSH_KEY_FILE, kubectl and jq; each step is in the log.
#   --no-repair  with --watch: report those two failures, but don't change anything

set -euo pipefail
SCRIPT_ARGS=("$@")
WATCH="false"
REPAIR="true"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="$2"; shift 2 ;;
    --watch) WATCH="true"; shift ;;
    --no-repair) REPAIR="false"; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_aws

tg_arn() {  # port -> this deployment's target group ARN for it, or empty
  none_to_empty "$(aws_q elbv2 describe-target-groups --names "${NAME_PREFIX}-tg-$1" --query 'TargetGroups[0].TargetGroupArn' || true)"
}
port_health() {  # target-group-arn -> "healthy total other-states"
  local states h=0 t=0 s
  states=$(aws_q elbv2 describe-target-health --target-group-arn "$1" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' | tr '\t' '\n')
  for s in $states; do t=$((t + 1)); if [[ "$s" == healthy ]]; then h=$((h + 1)); fi; done
  echo "$h $t $(printf '%s\n' $states | awk '$0 != "healthy" && NF {c[$0]++}
      END {n = 0; for (k in c) printf "%s%d %s", (n++ ? ", " : ""), c[k], k}')"
}

# --- Install checks and repairs (--watch) -------------------------------------------------------
# kubectl reaches node 1's own API server through a forward (it answers before the NLB does),
# with node 1's admin kubeconfig kept in the run's private scratch directory, never the log.
# A failure is repaired only after it has lasted a while, so a normal install in progress is
# never touched; each repair runs at most twice.
IC_ON="false"; IC_KCFG=""; IC_PORT=""; IC_FWD_PID=""; IC_SSH_PORT=""; IC_NEXT_CONF=0; IC_PRINTED=0
ST_TEXT="storage: waiting for Kubernetes on node 1"; ST_OK=0; ST_SINCE=""; ST_FIXES=0; ST_FIXED_AT=""; ST_WARNED=""
MG_TEXT="MongoDB key: waiting for Kubernetes on node 1"; MG_OK=0; MG_SINCE=""; MG_FIXES=0
STORAGE_STUCK_AFTER=300   # seconds the storage failure must last before the repair
MONGO_STUCK_AFTER=180     # seconds mongo.key must stay empty (the key manager sets it in ~15s)

ic_say() { IC_PRINTED=1; "$@"; }   # print during the watch (the live lines restart below it)
free_port() { local p=$1; while port_open localhost "$p"; do p=$((p + 1)); done; echo "$p"; }
port_wait() { local i; for ((i = 0; i < $2; i++)); do port_open localhost "$1" && return 0; sleep 1; done; return 1; }

node1_ssh() {  # [--quiet] command: run it on node 1 (no prompts); stdout returned, all of it logged unless --quiet
  local quiet="" rc=0 outf errf t0
  if [[ "$1" == --quiet ]]; then quiet=1; shift; fi
  outf=$(mktemp "$_LOG_TMP/ssh.XXXXXX"); errf="$outf.err"; t0=$(_clock)
  if [[ "$ACCESS_METHOD" == "eice" ]]; then
    ssh "${EICE_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=30 "$SSH_USER@${IDS[0]}" "$1" >"$outf" 2>"$errf" || rc=$?
  else
    if [[ -z "$IC_SSH_PORT" ]] || ! port_open localhost "$IC_SSH_PORT"; then
      IC_SSH_PORT=$(free_port 12222); ssm_forward "${IPS[0]}" 22 "$IC_SSH_PORT"; port_wait "$IC_SSH_PORT" 30 || true
    fi
    ssh -i "$SSH_KEY_FILE" -p "$IC_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$SSH_USER@localhost" "$1" >"$outf" 2>"$errf" || rc=$?
  fi
  logf DEBUG "ssh node 1 (${IDS[0]}): $1  -> exit $rc in $(_took "$t0")"
  if [[ -z "$quiet" ]]; then log_file out "$outf"; else logf DEBUG "  (output not logged: $(wc -c <"$outf" | tr -d ' ') bytes)"; fi
  log_file err "$errf"
  cat "$outf"; rm -f "$outf" "$errf"
  return $rc
}
kc() {  # [--quiet] kubectl-args...: kubectl on node 1's API server; logged (output too, unless --quiet)
  local quiet="" rc=0 outf errf t0
  if [[ "$1" == --quiet ]]; then quiet=1; shift; fi
  outf=$(mktemp "$_LOG_TMP/kc.XXXXXX"); errf="$outf.err"; t0=$(_clock)
  kubectl --kubeconfig "$IC_KCFG" --request-timeout=20s "$@" >"$outf" 2>"$errf" || rc=$?
  logf DEBUG "kubectl $(_quote_args "$@")  -> exit $rc in $(_took "$t0")"
  if [[ -z "$quiet" ]]; then log_file out "$outf"; else logf DEBUG "  (output not logged: $(wc -c <"$outf" | tr -d ' ') bytes)"; fi
  log_file err "$errf"
  cat "$outf"; rm -f "$outf" "$errf"
  return $rc
}

ic_init() {  # turn the install checks on if everything they need is here; say why not otherwise
  local why=""
  if [[ "$REPAIR" != "true" ]]; then logf INFO "Install repairs off (--no-repair); checks still run"; fi
  if ! type -P kubectl >/dev/null 2>&1; then why="kubectl not found (Install: $(install_hint kubectl))"
  elif ! type -P jq >/dev/null 2>&1; then why="jq not found (Install: $(install_hint jq))"
  elif [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then why="SSH_KEY_FILE in $CONFIG is not set to KEY_NAME's private key"
  elif [[ "$ACCESS_METHOD" == "ssm" ]] && ! type -P session-manager-plugin >/dev/null 2>&1; then why="session-manager-plugin not found"
  fi
  # shellcheck disable=SC2207
  if [[ -z "$why" ]]; then IDS=($(node_ids)); IPS=($(node_ips)); [[ ${#IDS[@]} -gt 0 ]] || why="no running nodes"; fi
  if [[ -n "$why" ]]; then warn "Install checks off: $why."; return 0; fi
  if [[ "$ACCESS_METHOD" == "eice" ]]; then eice_opts; fi
  IC_ON="true"; IC_KCFG="$_LOG_TMP/admin.conf"; KILL_JOBS_ON_EXIT=true; SSM_QUIET=true
  logf INFO "Install checks on: node 1 is ${IDS[0]} (${IPS[0]}); repairs $REPAIR"
}

ic_connect() {  # 0 once kubectl can reach node 1's API server (copies the kubeconfig and starts the forward as needed)
  local cluster
  if [[ ! -s "$IC_KCFG" ]]; then
    (( SECONDS >= IC_NEXT_CONF )) || return 1
    IC_NEXT_CONF=$((SECONDS + 60))
    (umask 077; : >"$IC_KCFG")                      # private before anything is written to it
    node1_ssh --quiet 'sudo cat /etc/kubernetes/admin.conf 2>/dev/null' >"$IC_KCFG" || true
    if ! grep -q certificate-authority-data "$IC_KCFG" 2>/dev/null; then
      : >"$IC_KCFG"; ST_TEXT="storage: waiting for Kubernetes on node 1"; MG_TEXT="MongoDB key: waiting for Kubernetes on node 1"
      return 1
    fi
    IC_PORT=$(free_port 16443)
    cluster=$(kubectl --kubeconfig "$IC_KCFG" config view -o jsonpath='{.clusters[0].name}')
    kubectl --kubeconfig "$IC_KCFG" config set-cluster "$cluster" --server="https://127.0.0.1:$IC_PORT" --tls-server-name=kubernetes >/dev/null
    logf INFO "Copied node 1's admin kubeconfig (not logged); kubectl uses https://127.0.0.1:$IC_PORT -> ${IPS[0]}:6443"
  fi
  if [[ -z "$IC_FWD_PID" ]] || ! kill -0 "$IC_FWD_PID" 2>/dev/null; then
    if [[ "$ACCESS_METHOD" == "eice" ]]; then
      ssh "${EICE_OPTS[@]}" -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L "$IC_PORT:${IPS[0]}:6443" \
          "$SSH_USER@${IDS[0]}" 2>>"$_LOG_TMP/ssh-api-forward.bg" &
      IC_FWD_PID=$!
      logf INFO "API forward (pid $IC_FWD_PID): localhost:$IC_PORT -> ${IPS[0]}:6443 through node 1"
    else
      ssm_forward "${IPS[0]}" 6443 "$IC_PORT"; IC_FWD_PID=$!
    fi
    if ! port_wait "$IC_PORT" 30; then
      kill "$IC_FWD_PID" 2>/dev/null || true; IC_FWD_PID=""
      ST_TEXT="storage: can't reach node 1's API server yet (retrying)"; MG_TEXT="MongoDB key: can't reach node 1's API server yet"
      return 1
    fi
  fi
  return 0
}

ic_storage() {  # sets ST_TEXT and ST_OK; repairs the piraeus-cluster / cert-manager race once it has lasted
  local sc rel sats unowned stuck
  sc=$(kc get storageclass -o jsonpath='{.items[*].metadata.name}') || { ST_TEXT="storage: API server not answering"; return 0; }
  if [[ " $sc " == *" linstor-"* ]]; then
    ST_OK=1; ST_SINCE=""; ST_TEXT="storage: LINSTOR storage classes present${ST_FIXED_AT:+ (repaired)}"; return 0
  fi
  ST_OK=0
  rel=$(kc -n piraeus-system get secrets -l owner=helm,name=piraeusoperator-piraeus-cluster -o jsonpath='{.items[*].metadata.labels.status}' 2>/dev/null) || rel=""
  sats=$(kc get linstorsatelliteconfigurations -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.app\.kubernetes\.io/managed-by}{" "}{end}' 2>/dev/null) || sats=""
  unowned=$(printf '%s\n' $sats | awk -F= '$2 != "Helm" && NF {print $1}' | tr '\n' ' ')
  if [[ -n "$ST_FIXED_AT" ]]; then
    ST_TEXT="storage: repaired $(elapsed $((SECONDS - ST_FIXED_AT))) ago; waiting for LINSTOR storage classes${rel:+ (piraeus-cluster $rel)}"
    if (( SECONDS - ST_FIXED_AT > 900 )) && [[ -z "$ST_WARNED" ]]; then
      ST_WARNED=1; ic_say warn "Storage still has no LINSTOR storage classes 15 minutes after the repair; see INSTALL.md Troubleshooting."
    fi
    if [[ -z "$rel" && -n "$unowned" && $ST_FIXES -lt 2 ]]; then ST_FIXED_AT=""; else return 0; fi
  fi
  if [[ -z "$rel" && -n "$unowned" ]]; then          # the failure: no chart release, satellite config(s) outside Helm
    ST_SINCE=${ST_SINCE:-$SECONDS}; stuck=$((SECONDS - ST_SINCE))
    if (( stuck == 0 )); then
      logf WARN "Storage: piraeus-cluster chart not installed and LinstorSatelliteConfiguration(s) outside Helm: $unowned"
      node1_ssh "sudo journalctl -u stylus-operator --since '-60 min' --no-pager 2>/dev/null | grep -E 'piraeus-cluster' | grep -E 'failed|ownership' | tail -5 | cut -c1-600" >/dev/null || true
    fi
    if (( stuck >= STORAGE_STUCK_AFTER )) && [[ "$REPAIR" == "true" ]]; then ic_fix_storage "$unowned"; return 0; fi
    ST_TEXT="storage: piraeus-cluster chart not installed, $(echo $unowned) outside Helm for $(elapsed $stuck)"
    if [[ "$REPAIR" == "true" ]]; then ST_TEXT+="; repair at $(elapsed $STORAGE_STUCK_AFTER)"; else ST_TEXT+="; --no-repair: see INSTALL.md"; fi
  else
    ST_SINCE=""
    ST_TEXT="storage: waiting for LINSTOR storage classes${rel:+ (piraeus-cluster $rel)}"
  fi
}

ic_fix_storage() {  # unowned-satellite-configs: let Helm adopt them, re-create the pack, restart stylus-operator
  local sat ns bdir
  ST_FIXES=$((ST_FIXES + 1)); ST_FIXED_AT=$SECONDS; ST_SINCE=""
  ic_say log "Repairing storage (attempt $ST_FIXES): the piraeus-cluster chart lost a race with cert-manager"
  bdir="${LOG_FILE%/*}/backup-$NAME_PREFIX-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -n "$LOG_FILE" ]] || bdir="$_LOG_TMP/backup"
  (umask 077; mkdir -p "$bdir")
  ns=$(kc --quiet get packs -A -o json | jq -r '[.items[] | select(.metadata.name == "piraeus-operator")][0].metadata.namespace // empty') || ns=""
  for sat in $1; do
    (umask 077; kc --quiet get linstorsatelliteconfiguration "$sat" -o yaml >"$bdir/linstorsatelliteconfiguration-$sat.yaml") || true
    if kc label linstorsatelliteconfiguration "$sat" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null \
       && kc annotate linstorsatelliteconfiguration "$sat" meta.helm.sh/release-name=piraeusoperator-piraeus-cluster \
            meta.helm.sh/release-namespace=piraeus-system --overwrite >/dev/null; then
      ic_say ok "LinstorSatelliteConfiguration $sat handed to the piraeus-cluster Helm release"
    else
      ic_say warn "Could not relabel LinstorSatelliteConfiguration $sat (see the log)"
    fi
  done
  if [[ -n "$ns" ]]; then
    (umask 077; kc --quiet -n "$ns" get pack piraeus-operator -o yaml >"$bdir/pack-piraeus-operator.yaml") || true
    if kc -n "$ns" delete pack piraeus-operator --wait=false >/dev/null; then
      ic_say ok "Deleted the piraeus-operator pack record in $ns; the cluster controller re-creates it"
    else
      ic_say warn "Could not delete the piraeus-operator pack record in $ns (see the log)"
    fi
  else
    ic_say warn "No piraeus-operator pack record found; restarting stylus-operator anyway"
  fi
  if node1_ssh 'sudo systemctl restart stylus-operator && systemctl is-active stylus-operator' >/dev/null; then
    ic_say ok "Restarted stylus-operator on node 1; it installs the piraeus-cluster chart again (a few minutes)"
  else
    ic_say warn "Could not restart stylus-operator on node 1 (see the log). By hand: ./connect.sh ssh 1, then sudo systemctl restart stylus-operator"
  fi
  logf INFO "Backups of the changed objects (private): $bdir"
  ST_TEXT="storage: repaired just now; waiting for LINSTOR storage classes"
}

ic_mongo() {  # sets MG_TEXT and MG_OK; sets a new key if mongo.key stays empty while mongo-0 waits
  local js len ann ready stuck
  js=$(kc --quiet -n hubble-system get secret spectro-mongodb-replicaset-key -o json 2>/dev/null) \
    || { MG_OK=0; MG_SINCE=""; MG_TEXT="MongoDB key: secret not created yet"; return 0; }
  len=$(jq -r '.data["mongo.key"] // "" | length' <<<"$js")
  ann=$(jq -r '.metadata.annotations // {} | to_entries | map(select(.key | startswith("mongodb-key"))) | map("\(.key)=\(.value)") | join(" ")' <<<"$js")
  logf DEBUG "MongoDB key secret: mongo.key is $len base64 characters; ${ann:-no key-manager annotations}"
  if (( len > 0 )); then
    MG_OK=1; MG_SINCE=""; MG_TEXT="MongoDB key: set"
    if [[ $MG_FIXES -gt 0 ]]; then MG_TEXT+=" (repaired)"; fi
    return 0
  fi
  MG_OK=0
  ready=$(kc -n hubble-system get pod mongo-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) || ready="absent"
  MG_SINCE=${MG_SINCE:-$SECONDS}; stuck=$((SECONDS - MG_SINCE))
  if (( stuck >= MONGO_STUCK_AFTER )) && [[ "$ready" != "true" && "$ready" != "absent" && "$REPAIR" == "true" && $MG_FIXES -lt 2 ]]; then
    ic_fix_mongo; return 0
  fi
  MG_TEXT="MongoDB key: empty for $(elapsed $stuck)"
  case "$ready" in
    absent) MG_TEXT+=", mongo-0 not created yet" ;;
    true)   MG_TEXT+=", but mongo-0 is ready: not changing it" ;;
    *)      MG_TEXT+=", mongo-0 waiting"
            if [[ "$REPAIR" != "true" ]]; then MG_TEXT+="; --no-repair: see INSTALL.md"
            elif [[ $MG_FIXES -lt 2 ]]; then MG_TEXT+="; repair at $(elapsed $MONGO_STUCK_AFTER)"
            else MG_TEXT+="; repaired twice already: see INSTALL.md"; fi ;;
  esac
}

ic_fix_mongo() {  # set a new random mongo.key (756 random bytes, base64); the value never reaches the log
  local pf len
  MG_FIXES=$((MG_FIXES + 1))
  ic_say log "Repairing MongoDB (attempt $MG_FIXES): mongo.key has stayed empty while mongo-0 waits in Init"
  pf=$(mktemp "$_LOG_TMP/mongo-key.XXXXXX")
  printf '{"stringData":{"mongo.key":"%s"}}' "$(head -c 756 /dev/urandom | base64 | tr -d '\n')" >"$pf"
  if kc -n hubble-system patch secret spectro-mongodb-replicaset-key --type merge --patch-file "$pf" >/dev/null; then
    len=$(kc --quiet -n hubble-system get secret spectro-mongodb-replicaset-key -o json | jq -r '.data["mongo.key"] // "" | length') || len=0
    ic_say ok "Set a new MongoDB key ($len base64 characters); mongo-0 picks it up within a minute"
    MG_OK=1; MG_SINCE=""; MG_TEXT="MongoDB key: set (repaired)"
  else
    ic_say warn "Could not set the MongoDB key (see the log); INSTALL.md Troubleshooting has the command"
  fi
  rm -f "$pf"
}

ic_check() {  # one round of install checks (every 30 seconds while watching)
  [[ "$IC_ON" == "true" ]] || return 0
  ic_connect || return 0
  if [[ "$(kc get --raw=/readyz 2>/dev/null)" != ok ]]; then   # not up yet, or the forward went stale
    ST_TEXT="storage: waiting for node 1's API server"; MG_TEXT="MongoDB key: waiting for node 1's API server"
    if [[ -n "$IC_FWD_PID" ]]; then kill "$IC_FWD_PID" 2>/dev/null || true; IC_FWD_PID=""; fi   # reopen it next round
    return 0
  fi
  ic_storage
  ic_mongo
}

watch_nlb() {  # one line for the NLB, one per port and two for the install; redrawn until all are done
  local start=$SECONDS tick=0 n np i h t rest arn="" ip="" state="" all=0 drawn=0 el
  # shellcheck disable=SC2206
  local ports=($APP_PORTS)
  local text=() done_=() tgs=() shown=() logged=()
  np=$((${#ports[@]} + 1)); n=$np
  ic_init
  if [[ "$IC_ON" == "true" ]]; then n=$((np + 2)); fi
  if [[ "$IC_ON" == "true" ]]; then log "Watching the NLB, target health and the install on node 1 (Ctrl-C to stop)"
  else log "Watching the NLB and target health (Ctrl-C to stop)"; fi
  while :; do
    el=$(elapsed $((SECONDS - start)))
    if [[ "$IC_ON" == "true" ]] && (( tick % 120 == 0 )); then   # install checks every 30 seconds
      ic_check
      text[$np]=$ST_TEXT; done_[$np]=$ST_OK; text[$((np + 1))]=$MG_TEXT; done_[$((np + 1))]=$MG_OK
      if [[ $IC_PRINTED -eq 1 ]]; then IC_PRINTED=0; drawn=0; fi   # messages printed: start the lines below them
    fi
    if (( tick % 40 == 0 )); then                      # ask AWS every 10 seconds
      all=1
      if [[ -z "$arn" ]]; then arn=$(nlb_arn); fi
      if [[ -z "$arn" ]]; then
        text[0]="NLB ${NAME_PREFIX}-nlb not created yet (./deploy.sh after Deploy Cluster)"; done_[0]=0; all=0
      else
        state=$(aws_q elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].State.Code')
        if [[ -z "$ip" ]]; then ip=$(nlb_private_ip "$arn"); fi
        text[0]="NLB ${NAME_PREFIX}-nlb ($ip) $state"
        if [[ "$state" == active ]]; then done_[0]=1; else done_[0]=0; all=0; fi
      fi
      for i in "${!ports[@]}"; do
        if [[ -z "${tgs[$i]:-}" ]]; then tgs[$i]=$(tg_arn "${ports[$i]}"); fi
        if [[ -z "${tgs[$i]}" ]]; then
          text[$((i + 1))]="port ${ports[$i]}: no target group yet"; done_[$((i + 1))]=0; all=0; continue
        fi
        read -r h t rest <<<"$(port_health "${tgs[$i]}")"
        text[$((i + 1))]="port ${ports[$i]}: $h/$t healthy${rest:+ ($rest)}"
        if [[ $t -gt 0 && $h -eq $t ]]; then done_[$((i + 1))]=1; else done_[$((i + 1))]=0; all=0; fi
      done
      for ((i = 0; i < n; i++)); do                    # the log gets every change, terminal or not
        if [[ -z "${text[$i]:-}" ]]; then continue; fi
        if [[ "${logged[$i]:-}" != "${text[$i]}" ]]; then logf INFO "${text[$i]} (after $el)"; logged[$i]=${text[$i]}; fi
      done
    fi
    if [[ -t 1 ]]; then                                # redraw the lines in place
      if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$n"; fi
      for ((i = 0; i < n; i++)); do
        if [[ ${done_[$i]} -eq 1 ]]; then printf '\r\033[K  %s %s\n' "$GREEN_CHECK" "${text[$i]}"
        else printf '\r\033[K  %s %s  %s\n' "${SPIN[$((tick % 4))]}" "${text[$i]}" "$el"; fi
      done
      drawn=1
    elif (( tick % 40 == 0 )); then                    # not a terminal: print what changed
      for ((i = 0; i < n; i++)); do
        if [[ "${shown[$i]:-}" != "${text[$i]}" ]]; then echo "  $el  ${text[$i]}"; shown[$i]=${text[$i]}; fi
      done
    fi
    if [[ $all -eq 1 ]]; then ok "NLB active and every port healthy on every node ($el)"; return 0; fi
    sleep 0.25; tick=$((tick + 1))
  done
}

log "Instances"
aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'sort_by(Reservations[].Instances[], &join(`,`, Tags[?Key==`Name`].Value))[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,PrivateIpAddress]' \
    --output table

log "Access ($ACCESS_METHOD)"
if [[ "$ACCESS_METHOD" == "eice" ]]; then
  id=$(eice_id)
  [[ -n "$id" ]] && ok "$id: $(aws_q ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$id" --query 'InstanceConnectEndpoints[0].State')" \
    || warn "No EC2 Instance Connect Endpoint."
else
  jump=$(instance_id jump)
  [[ -n "$jump" ]] && ok "Jump host $jump: Session Manager $(aws_q ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$jump" --query 'InstanceInformationList[0].PingStatus')" || warn "No jump host."
  for svc in $SSM_SERVICES; do
    ok "$svc endpoint: $(aws_q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$(vpc_id)" \
        "Name=service-name,Values=com.amazonaws.$REGION.$svc" --query 'VpcEndpoints[0].State')"
  done
fi

if [[ "$WATCH" == "true" ]]; then watch_nlb; exit 0; fi

NLB_ARN=$(nlb_arn)
if [[ -z "$NLB_ARN" ]]; then
  warn "No NLB yet (create it with ./deploy.sh after Deploy Cluster; VIP $NLB_PRIVATE_IP)."
  exit 0
fi
log "Internal NLB"
ok "Private IP (VIP): $(nlb_private_ip "$NLB_ARN"), state $(aws_q elbv2 describe-load-balancers \
    --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].State.Code')"
log "Target health"
for port in $APP_PORTS; do
  tg=$(tg_arn "$port")
  [[ -n "$tg" ]] || { warn "tg-$port missing"; continue; }
  read -r h t rest <<<"$(port_health "$tg")"
  printf '  %-6s %s/%s healthy%s\n' "$port" "$h" "$t" "${rest:+ ($rest)}"
  logf INFO "port $port: $h/$t healthy${rest:+ ($rest)}"
  log_detail aws elbv2 describe-target-health --target-group-arn "$tg" --output json \
      --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Detail:TargetHealth.Description}'
done
