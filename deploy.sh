#!/usr/bin/env bash
# Deploy the VerteX appliance into the private-only network from create-aws-infra.sh:
#   security groups  access, app and NLB groups referencing each other by ID; default
#                    allow-all egress removed; nodes may talk to each other
#   access           ACCESS_METHOD=eice: an EC2 Instance Connect Endpoint in the subnet
#                    ACCESS_METHOD=ssm:  ssm/ssmmessages/ec2messages endpoints, an IAM role,
#                                        and a small Amazon Linux jump host (no inbound ports)
#   nodes            APP_COUNT appliance instances (root volume ROOT_VOLUME_SIZE_GB,
#                    DATA_VOLUME_COUNT x DATA_VOLUME_SIZE_GB data volumes, user data)
#   NLB              internal NLB on NLB_PRIVATE_IP (the VIP) with a TCP listener and target
#                    group per app port
# Safe to re-run: existing resources are reused.
#
# Usage: ./deploy.sh [-c config.env] [--preflight-only] [--no-nlb]
#   --no-nlb  build everything but the NLB and its target groups. Local UI refuses a VIP that
#             a device already owns: run --no-nlb, enter NLB_PRIVATE_IP as the VIP, click
#             Deploy Cluster, then run ./deploy.sh to create the NLB on that IP.

set -euo pipefail
SCRIPT_ARGS=("$@")
PREFLIGHT_ONLY="false"
NO_NLB="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="$2"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY="true"; shift ;;
    --no-nlb) NO_NLB="true"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

