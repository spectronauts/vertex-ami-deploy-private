#!/usr/bin/env bash
# What deploy.sh built: instances, the access path, the NLB (VIP) and target health.
#
# Usage: ./status.sh [-c config.env]

set -euo pipefail
[[ "${1:-}" == "-c" ]] && CONFIG="$2"
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_aws

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

NLB_ARN=$(nlb_arn)
if [[ -z "$NLB_ARN" ]]; then
  warn "No NLB yet (create it with ./deploy.sh after Deploy Cluster; VIP $NLB_PRIVATE_IP)."
  exit 0
fi
log "Internal NLB"
ok "Private IP (VIP): $(nlb_private_ip "$NLB_ARN")"
log "Target health"
for port in $APP_PORTS; do
  tg=$(aws_q elbv2 describe-target-groups --names "${NAME_PREFIX}-tg-$port" --query 'TargetGroups[0].TargetGroupArn' || true)
  [[ -n "$tg" && "$tg" != "None" ]] || { warn "tg-$port missing"; continue; }
  printf '  %-6s %s\n' "$port" "$(aws_q elbv2 describe-target-health --target-group-arn "$tg" \
      --query 'TargetHealthDescriptions[].[TargetHealth.State]' | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}')"
done
