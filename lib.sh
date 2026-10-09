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

[[ -n "${REGION:-}" ]] || die "REGION is required in $CONFIG (for example us-gov-west-1)."
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""   # print AWS CLI output to the terminal instead of a pager (less)
TAG_KEY="vxp:deployment"
OUTPUT_FILE="outputs-${NAME_PREFIX}.txt"
JUMP_ROLE="${NAME_PREFIX}-jump"
SSM_SERVICES="ssm ssmmessages ec2messages"

aws_q() { aws "$@" --output text 2>/dev/null; }
none_to_empty() { [[ "$1" == "None" ]] && echo "" || echo "$1"; }

# --- Workstation prerequisites: macOS or Linux, x86_64 or arm64 -----------------------------
OS=$(uname -s); ARCH=$(uname -m)

install_hint() {  # tool -> how to install it on this OS and CPU
  local aws_arch=x86_64 k8s_arch=amd64 ssm_arch=64bit
  local ssm_url=https://s3.amazonaws.com/session-manager-downloads/plugin/latest
  case "$ARCH" in
    x86_64|amd64) ;;
    arm64|aarch64) aws_arch=aarch64; k8s_arch=arm64; ssm_arch=arm64 ;;
    *) case "$1" in aws|session-manager-plugin|kubectl) echo "no $1 build for $ARCH; use an x86_64 or arm64 machine"; return ;; esac ;;
  esac
  if [[ "$OS" == "Darwin" ]]; then
    case "$1" in
      aws) echo "brew install awscli  (or https://awscli.amazonaws.com/AWSCLIV2.pkg)" ;;
      session-manager-plugin) echo "brew install --cask session-manager-plugin" ;;
      kubectl) echo "brew install kubectl" ;;
      ssh|ssh-add|ssh-agent|ssh-keygen) echo "it ships with macOS; check your PATH" ;;
      *) echo "brew install $1" ;;
    esac
    return
  fi
  case "$1" in
    aws) echo "curl -fsSLo awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-$aws_arch.zip && unzip -q awscliv2.zip && sudo ./aws/install --update" ;;
    session-manager-plugin)
      if command -v dpkg >/dev/null 2>&1; then
        echo "curl -fsSLO $ssm_url/ubuntu_$ssm_arch/session-manager-plugin.deb && sudo dpkg -i session-manager-plugin.deb"
      else
        echo "sudo dnf install -y $ssm_url/linux_$ssm_arch/session-manager-plugin.rpm  (yum on older releases)"
      fi ;;
    kubectl) echo "curl -fsSLO https://dl.k8s.io/release/\$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$k8s_arch/kubectl && sudo install kubectl /usr/local/bin/" ;;
    ssh|ssh-add|ssh-agent|ssh-keygen)
      if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y openssh-client"
      else echo "sudo dnf install -y openssh-clients"; fi ;;
    *) echo "install $1 with your package manager" ;;
  esac
}

require_tools() {  # tool... -> stop, with an install command per tool, if any is missing
  local t missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { warn "$t not found. Install: $(install_hint "$t")"; missing=1; }
  done
  [[ -z "$missing" ]] || die "Install the missing tools above ($OS $ARCH), then re-run."
}

require_aws() {  # AWS CLI v2 (2.12+ for EICE's open-tunnel) and working credentials; sets CALLER_ARN, PARTITION
  require_tools aws
  local v minor
  v=$(aws --version 2>&1 | awk '{print $1}')
  [[ "$v" == aws-cli/2.* ]] || die "AWS CLI v2 is required; found ${v:-nothing}. Install: $(install_hint aws)"
  minor=$(echo "$v" | cut -d/ -f2 | cut -d. -f2)
  [[ "$ACCESS_METHOD" != "eice" || "$minor" -ge 12 ]] \
    || die "ACCESS_METHOD=eice needs AWS CLI 2.12 or later for open-tunnel; found ${v#aws-cli/}. Update: $(install_hint aws)"
  CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
    || die "AWS credentials don't work in $REGION: $(echo "$CALLER_ARN" | tail -1)"
  PARTITION=$(echo "$CALLER_ARN" | cut -d: -f2)
}

require_agent() {  # ssh-agent running, with SSH_KEY_FILE loaded (adds it if missing)
  require_tools ssh ssh-add ssh-keygen
  local rc=0 fp
  ssh-add -l >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 2 ]] || die "No ssh-agent is running. Start one in this shell: eval \"\$(ssh-agent -s)\""
  fp=$(ssh-keygen -lf "$SSH_KEY_FILE" 2>/dev/null | awk '{print $2}') || fp=""
  [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp" || ssh-add "$SSH_KEY_FILE"
}

port_open() {  # host port -> 0 if something accepts TCP connections there (bash /dev/tcp; no nc needed)
  (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
}

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
