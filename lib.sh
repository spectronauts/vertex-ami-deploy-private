# Shared helpers for the ami-deploy-private scripts. Sourced, not run.
# shellcheck shell=bash

CONFIG="${CONFIG:-config.env}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "Config file '$CONFIG' not found. Copy config.env.example to config.env and fill it in."
# shellcheck disable=SC1090
source "$CONFIG"

: "${NAME_PREFIX:=vxp}" "${AZ:=}" "${VPC_CIDR:=10.0.0.0/16}" "${PRIVATE_CIDR:=10.0.11.0/24}"
: "${APP_PORTS:=443 6443 30003 5080}" "${APP_COUNT:=3}"
: "${INSTANCE_TYPE:=m5.2xlarge}" "${ROOT_VOLUME_SIZE_GB:=200}"
: "${DATA_VOLUME_COUNT:=2}" "${DATA_VOLUME_SIZE_GB:=500}"
: "${USER_DATA_FILE:=user-data.yaml}" "${NODE_TO_NODE:=true}" "${PRESERVE_CLIENT_IP:=false}" "${NLB_PRIVATE_IP:=}"
: "${ACCESS_METHOD:=eice}" "${JUMP_INSTANCE_TYPE:=t3.micro}" "${SSH_USER:=kairos}" "${SSH_KEY_FILE:=}"
: "${JUMP_AMI_SSM_PARAM:=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}"

export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""   # print AWS CLI output to the terminal instead of a pager (less)
TAG_KEY="vxp:deployment"
OUTPUT_FILE="outputs-${NAME_PREFIX}.txt"
JUMP_ROLE="${NAME_PREFIX}-jump"
SSM_SERVICES="ssm ssmmessages ec2messages"

aws_q() { aws "$@" --output text 2>/dev/null; }
none_to_empty() { [[ "$1" == "None" ]] && echo "" || echo "$1"; }

tags() {  # resource-type name -> a --tag-specifications value
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=$TAG_KEY,Value=$NAME_PREFIX}]"
}

# Look up this deployment's resources by their Name tag.
vpc_id()     { none_to_empty "$(aws_q ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" --query 'Vpcs[0].VpcId')"; }
subnet_id()  { none_to_empty "$(aws_q ec2 describe-subnets --filters "Name=tag:Name,Values=${NAME_PREFIX}-$1" "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" --query 'Subnets[0].SubnetId')"; }
sg_id()      { none_to_empty "$(aws_q ec2 describe-security-groups --filters "Name=group-name,Values=${NAME_PREFIX}-$1-sg" "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" --query 'SecurityGroups[0].GroupId')"; }
instance_id() {
  none_to_empty "$(aws_q ec2 describe-instances --filters "Name=tag:Name,Values=${NAME_PREFIX}-$1" "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[0].Instances[0].InstanceId')"
}
eice_id() {  # this deployment's EC2 Instance Connect Endpoint, if any
  none_to_empty "$(aws_q ec2 describe-instance-connect-endpoints --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
      "Name=state,Values=create-in-progress,create-complete" --query 'InstanceConnectEndpoints[0].InstanceConnectEndpointId')"
}
nlb_arn()    { none_to_empty "$(aws_q elbv2 describe-load-balancers --names "${NAME_PREFIX}-nlb" --query 'LoadBalancers[0].LoadBalancerArn')"; }
nlb_private_ip() {  # the internal NLB's single private IP = the installer VIP
  local arn="$1"
  aws_q ec2 describe-network-interfaces --filters "Name=description,Values=ELB ${arn#*:loadbalancer/}" \
      --query 'NetworkInterfaces[0].PrivateIpAddress'
}
node_ids() {  # node instance IDs in node-1..N order
  aws_q ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" "Name=tag:Name,Values=${NAME_PREFIX}-node-*" \
      "Name=instance-state-name,Values=pending,running" \
      --query 'sort_by(Reservations[].Instances[], &join(`,`, Tags[?Key==`Name`].Value))[].InstanceId' | tr '\t' ' '
}
node_ips() {  # node private IPs in node-1..N order
  aws_q ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" "Name=tag:Name,Values=${NAME_PREFIX}-node-*" \
      "Name=instance-state-name,Values=pending,running" \
      --query 'sort_by(Reservations[].Instances[], &join(`,`, Tags[?Key==`Name`].Value))[].PrivateIpAddress' | tr '\t' ' '
}
