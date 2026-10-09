#!/usr/bin/env bash
# Remove everything create-vpc.sh and deploy.sh built for one NAME_PREFIX: NLB and target
# groups, instances, the access path (EC2 Instance Connect Endpoint, or SSM endpoints and
# the jump host's IAM role), route table, subnet, security groups, VPC. Asks first.
#
# Usage: ./teardown.sh [-c config.env] [--nlb-only]
#   --nlb-only  delete just the NLB and its listeners; keep target groups and everything else

set -euo pipefail
NLB_ONLY="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="$2"; shift 2 ;;
    --nlb-only) NLB_ONLY="true"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_aws

retry() {  # tries what command...  (network interfaces take a while to release)
  local tries=$1 what=$2 i; shift 2
  for ((i = 1; i <= tries; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 15
  done
  warn "Could not $what; delete it manually."
}

if [[ "$NLB_ONLY" == "true" ]]; then
  NLB_ARN=$(nlb_arn)
  [[ -n "$NLB_ARN" ]] || { log "No ${NAME_PREFIX}-nlb to delete."; exit 0; }
  read -r -p "Delete ${NAME_PREFIX}-nlb (private IP $(nlb_private_ip "$NLB_ARN")) and its listeners? Type the NAME_PREFIX ($NAME_PREFIX): " answer
  [[ "$answer" == "$NAME_PREFIX" ]] || { echo "Cancelled."; exit 1; }
  log "Deleting NLB ${NAME_PREFIX}-nlb (target groups kept)"
  aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$NLB_ARN"
  log "NLB deleted. Its IP is free about a minute later; ./deploy.sh re-creates it."
  exit 0
fi

VPC_ID=$(vpc_id)
echo "This permanently deletes the '$NAME_PREFIX' deployment in $REGION: the NLB, all instances"
echo "and their volumes, the access path, and the VPC ${VPC_ID:-<not found>} with everything in it."
read -r -p "Type the NAME_PREFIX ($NAME_PREFIX) to continue: " answer
[[ "$answer" == "$NAME_PREFIX" ]] || { echo "Cancelled."; exit 1; }

# 1. NLB and target groups
NLB_ARN=$(nlb_arn)
if [[ -n "$NLB_ARN" ]]; then
  log "Deleting NLB ${NAME_PREFIX}-nlb"
  aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$NLB_ARN"
fi
for port in $APP_PORTS; do
  tg=$(none_to_empty "$(aws_q elbv2 describe-target-groups --names "${NAME_PREFIX}-tg-$port" --query 'TargetGroups[0].TargetGroupArn' || true)")
  [[ -z "$tg" ]] || { log "Deleting target group ${NAME_PREFIX}-tg-$port"; aws elbv2 delete-target-group --target-group-arn "$tg"; }
done

# 2. Instances (nodes and any jump host)
# shellcheck disable=SC2207
IDS=($(aws_q ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId'))
if [[ ${#IDS[@]} -gt 0 ]]; then
  log "Terminating instances: ${IDS[*]}"
  aws ec2 terminate-instances --instance-ids "${IDS[@]}" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "${IDS[@]}"
fi

# 3. Access path: EC2 Instance Connect Endpoint, SSM interface endpoints, jump host role
for eice in $(aws_q ec2 describe-instance-connect-endpoints --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
    --query "InstanceConnectEndpoints[?State!='delete-complete'].InstanceConnectEndpointId"); do
  log "Deleting EC2 Instance Connect Endpoint $eice"
  aws ec2 delete-instance-connect-endpoint --instance-connect-endpoint-id "$eice" >/dev/null
done
if [[ -n "$VPC_ID" ]]; then
  # shellcheck disable=SC2207
  EPS=($(aws_q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
      "Name=vpc-endpoint-state,Values=pending,available" --query 'VpcEndpoints[].VpcEndpointId'))
  if [[ ${#EPS[@]} -gt 0 ]]; then
    log "Deleting VPC endpoints: ${EPS[*]}"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${EPS[@]}" >/dev/null
  fi
fi
if aws iam get-instance-profile --instance-profile-name "$JUMP_ROLE" >/dev/null 2>&1; then
  log "Deleting instance profile and IAM role $JUMP_ROLE"
  aws iam remove-role-from-instance-profile --instance-profile-name "$JUMP_ROLE" --role-name "$JUMP_ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$JUMP_ROLE"
fi
if aws iam get-role --role-name "$JUMP_ROLE" >/dev/null 2>&1; then
  for p in $(aws_q iam list-attached-role-policies --role-name "$JUMP_ROLE" --query 'AttachedPolicies[].PolicyArn'); do
    aws iam detach-role-policy --role-name "$JUMP_ROLE" --policy-arn "$p"
  done
  aws iam delete-role --role-name "$JUMP_ROLE"
fi

[[ -n "$VPC_ID" ]] || { rm -f "$OUTPUT_FILE"; log "No VPC found. Teardown complete."; exit 0; }

# 4. Route tables, subnet (endpoint interfaces can hold it for a few minutes)
for rtb in $(aws_q ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?!(Associations[?Main])].RouteTableId'); do
  for assoc in $(aws_q ec2 describe-route-tables --route-table-ids "$rtb" --query 'RouteTables[0].Associations[].RouteTableAssociationId'); do
    aws ec2 disassociate-route-table --association-id "$assoc" >/dev/null 2>&1 || true
  done
  log "Deleting route table $rtb"
  aws ec2 delete-route-table --route-table-id "$rtb"
done
for sn in $(aws_q ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId'); do
  log "Deleting subnet $sn"
  retry 40 "delete subnet $sn" aws ec2 delete-subnet --subnet-id "$sn"
done

# 5. Security groups (they reference each other, so empty them first), then the VPC
SGS=$(aws_q ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId")
for sg in $SGS; do
  for dir in ingress egress; do
    key=IpPermissions; [[ $dir == egress ]] && key=IpPermissionsEgress
    perms=$(aws ec2 describe-security-groups --group-ids "$sg" --output json --query "SecurityGroups[0].$key")
    [[ "$perms" == "[]" ]] || aws ec2 "revoke-security-group-$dir" --group-id "$sg" --ip-permissions "$perms" >/dev/null 2>&1 || true
  done
done
for sg in $SGS; do
  log "Deleting security group $sg"
  retry 12 "delete security group $sg" aws ec2 delete-security-group --group-id "$sg"
done
log "Deleting VPC $VPC_ID"
retry 8 "delete VPC $VPC_ID" aws ec2 delete-vpc --vpc-id "$VPC_ID"

rm -f "$OUTPUT_FILE"
log "Teardown complete."