# ---------------------------------------------------------------------------
preflight() {
  log "Preflight checks"
  local v
  for v in REGION AMI_ID KEY_NAME USER_DATA_FILE NLB_PRIVATE_IP; do
    [[ -n "${!v:-}" ]] || die "$v is required in $CONFIG."
  done
  [[ $CONFIG_PROBLEMS -eq 0 ]] || die "Fix the settings above in $CONFIG, then re-run."
  ok "Settings in $CONFIG"
  logf INFO "Mode: preflight-only=$PREFLIGHT_ONLY, no-nlb=$NO_NLB"
  require_aws
  ok "Authenticated as $CALLER_ARN ($OS $ARCH)"

  [[ "$(aws_q ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].State')" == "available" ]] \
    || die "AMI $AMI_ID is not available in $REGION."
  ROOT_DEVICE=$(aws_q ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].RootDeviceName')
  log_detail aws ec2 describe-images --image-ids "$AMI_ID" --output json --query \
      'Images[0].{Name:Name,Description:Description,Created:CreationDate,Owner:OwnerId,Arch:Architecture,Root:RootDeviceName,Disks:BlockDeviceMappings}'
  ok "AMI $AMI_ID available"
  # Two floors (INSTALL.md Step 5). Below about 40 GB the AMI's first-boot reset can't add its
  # 19,780 MiB COS_STATE partition and the node stays in Kairos recovery. Below 300 GB the
  # COS_PERSISTENT partition (kubelet's filesystem: whatever the root has left, 59.8 GiB on
  # 100 GB) can pass kubelet's 85% image garbage-collection threshold during install; kubelet
  # then deletes preloaded images that an airgapped node can't pull back.
  [[ "$ROOT_VOLUME_SIZE_GB" =~ ^[0-9]+$ && $ROOT_VOLUME_SIZE_GB -ge 40 ]] \
    || die "ROOT_VOLUME_SIZE_GB must be at least 40; the AMI's first-boot reset cannot create COS_STATE below that."
  if [[ $ROOT_VOLUME_SIZE_GB -lt 300 ]]; then
    if [[ -n "$(node_ids)" ]]; then
      warn "ROOT_VOLUME_SIZE_GB $ROOT_VOLUME_SIZE_GB is under 300; the existing nodes are kept as they are."
    else
      die "ROOT_VOLUME_SIZE_GB must be at least 300; below that kubelet can delete preloaded images."
    fi
  fi
  ok "Root volume $ROOT_DEVICE: $ROOT_VOLUME_SIZE_GB GB"
  local hv vcpu mib nvme
  read -r hv vcpu mib nvme <<<"$(aws_q ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
      --query 'InstanceTypes[0].[Hypervisor,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,EbsInfo.NvmeSupport]' || true)"
  [[ -n "$vcpu" && "$vcpu" != None ]] || die "Instance type $INSTANCE_TYPE is not offered in $REGION."
  ok "Instance type $INSTANCE_TYPE: $vcpu vCPU, $((mib / 1024)) GiB$([[ "$hv" == None ]] || echo " ($hv)")"
  DATA_DRIVE=$(sed -n 's/^DATA_DRIVE=//p' "$OUTPUT_FILE" 2>/dev/null || true)   # as found on the nodes, if checked
  DATA_DRIVE=${DATA_DRIVE:-$(expected_data_drive "$nvme")}
  ok "Data drive $DATA_DRIVE: $DATA_VOLUME_SIZE_GB GB (Storage Pool Drive in the cluster profile)"
  aws_q ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null || die "Key pair '$KEY_NAME' not found."
  ok "Key pair $KEY_NAME found"
  check_ssh_key

  [[ -f "$USER_DATA_FILE" ]] || die "$USER_DATA_FILE not found. Copy user-data.yaml.example and set the password and SSH key."
  [[ "$(head -1 "$USER_DATA_FILE")" == "#cloud-config" ]] || die "$USER_DATA_FILE must start with '#cloud-config'."
  ! grep -q 'ssh-rsa abc@spectrocloud.com' "$USER_DATA_FILE" \
    || die "Replace the placeholder SSH key in $USER_DATA_FILE with your public key."
  grep -Eq '^[[:space:]]+passwd:[[:space:]]*fusion[[:space:]]*$' "$USER_DATA_FILE" \
    && warn "$USER_DATA_FILE still uses the sample password."
  # For the log: the file's shape, never its passwords.
  logf INFO "$USER_DATA_FILE: $(wc -c <"$USER_DATA_FILE" | tr -d ' ') bytes, sha256 $(_sha256 "$USER_DATA_FILE"), top-level keys: $(grep -Eo '^[A-Za-z_][A-Za-z0-9_-]*:' "$USER_DATA_FILE" | tr -d ':' | tr '\n' ' ')"
  logf INFO "$USER_DATA_FILE: $(grep -cE '^[[:space:]]+passwd:' "$USER_DATA_FILE" || true) passwd line(s), $(grep -cE '(ssh-(rsa|ed25519)|ecdsa-sha2-)' "$USER_DATA_FILE" || true) SSH public key(s)"
  ok "User data $USER_DATA_FILE"

  VPC_ID=$(vpc_id); PRIVATE_ID=$(subnet_id private)
  [[ -n "$VPC_ID" && -n "$PRIVATE_ID" ]] \
    || die "Network not found. Run ./create-aws-infra.sh first."
  AZ=$(aws_q ec2 describe-subnets --subnet-ids "$PRIVATE_ID" --query 'Subnets[0].AvailabilityZone')
  [[ "$(aws_q ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'][] | length(@)")" == "0" ]] \
    || die "A route table in $VPC_ID has a default route; this deployment allows none."
  [[ -z "$(none_to_empty "$(aws_q ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
      --query 'InternetGateways[0].InternetGatewayId')")" ]] || die "$VPC_ID has an internet gateway; this deployment allows none."
  ok "VPC $VPC_ID, private subnet $PRIVATE_ID in $AZ; no internet gateway, no default route"
  log_detail aws ec2 describe-subnets --subnet-ids "$PRIVATE_ID" --output json \
      --query 'Subnets[0].{Cidr:CidrBlock,Az:AvailabilityZone,FreeIPs:AvailableIpAddressCount,PublicIpOnLaunch:MapPublicIpOnLaunch}'
  log_detail aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" --output json --query \
      'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,State:State.Name,Ip:PrivateIpAddress,Launched:LaunchTime}'

  local arn current
  arn=$(nlb_arn); current=""
  [[ -n "$arn" ]] && current=$(nlb_private_ip "$arn")
  if [[ -n "$arn" && "$current" != "$NLB_PRIVATE_IP" ]]; then
    die "${NAME_PREFIX}-nlb exists with private IP $current; an NLB's IP is fixed at creation. Run ./teardown.sh --nlb-only first."
  fi
  if [[ -z "$arn" ]]; then
    [[ "$(aws_q ec2 describe-network-interfaces --filters "Name=addresses.private-ip-address,Values=$NLB_PRIVATE_IP" \
        "Name=vpc-id,Values=$VPC_ID" --query 'length(NetworkInterfaces)')" == "0" ]] \
      || die "NLB_PRIVATE_IP $NLB_PRIVATE_IP is in use in $VPC_ID (an NLB interface can take a minute to release)."
  fi
  ok "VIP / NLB private IP: $NLB_PRIVATE_IP"

  if [[ "$ACCESS_METHOD" == "ssm" ]]; then
    command -v session-manager-plugin >/dev/null \
      || warn "session-manager-plugin not found; ./connect.sh needs it. Install: $(install_hint session-manager-plugin)"
  fi
  ok "Access method: $ACCESS_METHOD"
}

