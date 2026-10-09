#!/usr/bin/env bash
# Copy container images from one node's containerd to another's and pin them on the target,
# so kubelet image garbage collection can't delete them again.
#
# Usage: ./copy-images.sh [-c config.env] <from-node> <to-node> <image>...
#        ./copy-images.sh [-c config.env] <from-node> <to-node> -f <file>   (one image per line, # comments)
#
# Why: the appliance preloads its system images (k8s, calico, piraeus, mongo, cert-manager,
# palette agents) on every node, and the stylus webhook does not redirect them to zot. If
# kubelet garbage-collects one (disk over 85%), an airgapped node can't pull it back.
#
# How: ssh -A forwards your ssh-agent to <from-node>, which streams each image straight to
# <to-node>'s private IP. Your key stays on your workstation, and the data never crosses the EICE
# tunnel (too slow, and it can drop the end of a long stream). Images already on <to-node>
# are only pinned. Needs ACCESS_METHOD=eice and node-to-node traffic (NODE_TO_NODE=true).

set -euo pipefail
[[ "${1:-}" == "-c" ]] && { CONFIG="$2"; shift 2; }
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

CTR=/opt/bin/ctr   # containerd's ctr on the appliance nodes; not on sudo's PATH

[[ $# -ge 3 ]] || { sed -n '2,15p' "$0"; exit 2; }
FROM="$1"; TO="$2"; shift 2
if [[ "$1" == "-f" ]]; then
  [[ -f "${2:-}" ]] || die "Image list '${2:-}' not found."
  # shellcheck disable=SC2207
  IMAGES=($(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$2"))
else
  IMAGES=("$@")
fi
[[ ${#IMAGES[@]} -gt 0 ]] || die "No images given."

[[ "$ACCESS_METHOD" == "eice" ]] || die "copy-images.sh supports ACCESS_METHOD=eice only."
[[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]] || die "Set SSH_KEY_FILE in $CONFIG to the private key for $KEY_NAME."
require_aws
require_agent   # agent forwarding needs the key loaded in your workstation's ssh-agent

# shellcheck disable=SC2207
IDS=($(node_ids)); IPS=($(node_ips))
for n in "$FROM" "$TO"; do
  [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#IDS[@]} ]] || die "Node must be 1-${#IDS[@]}."
done
[[ "$FROM" != "$TO" ]] || die "From and to are the same node."

log "Copying ${#IMAGES[@]} image(s) from node $FROM (${IPS[$((FROM - 1))]}) to node $TO (${IPS[$((TO - 1))]})"
# The remote script is wrapped in a function so bash reads all of it before the inner ssh
# commands run; ssh -n keeps the check from reading the script off stdin.
ssh -A -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --region $REGION --instance-id %h" \
    "$SSH_USER@${IDS[$((FROM - 1))]}" bash -s -- "$CTR" "$SSH_USER@${IPS[$((TO - 1))]}" "${IMAGES[@]}" <<'REMOTE'
main() {
  set -uo pipefail
  local ctr="$1" to="$2" img copied=0 pinned=0 failed=0; shift 2
  local opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
  local pin="io.cri-containerd.pinned=pinned"
  for img in "$@"; do
    if ssh -n "${opts[@]}" "$to" "sudo $ctr -n k8s.io images ls -q | grep -qxF '$img'"; then
      if ssh -n "${opts[@]}" "$to" "sudo $ctr -n k8s.io images label '$img' $pin >/dev/null"; then
        echo "  pinned  $img (already there)"; pinned=$((pinned + 1))
      else
        echo "  FAILED  $img (pin)"; failed=$((failed + 1))
      fi
    elif sudo "$ctr" -n k8s.io images export --platform linux/amd64 - "$img" \
        | ssh "${opts[@]}" "$to" "sudo $ctr -n k8s.io images import --platform linux/amd64 - >/dev/null && sudo $ctr -n k8s.io images label '$img' $pin >/dev/null"; then
      echo "  copied  $img"; copied=$((copied + 1))
    else
      echo "  FAILED  $img"; failed=$((failed + 1))
    fi
  done
  echo "$copied copied, $pinned already there (pinned), $failed failed"
  [[ $failed -eq 0 ]]
}
main "$@"
REMOTE
