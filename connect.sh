#!/usr/bin/env bash
# Reach the private nodes from your Mac through the deployment's ACCESS_METHOD.
#
# Usage: ./connect.sh [-c config.env] <command>
#   localui      forward every node's Local UI: node N -> https://localhost:<5079+N>
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

# shellcheck disable=SC2207
IDS=($(node_ids)); IPS=($(node_ips))
[[ ${#IDS[@]} -gt 0 ]] || die "No running nodes for $NAME_PREFIX."

need_key() {
  [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]] || die "Set SSH_KEY_FILE in $CONFIG to the private key for $KEY_NAME."
}
eice_ssh() {  # extra ssh options... -> ssh to node 1 through the endpoint
  need_key
  ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
      -o ProxyCommand="aws ec2-instance-connect open-tunnel --region $REGION --instance-id %h" "$@"
}
ssm_forward() {  # remote-host remote-port local-port  (runs in the background)
  local jump
  jump=$(instance_id jump); [[ -n "$jump" ]] || die "No jump host for $NAME_PREFIX (ACCESS_METHOD=ssm)."
  aws ssm start-session --target "$jump" --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"$2\"],\"localPortNumber\":[\"$3\"]}" >/dev/null &
}
wait_port() {  # local-port: wait until something listens on it
  local i
  for i in $(seq 1 30); do nc -z localhost "$1" 2>/dev/null && return 0; sleep 1; done
  die "Nothing listening on localhost:$1 after 30 seconds."
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

  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