# ---------------------------------------------------------------------------
ensure_sg() {  # role description -> id
  local id
  id=$(sg_id "$1")
  if [[ -z "$id" ]]; then
    id=$(aws_q ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${NAME_PREFIX}-$1-sg" \
        --description "$2" --tag-specifications "$(tags security-group "${NAME_PREFIX}-$1-sg")" --query GroupId)
    # Outbound is spelled out below, so drop the default allow-all.
    aws ec2 revoke-security-group-egress --group-id "$id" \
      --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
    ok "Created ${NAME_PREFIX}-$1-sg ($id)" >&2
  else
    ok "Using ${NAME_PREFIX}-$1-sg ($id)" >&2
  fi
  echo "$id"
}

rule() {  # ingress|egress sg protocol port(or "all") peer-sg|cidr description
  # Re-runs get InvalidPermission.Duplicate for rules already there; the log shows each result.
  local dir=$1 sg=$2 proto=$3 port=$4 peer=$5 desc=$6 perm
  if [[ "$proto" == "all" ]]; then perm="IpProtocol=-1"; else perm="IpProtocol=$proto,FromPort=$port,ToPort=$port"; fi
  if [[ "$peer" == sg-* ]]; then
    perm+=",UserIdGroupPairs=[{GroupId=$peer,Description=\"$desc\"}]"
  else
    perm+=",IpRanges=[{CidrIp=$peer,Description=\"$desc\"}]"
  fi
  aws ec2 "authorize-security-group-$dir" --group-id "$sg" --ip-permissions "$perm" >/dev/null 2>&1 || true
}

ensure_security_groups() {
  log "Security groups"
  if [[ "$ACCESS_METHOD" == "eice" ]]; then
    ACCESS_SG=$(ensure_sg access "EC2 Instance Connect Endpoint: all ports to app and NLB")
  else
    ACCESS_SG=$(ensure_sg access "SSM jump host: all ports to app and NLB; 443 to the SSM endpoints")
    ENDPOINTS_SG=$(ensure_sg endpoints "SSM interface endpoints: 443 from the jump host")
    rule ingress "$ENDPOINTS_SG" tcp 443 "$ACCESS_SG" "from jump host"
    rule egress  "$ACCESS_SG" tcp 443 "$ENDPOINTS_SG" "to SSM endpoints"
  fi
  APP_SG=$(ensure_sg app "Appliance nodes: all from access; app ports from NLB; node to node")
  NLB_SG=$(ensure_sg nlb "Internal NLB: all from access; app ports from app; app ports to app")

  local port
  rule egress  "$ACCESS_SG" all all "$APP_SG" "all ports to app"
  rule egress  "$ACCESS_SG" all all "$NLB_SG" "all ports to NLB"
  rule ingress "$APP_SG" all all "$ACCESS_SG" "all ports from access"
  rule ingress "$NLB_SG" all all "$ACCESS_SG" "all ports from access"
  for port in $APP_PORTS; do
    rule ingress "$APP_SG" tcp "$port" "$NLB_SG" "from NLB"
    rule egress  "$APP_SG" tcp "$port" "$NLB_SG" "to NLB"
    rule ingress "$NLB_SG" tcp "$port" "$APP_SG" "from app"
    rule egress  "$NLB_SG" tcp "$port" "$APP_SG" "to app"
  done
  if [[ "$NODE_TO_NODE" == "true" ]]; then
    rule ingress "$APP_SG" all all "$APP_SG" "node to node"
    rule egress  "$APP_SG" all all "$APP_SG" "node to node"
  fi
  ok "Rules applied (node to node: $NODE_TO_NODE)"
  log_detail aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:$TAG_KEY,Values=$NAME_PREFIX" \
      --output json --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,In:IpPermissions,Out:IpPermissionsEgress}'
}

# ---------------------------------------------------------------------------
ensure_eice() {
  log "Access: EC2 Instance Connect Endpoint"
  EICE_ID=$(eice_id)
  if [[ -z "$EICE_ID" ]]; then
    # Client IP not preserved: the node sees the endpoint's address, which the app group's
    # "all from access" rule matches.
    EICE_ID=$(aws ec2 create-instance-connect-endpoint --output text --subnet-id "$PRIVATE_ID" --security-group-ids "$ACCESS_SG" \
        --no-preserve-client-ip --tag-specifications "$(tags instance-connect-endpoint "${NAME_PREFIX}-eice")" \
        --query 'InstanceConnectEndpoint.InstanceConnectEndpointId') || die "Could not create the EC2 Instance Connect Endpoint."
    ok "Created $EICE_ID"
  else
    ok "Using $EICE_ID"
  fi
}

eice_ready() {  # wait_until check: the endpoint's state
  WAIT_STATE=$(none_to_empty "$(aws_q ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EICE_ID" \
      --query 'InstanceConnectEndpoints[0].State')")
  case "$WAIT_STATE" in create-complete) return 0 ;; create-failed|delete-*) return 2 ;; esac
  return 1
}
wait_eice() {  # usually 3-5 minutes from creation
  local rc=0
  wait_until "EC2 Instance Connect Endpoint $EICE_ID" "EC2 Instance Connect Endpoint $EICE_ID ready" 900 10 eice_ready || rc=$?
  [[ $rc -eq 0 ]] || die "EC2 Instance Connect Endpoint $EICE_ID is '${WAIT_STATE:-unknown}'$([[ $rc -eq 1 ]] && echo " after 15 minutes")."
}

