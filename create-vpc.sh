#!/usr/bin/env bash
# Network for a deployment with no public subnets: one VPC and one private subnet whose
# route table has no default route. No internet gateway, no NAT gateway. DNS support and
# DNS hostnames are on, which the SSM interface endpoints' private DNS needs.
# Safe to re-run: existing resources (found by Name tag) are reused.
#
# Usage: ./create-vpc.sh [-c config.env]

set -euo pipefail
[[ "${1:-}" == "-c" ]] && CONFIG="$2"
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

pick_az() {
  # A real zone that offers the node type (and the jump host type for ssm).
  local zones z types="$INSTANCE_TYPE" want=1
  [[ "$ACCESS_METHOD" == "ssm" && "$JUMP_INSTANCE_TYPE" != "$INSTANCE_TYPE" ]] && { types="$INSTANCE_TYPE,$JUMP_INSTANCE_TYPE"; want=2; }
  zones=$(aws_q ec2 describe-availability-zones --filters "Name=state,Values=available" --query 'AvailabilityZones[].ZoneName')
  for z in $zones; do
    if aws_q ec2 describe-instance-type-offerings --location-type availability-zone \
         --filters "Name=location,Values=$z" "Name=instance-type,Values=$types" \
         --query 'length(InstanceTypeOfferings)' | grep -qx "$want"; then
      echo "$z"; return
    fi
  done
  die "No zone in $REGION offers $types."
}

log "Private network ($REGION)"
require_aws
ok "Authenticated as $CALLER_ARN ($OS $ARCH)"

VPC_ID=$(vpc_id)
if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(aws_q ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tags vpc "${NAME_PREFIX}-vpc")" --query Vpc.VpcId)
  aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
  ok "Created VPC $VPC_ID ($VPC_CIDR)"
else
  ok "Using VPC $VPC_ID"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
ok "DNS support and DNS hostnames enabled"

PRIVATE_ID=$(subnet_id private)
if [[ -z "$PRIVATE_ID" ]]; then
  [[ -n "$AZ" ]] || AZ=$(pick_az)
  PRIVATE_ID=$(aws_q ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_CIDR" --availability-zone "$AZ" \
      --tag-specifications "$(tags subnet "${NAME_PREFIX}-private")" --query Subnet.SubnetId)
  ok "Created private subnet $PRIVATE_ID ($PRIVATE_CIDR) in $AZ"
else
  AZ=$(aws_q ec2 describe-subnets --subnet-ids "$PRIVATE_ID" --query 'Subnets[0].AvailabilityZone')
  ok "Using private subnet $PRIVATE_ID in $AZ"
fi

RTB=$(none_to_empty "$(aws_q ec2 describe-route-tables --filters "Name=tag:Name,Values=${NAME_PREFIX}-private-rtb" \
    "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[0].RouteTableId')")
if [[ -z "$RTB" ]]; then
  RTB=$(aws_q ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tags route-table "${NAME_PREFIX}-private-rtb")" --query RouteTable.RouteTableId)
fi
aws ec2 associate-route-table --route-table-id "$RTB" --subnet-id "$PRIVATE_ID" >/dev/null 2>&1 || true

# The premise: nothing in this VPC reaches the internet.
[[ "$(aws_q ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'][] | length(@)")" == "0" ]] \
  || die "A route table in $VPC_ID has a default route; this deployment allows none."
[[ -z "$(none_to_empty "$(aws_q ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId')")" ]] \
  || die "$VPC_ID has an internet gateway attached; this deployment allows none."
ok "Route table $RTB: no default route; no internet gateway in the VPC"

log "Network ready. Next: ./deploy.sh --no-nlb"
