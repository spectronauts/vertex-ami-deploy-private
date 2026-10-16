#!/usr/bin/env bash
# What deploy.sh built: instances, the access path, the NLB (VIP) and target health.
#
# Usage: ./status.sh [-c config.env] [--watch]
#   --watch  keep checking the NLB and each port's target health: one updating line each, with
#            the elapsed time, until the NLB is active and every port is healthy on every
#            node (Ctrl-C to stop)

set -euo pipefail
SCRIPT_ARGS=("$@")
WATCH="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="$2"; shift 2 ;;
    --watch) WATCH="true"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
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

watch_nlb() {  # one line for the NLB and one per port, redrawn until all are done
  local start=$SECONDS tick=0 n i h t rest arn="" ip="" state="" all=0 drawn=0 el
  # shellcheck disable=SC2206
  local ports=($APP_PORTS)
  local text=() done_=() tgs=() shown=() logged=()
  n=$((${#ports[@]} + 1))
  log "Watching the NLB and target health (Ctrl-C to stop)"
  while :; do
    el=$(elapsed $((SECONDS - start)))
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