ensure_ssm() {
  log "Access: Session Manager (jump host + interface endpoints)"
  local svc name ep
  for svc in $SSM_SERVICES; do
    name="com.amazonaws.$REGION.$svc"
    ep=$(none_to_empty "$(aws_q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$name" \
        "Name=vpc-endpoint-state,Values=pending,available" --query 'VpcEndpoints[0].VpcEndpointId')")
    if [[ -z "$ep" ]]; then
      ep=$(aws ec2 create-vpc-endpoint --output text --vpc-id "$VPC_ID" --vpc-endpoint-type Interface --service-name "$name" \
          --subnet-ids "$PRIVATE_ID" --security-group-ids "$ENDPOINTS_SG" --private-dns-enabled \
          --tag-specifications "$(tags vpc-endpoint "${NAME_PREFIX}-$svc")" --query 'VpcEndpoint.VpcEndpointId') \
        || die "Could not create the $svc endpoint."
      ok "Created $svc endpoint ($ep)"
    else
      ok "$svc endpoint exists ($ep)"
    fi
  done

  if ! aws iam get-role --role-name "$JUMP_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$JUMP_ROLE" --tags "Key=$TAG_KEY,Value=$NAME_PREFIX" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$JUMP_ROLE" \
      --policy-arn "arn:$PARTITION:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ok "Created IAM role $JUMP_ROLE (AmazonSSMManagedInstanceCore)"
  fi
  if ! aws iam get-instance-profile --instance-profile-name "$JUMP_ROLE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$JUMP_ROLE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$JUMP_ROLE" --role-name "$JUMP_ROLE"
    aws iam wait instance-profile-exists --instance-profile-name "$JUMP_ROLE"
    ok "Created instance profile $JUMP_ROLE"
  fi

  JUMP_ID=$(instance_id jump)
  if [[ -z "$JUMP_ID" ]]; then
    local ami attempt
    ami=$(aws_q ssm get-parameter --name "$JUMP_AMI_SSM_PARAM" --query Parameter.Value) \
      || die "Could not look up the Amazon Linux 2023 AMI."
    for attempt in 1 2 3 4 5 6; do   # a new instance profile takes a few seconds to be usable
      JUMP_ID=$(aws_q ec2 run-instances --image-id "$ami" --instance-type "$JUMP_INSTANCE_TYPE" \
          --subnet-id "$PRIVATE_ID" --security-group-ids "$ACCESS_SG" --iam-instance-profile "Name=$JUMP_ROLE" \
          --metadata-options "HttpEndpoint=enabled,HttpTokens=required" \
          --tag-specifications "$(tags instance "${NAME_PREFIX}-jump")" --query 'Instances[0].InstanceId') && break
      [[ $attempt -eq 6 ]] && die "Could not launch the jump host (check iam:PassRole)."
      sleep 10
    done
    ok "Launched jump host $JUMP_ID ($JUMP_INSTANCE_TYPE)"
  else
    ok "Jump host exists ($JUMP_ID)"
  fi
}

ssm_online() {  # wait_until check: the jump host's Session Manager status
  WAIT_STATE=$(none_to_empty "$(aws_q ssm describe-instance-information --filters "Key=InstanceIds,Values=$JUMP_ID" \
      --query 'InstanceInformationList[0].PingStatus')")
  [[ "$WAIT_STATE" == "Online" ]] && return 0
  WAIT_STATE=${WAIT_STATE:-not registered yet}
  return 1
}
wait_ssm() {
  wait_until "Jump host $JUMP_ID in Session Manager" "Jump host $JUMP_ID online in Session Manager" 600 10 ssm_online \
    || die "Jump host $JUMP_ID is not online in Session Manager after 10 minutes; check the endpoints and their security group."
}

# ---------------------------------------------------------------------------
block_device_json() {
  local letters=(b c d e f g) i
  local out="[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_SIZE_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}"
  for ((i = 0; i < DATA_VOLUME_COUNT; i++)); do
    out+=",{\"DeviceName\":\"/dev/sd${letters[$i]}\",\"Ebs\":{\"VolumeSize\":$DATA_VOLUME_SIZE_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}"
  done
  echo "$out]"
}

nodes_running() {  # wait_until check: how many of APP_IDS are running
  local states s r=0 t=0
  states=$(aws_q ec2 describe-instances --instance-ids "${APP_IDS[@]}" --query 'Reservations[].Instances[].State.Name' | tr '\t' '\n') || true
  for s in $states; do t=$((t + 1)); if [[ "$s" == running ]]; then r=$((r + 1)); fi; done
  WAIT_STATE="$r of ${#APP_IDS[@]} running"
  if [[ $t -gt 0 && $r -eq ${#APP_IDS[@]} ]]; then return 0; fi
  if [[ " $(echo $states) " == *" terminated "* || " $(echo $states) " == *" shutting-down "* ]]; then WAIT_STATE+="; one is terminating"; return 2; fi
  return 1
}
ensure_nodes() {
  log "Appliance nodes ($APP_COUNT x $INSTANCE_TYPE)"
  local n id
  APP_IDS=()
  logf INFO "Block devices for new nodes: $(block_device_json)"
  logf INFO "User data for new nodes: $USER_DATA_FILE (sha256 $(_sha256 "$USER_DATA_FILE"))"
  for ((n = 1; n <= APP_COUNT; n++)); do
    id=$(instance_id "node-$n")
    if [[ -z "$id" ]]; then
      id=$(aws_q ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
          --key-name "$KEY_NAME" --subnet-id "$PRIVATE_ID" --security-group-ids "$APP_SG" \
          --metadata-options "HttpEndpoint=enabled,HttpTokens=optional" \
          --block-device-mappings "$(block_device_json)" \
          --user-data "file://$USER_DATA_FILE" \
          --tag-specifications "$(tags instance "${NAME_PREFIX}-node-$n")" \
              "ResourceType=volume,Tags=[{Key=Name,Value=${NAME_PREFIX}-node-$n},{Key=$TAG_KEY,Value=$NAME_PREFIX}]" \
          --query 'Instances[0].InstanceId')
      ok "Launched ${NAME_PREFIX}-node-$n ($id)"
    else
      ok "${NAME_PREFIX}-node-$n exists ($id)"
    fi
    APP_IDS+=("$id")
  done
  wait_until "Starting nodes" "All ${#APP_IDS[@]} nodes running" 600 5 nodes_running \
    || die "Not every node is running after 10 minutes (${WAIT_STATE}); see the log."
  log_detail aws ec2 describe-instances --instance-ids "${APP_IDS[@]}" --output json --query \
      'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,Type:InstanceType,State:State.Name,Ip:PrivateIpAddress,Az:Placement.AvailabilityZone,Launched:LaunchTime,Volumes:BlockDeviceMappings[].[DeviceName,Ebs.VolumeId]}'
}

# ---------------------------------------------------------------------------
ensure_nlb() {
  log "Internal NLB on $NLB_PRIVATE_IP"
  NLB_ARN=$(nlb_arn)
  if [[ -z "$NLB_ARN" ]]; then
    NLB_ARN=$(aws_q elbv2 create-load-balancer --name "${NAME_PREFIX}-nlb" --type network --scheme internal \
        --subnet-mappings "SubnetId=$PRIVATE_ID,PrivateIPv4Address=$NLB_PRIVATE_IP" --security-groups "$NLB_SG" \
        --tags "Key=Name,Value=${NAME_PREFIX}-nlb" "Key=$TAG_KEY,Value=$NAME_PREFIX" \
        --query 'LoadBalancers[0].LoadBalancerArn')
    ok "Created internal NLB ${NAME_PREFIX}-nlb"
  else
    ok "Using ${NAME_PREFIX}-nlb"
  fi

  local port tg targets stale t
  targets=$(printf 'Id=%s ' "${APP_IDS[@]}")
  for port in $APP_PORTS; do
    tg=$(none_to_empty "$(aws_q elbv2 describe-target-groups --names "${NAME_PREFIX}-tg-$port" --query 'TargetGroups[0].TargetGroupArn' || true)")
    if [[ -z "$tg" ]]; then
      tg=$(aws_q elbv2 create-target-group --name "${NAME_PREFIX}-tg-$port" --protocol TCP --port "$port" \
          --vpc-id "$VPC_ID" --target-type instance --health-check-protocol TCP \
          --tags "Key=$TAG_KEY,Value=$NAME_PREFIX" --query 'TargetGroups[0].TargetGroupArn')
    fi
    # Client IP preservation on breaks a node reaching itself through the NLB (the VIP).
    aws elbv2 modify-target-group-attributes --target-group-arn "$tg" \
        --attributes "Key=preserve_client_ip.enabled,Value=$PRESERVE_CLIENT_IP" >/dev/null
    # shellcheck disable=SC2086
    aws elbv2 register-targets --target-group-arn "$tg" --targets $targets
    stale=""
    for t in $(aws_q elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].Target.Id'); do
      [[ " ${APP_IDS[*]} " == *" $t "* ]] || stale+="Id=$t "
    done
    # shellcheck disable=SC2086
    [[ -z "$stale" ]] || aws elbv2 deregister-targets --target-group-arn "$tg" --targets $stale
    if ! aws_q elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" \
         --query "Listeners[?Port==\`$port\`].ListenerArn" | grep -q arn; then
      aws elbv2 create-listener --load-balancer-arn "$NLB_ARN" --protocol TCP --port "$port" \
        --default-actions "Type=forward,TargetGroupArn=$tg" >/dev/null
    fi
    ok "TCP $port -> ${NAME_PREFIX}-tg-$port (${#APP_IDS[@]} target(s))"
  done

  wait_nlb_active
  log_detail aws elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" --output json \
      --query 'Listeners[].{Port:Port,Protocol:Protocol,TargetGroup:DefaultActions[0].TargetGroupArn}'
  NLB_DNS=$(aws_q elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].DNSName')
  ok "NLB active: $NLB_DNS ($(nlb_private_ip "$NLB_ARN"))"
}

wait_nlb_active() {  # one live line (state and elapsed time) until NLB_ARN is active
  local start=$SECONDS tick=0 state="" el last=""
  log "Waiting for the NLB to become active (usually 2-5 minutes)"
  while :; do
    el=$(elapsed $((SECONDS - start)))
    if (( tick % 20 == 0 )); then                      # ask AWS every 5 seconds
      state=$(aws_q elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].State.Code')
      if [[ "$state" != "${last:-}" ]]; then logf INFO "NLB ${NAME_PREFIX}-nlb: ${state:-unknown} after $el"; last=$state; fi
      case "$state" in
        active) break ;;
        active_impaired) warn "NLB is active but impaired."; break ;;
        failed) end_line; die "NLB ${NAME_PREFIX}-nlb failed to provision." ;;
      esac
      if (( SECONDS - start > 900 )); then end_line; die "NLB still ${state:-unknown} after 15 minutes."; fi
      if [[ ! -t 1 ]] && (( tick % 120 == 0 )); then echo "  NLB ${NAME_PREFIX}-nlb ${state:-checking} $el"; fi
    fi
    spin_line "$tick" "NLB ${NAME_PREFIX}-nlb ${state:-checking} $el"
    sleep 0.25; tick=$((tick + 1))
  done
  check_line "NLB ${NAME_PREFIX}-nlb active after $(elapsed $((SECONDS - start)))"
}

# ---------------------------------------------------------------------------
summary() {
  local ips
  ips=$(node_ips)
  {
    echo "NAME_PREFIX=$NAME_PREFIX"
    echo "REGION=$REGION"
    echo "AZ=$AZ"
    echo "VPC_ID=$VPC_ID"
    echo "ACCESS_METHOD=$ACCESS_METHOD"
    [[ "$ACCESS_METHOD" == "eice" ]] && echo "EICE_ID=$EICE_ID" || echo "JUMP_ID=$JUMP_ID"
    echo "APP_IDS=\"${APP_IDS[*]}\""
    echo "APP_PRIVATE_IPS=\"$ips\""
    echo "NLB_ARN=$NLB_ARN"
    echo "NLB_DNS=$NLB_DNS"
    echo "VIP=$NLB_PRIVATE_IP"
    echo "DATA_DRIVE=$DATA_DRIVE"
  } > "$OUTPUT_FILE"
  logf INFO "Wrote $OUTPUT_FILE:"
  log_file out "$OUTPUT_FILE"

  log "Done. Outputs saved to $OUTPUT_FILE"
  cat <<EOF

  Nodes (private):        $ips
  VIP for Cluster Config: $NLB_PRIVATE_IP   (the NLB's private IP)
  Storage Pool Drive:     $DATA_DRIVE  (the data drive; ./connect.sh link confirms it on each node)
  NLB:                    $NLB_DNS

  Local UI in about 25-30 minutes. From your workstation:
    ./connect.sh localui        forwards every node's 5080 (node 1 -> https://localhost:5080)
    ./connect.sh ssh 1          shell on node 1
    ./connect.sh api            forwards the VIP's 6443 for kubectl
    ./connect.sh console        forwards the VIP's 443: VerteX at https://localhost:8443/system
EOF
  if [[ "$NO_NLB" == "true" ]]; then cat <<EOF

  Next: link the nodes, create the cluster with VIP $NLB_PRIVATE_IP, click Deploy Cluster,
  then run ./deploy.sh to create the NLB on that IP.
EOF
  else cat <<EOF

  Next: ./status.sh --watch    follows the NLB and each port until every port is healthy
EOF
  fi
  echo
}

preflight
[[ "$PREFLIGHT_ONLY" == "true" ]] && { log "Preflight passed. No resources created."; exit 0; }
ensure_security_groups
if [[ "$ACCESS_METHOD" == "eice" ]]; then ensure_eice; else ensure_ssm; fi
ensure_nodes
if [[ "$ACCESS_METHOD" == "eice" ]]; then wait_eice; else wait_ssm; fi
if [[ "$NO_NLB" == "true" ]]; then
  NLB_ARN="(not created: --no-nlb)"; NLB_DNS="(not created yet)"
  warn "NLB not created. Enter VIP $NLB_PRIVATE_IP in Local UI, click Deploy Cluster, then run ./deploy.sh."
else
  ensure_nlb
fi
summary
