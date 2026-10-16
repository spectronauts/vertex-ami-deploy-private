# Shared helpers for the ami-deploy-private scripts. Sourced, not run.
# shellcheck shell=bash

CONFIG="${CONFIG:-config.env}"
SCRIPT_NAME=$(basename "$0")
LOG_FILE=""

# Console messages; each one is also written to the run log (see "Run log" below).
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; logf INFO "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; logf OK "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; logf WARN "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; logf ERROR "$*"; _DIED=1; exit 1; }

# --- Run log ------------------------------------------------------------------------------------
# Every run writes logs/<script>-<NAME_PREFIX>-<UTC time>.log (LOG_DIR overrides logs/): the
# run's settings and workstation, then every AWS CLI call (arguments, exit code, time taken,
# full output and errors, including errors the console hides), every Local UI API call, every
# ssh/kubectl step, each poll of a wait, and the failing command if the run stops. Passwords,
# login tokens, link tokens and AWS secrets are written as <redacted>. Files are private (0600).
_redact() {  # stdin -> stdout with secrets masked
  sed -E \
    -e 's/("([Pp]ass(word|wd)|[Tt]oken|[Aa]uthorization|[Oo]tp|[Ss]ecret[A-Za-z]*|SessionToken|SecretAccessKey)"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1"<redacted>"/g' \
    -e 's/([Aa]uthorization:[[:space:]]*)[^[:space:]]+/\1<redacted>/g' \
    -e 's/eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*/<redacted-jwt>/g' \
    -e 's/(passwd:[[:space:]]*).+/\1<redacted>/' \
    -e 's/(mongo\.key"?[[:space:]]*:[[:space:]]*)"?[A-Za-z0-9+\/=]{16,}"?/\1<redacted>/g' \
    -e 's/(aws_secret_access_key|aws_session_token)([[:space:]]*=[[:space:]]*).+/\1\2<redacted>/'
}
_log_where() {  # the calling function chain, without the logging helpers
  local i f out=""
  for ((i = ${#FUNCNAME[@]} - 1; i >= 1; i--)); do
    f=${FUNCNAME[$i]}
    case "$f" in main|source|logf|log_text|log_file|_log_where|log|ok|warn|die|aws|aws_q|none_to_empty|_on_exit|_on_signal|_log_bg|log_init|_log_header|check_line) continue ;; esac
    out+="${out:+>}$f"
  done
  printf '%s' "${out:-main}"
}
logf() {  # LEVEL message...: one timestamped line in the run log (nothing before log_init)
  [[ -n "$LOG_FILE" ]] || return 0
  local lvl=$1; shift
  printf '%s +%-5s %-5s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SECONDS}s" "$lvl" "$(_log_where)" "$*" | _redact >&9
}
log_text() {  # label text: text as indented lines under the previous log line
  [[ -n "$LOG_FILE" && -n "$2" ]] || return 0
  printf '%s\n' "$2" | awk -v p="      $1| " -v max=2000 \
    'NR <= max { print p $0 } END { if (NR > max) print p "... " NR - max " more lines" }' | _redact >&9
}
log_file() {  # label file: a file's lines, indented, in the run log
  [[ -n "$LOG_FILE" && -s "$2" ]] || return 0
  awk -v p="      $1| " -v max=2000 \
    'NR <= max { print p $0 } END { if (NR > max) print p "... " NR - max " more lines" }' "$2" | _redact >&9
}
log_detail() {  # command...: run it for the log only (output recorded there, not shown)
  "$@" >/dev/null 2>&1 || true
}
_quote_args() {  # args -> one line a shell could re-run (args with special characters quoted)
  local a out="" safe='^[A-Za-z0-9_./:=,@%+-]+$'
  for a in "$@"; do
    if [[ $a =~ $safe ]]; then out+=" $a"
    elif [[ "$a" != *"'"* ]]; then out+=" '$a'"
    else out+=" $(printf '%q' "$a")"; fi
  done
  printf '%s' "${out# }"
}
# Millisecond clock for timing calls: bash 5's EPOCHREALTIME, GNU date, perl, or whole seconds.
if [[ -n "${EPOCHREALTIME:-}" ]]; then _clock() { local t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); }
elif [[ "$(date +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then _clock() { date +%s%3N; }
elif command -v perl >/dev/null 2>&1; then _clock() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'; }
else _clock() { echo $((SECONDS * 1000)); }; fi
elapsed() {  # seconds -> "42s" or "3m05s"
  if [[ $1 -lt 60 ]]; then echo "${1}s"; else printf '%dm%02ds\n' $(($1 / 60)) $(($1 % 60)); fi
}
_took() {  # start-ms -> "1.234s"
  local ms=$(( $(_clock) - $1 ))
  printf '%d.%03ds' $((ms / 1000)) $((ms % 1000))
}

aws() {  # every AWS CLI call: run it, then log arguments, exit code, time, output and errors
  if [[ -z "$LOG_FILE" ]]; then command aws "$@"; return; fi
  local out err rc=0 t0
  out=$(mktemp "$_LOG_TMP/aws.XXXXXX"); err="$out.err"
  if [[ "${1:-} ${2:-}" == *" wait" ]]; then logf DEBUG "aws $(_quote_args "$@")  (waiting...)"; fi
  t0=$(_clock)
  command aws "$@" >"$out" 2>"$err" || rc=$?
  logf DEBUG "aws $(_quote_args "$@")  -> exit $rc in $(_took "$t0")"
  if [[ $rc -ne 0 ]]; then _LAST_AWS_FAIL="aws $(_quote_args "$@") (exit $rc): $(grep -v '^[[:space:]]*$' "$err" | tail -1)"; fi
  log_file out "$out"; log_file err "$err"
  cat "$out"; cat "$err" >&2
  rm -f "$out" "$err"
  return $rc
}

_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-16; else sha256sum "$1" | cut -c1-16; fi; }
_tool_version() {  # tool -> its version line, or "not installed"
  if ! type -P "$1" >/dev/null 2>&1; then echo "not installed"; return; fi
  case "$1" in
    aws) command aws --version 2>&1 | head -1 ;;
    ssh) ssh -V 2>&1 | head -1 ;;
    curl) curl --version 2>/dev/null | head -1 ;;
    kubectl) kubectl version --client 2>/dev/null | head -1 ;;
    session-manager-plugin) session-manager-plugin --version 2>/dev/null | head -1 ;;
    *) "$1" --version 2>&1 | head -1 ;;
  esac
}
_log_header() {  # what ran, where, with which settings and tools
  local v git_desc="not a git checkout"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git_desc="$(git rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git rev-parse --short HEAD 2>/dev/null)"
    git_desc+=", $(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ') modified file(s)"
  fi
  local tty="is not"; if [[ -t 1 ]]; then tty="is"; fi
  logf INFO "==== $SCRIPT_NAME $(_quote_args "${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}")"
  log_text run "$(
    printf 'started     %s (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'directory   %s (run from %s)\n' "$PWD" "${OLDPWD:-$PWD}"
    printf 'repo        %s\n' "$git_desc"
    printf 'config      %s (sha256 %s)\n' "$CONFIG_PATH" "$(_sha256 "$CONFIG")"
    printf 'workstation %s, bash %s, user %s\n' "$(uname -srm)" "$BASH_VERSION" "$(id -un)"
    printf 'terminal    stdout %s a terminal, TERM=%s\n' "$tty" "${TERM:-unset}")"
  log_text tool "$(for v in session-manager-plugin ssh curl jq kubectl; do printf '%-23s %s\n' "$v" "$(_tool_version "$v")"; done)"
  log_text env "$(
    printf 'AWS_PROFILE=%s AWS_REGION=%s AWS_DEFAULT_REGION=%s\n' "${AWS_PROFILE:-unset}" "${AWS_REGION:-unset}" "${AWS_DEFAULT_REGION:-unset}"
    printf 'AWS_CONFIG_FILE=%s AWS_SHARED_CREDENTIALS_FILE=%s\n' "${AWS_CONFIG_FILE:-default}" "${AWS_SHARED_CREDENTIALS_FILE:-default}"
    for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
      if [[ -n "${!v:-}" ]]; then printf '%s is set\n' "$v"; else printf '%s is not set\n' "$v"; fi
    done)"
  log_text cfg "$(for v in NAME_PREFIX REGION AZ VPC_CIDR PRIVATE_CIDR AMI_ID KEY_NAME INSTANCE_TYPE APP_COUNT APP_PORTS \
      ROOT_VOLUME_SIZE_GB DATA_VOLUME_COUNT DATA_VOLUME_SIZE_GB USER_DATA_FILE NODE_TO_NODE PRESERVE_CLIENT_IP \
      NLB_PRIVATE_IP ACCESS_METHOD JUMP_INSTANCE_TYPE JUMP_AMI_SSM_PARAM SSH_USER SSH_KEY_FILE LOCALUI_USER; do
      printf '%-20s %s\n' "$v" "${!v:-}"; done
      printf '%-20s %s\n' LOCALUI_PASSWORD "$([[ -n "${LOCALUI_PASSWORD:-}" ]] && echo '(set)' || echo '(not set)')")"
}
log_init() {  # start this run's log file; everything after is recorded in it
  local dir="${LOG_DIR:-logs}" f
  _LOG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/vxp-run.XXXXXX")   # scratch files; removed on exit
  _DIED=""
  trap '_on_exit $? "$BASH_COMMAND" $LINENO' EXIT
  trap '_on_signal INT 130' INT
  trap '_on_signal TERM 143' TERM
  [[ "$dir" == /* ]] || dir="$PWD/$dir"
  if ! { mkdir -p "$dir" && chmod 700 "$dir"; } 2>/dev/null; then warn "Can't create $dir; continuing without a log file."; return 0; fi
  f="$dir/${LOG_NAME:-${SCRIPT_NAME%.sh}}-${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ).log"
  if ! (umask 077; : >>"$f") 2>/dev/null; then warn "Can't write $f; continuing without a log file."; return 0; fi
  exec 9>>"$f"
  LOG_FILE=$f
  _log_header
  printf '\033[2m  Log: %s\033[0m\n' "${LOG_FILE/#$HOME/~}"
}
_on_signal() {  # name exit-code
  if [[ -t 1 ]]; then printf '\n'; fi
  logf WARN "Interrupted by SIG$1"
  exit "$2"
}
_log_bg() {  # background processes' output (ssh forwards, SSM sessions) into the log
  local f
  for f in "$_LOG_TMP"/*.bg; do
    [[ -s "$f" ]] || continue
    logf DEBUG "output of background process $(basename "$f" .bg):"
    log_file bg "$f"
  done
}
_on_exit() {  # exit-code last-command line: stop background processes, finish the log
  local rc=$1 pids i chain="" cmd
  if [[ "${KILL_JOBS_ON_EXIT:-}" == "true" ]]; then
    pids=$(jobs -p)
    if [[ -n "$pids" ]]; then logf DEBUG "stopping background processes: $(echo $pids)"; kill $pids 2>/dev/null || true; sleep 0.2; fi
  fi
  _log_bg
  if [[ $rc -eq 0 ]]; then
    logf INFO "==== finished OK in $(elapsed $SECONDS)"
  else
    if [[ -z "$_DIED" && $rc -ne 130 && $rc -ne 143 && "$2" != exit* ]]; then   # set -e stopped the run: say where
      for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do [[ "${FUNCNAME[$i]}" == main ]] || chain+="${chain:+ < }${FUNCNAME[$i]}"; done
      cmd=$2; if [[ "$cmd" == 'return $rc' && -n "${_LAST_AWS_FAIL:-}" ]]; then cmd=$_LAST_AWS_FAIL; fi
      logf ERROR "stopped by a failed command (exit $rc) at ${BASH_SOURCE[1]##*/}:$3${chain:+ in $chain}: $cmd"
    fi
    logf INFO "==== finished with exit code $rc in $(elapsed $SECONDS)"
    if [[ -n "$LOG_FILE" && "${QUIET_EXIT:-}" != "true" ]]; then printf '  Log: %s\n' "${LOG_FILE/#$HOME/~}" >&2; fi
  fi
  rm -rf "$_LOG_TMP"
}

[[ -f "$CONFIG" ]] || die "Config file '$CONFIG' not found. Copy config.env.example to config.env and fill it in."
CONFIG_PATH="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
# shellcheck disable=SC1090
source "$CONFIG"

: "${NAME_PREFIX:=vxp}" "${AZ:=}" "${VPC_CIDR:=10.0.0.0/16}" "${PRIVATE_CIDR:=10.0.11.0/24}"
: "${APP_PORTS:=443 6443 30003 5080}" "${APP_COUNT:=3}"
: "${INSTANCE_TYPE:=m5.2xlarge}" "${ROOT_VOLUME_SIZE_GB:=300}"
: "${DATA_VOLUME_COUNT:=1}" "${DATA_VOLUME_SIZE_GB:=500}"
: "${USER_DATA_FILE:=user-data.yaml}" "${NODE_TO_NODE:=true}" "${PRESERVE_CLIENT_IP:=false}" "${NLB_PRIVATE_IP:=}"
: "${ACCESS_METHOD:=eice}" "${JUMP_INSTANCE_TYPE:=t3.micro}" "${SSH_USER:=kairos}" "${SSH_KEY_FILE:=}"
: "${LOCALUI_USER:=}" "${AMI_ID:=}" "${KEY_NAME:=}"
# A leading ~ inside quotes ("~/keys/x.pem") isn't expanded by the shell; expand it here.
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
USER_DATA_FILE="${USER_DATA_FILE/#\~/$HOME}"
: "${JUMP_AMI_SSM_PARAM:=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}"

# Which settings this run uses, first thing, so a run from the wrong directory is obvious.
printf '  Config: %s (NAME_PREFIX=\033[1m%s\033[0m, REGION=%s)\n' "${CONFIG_PATH/#$HOME/~}" "$NAME_PREFIX" "${REGION:-not set}"
log_init

[[ -n "${REGION:-}" ]] || die "REGION is required in $CONFIG (for example us-gov-west-1)."
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""   # print AWS CLI output to the terminal instead of a pager (less)
TAG_KEY="vxp:deployment"
OUTPUT_FILE="outputs-${NAME_PREFIX}.txt"
JUMP_ROLE="${NAME_PREFIX}-jump"
SSM_SERVICES="ssm ssmmessages ec2messages"

aws_q() { aws "$@" --output text 2>/dev/null; }
none_to_empty() { [[ "$1" == "None" ]] && echo "" || echo "$1"; }

# --- Settings check: every script, before anything else; no AWS calls ---------------------------
# Names any setting no script can use; create-aws-infra.sh and deploy.sh stop on them
# (CONFIG_PROBLEMS), the others carry on so a bad edit never blocks ./teardown.sh. Values allowed
# but known to break the install get a warning only.
KNOWN_SETTINGS=" REGION NAME_PREFIX AMI_ID KEY_NAME SSH_KEY_FILE NLB_PRIVATE_IP ACCESS_METHOD APP_COUNT
  INSTANCE_TYPE ROOT_VOLUME_SIZE_GB DATA_VOLUME_SIZE_GB DATA_VOLUME_COUNT USER_DATA_FILE AZ VPC_CIDR
  PRIVATE_CIDR LOCALUI_USER LOCALUI_PASSWORD SSH_USER JUMP_INSTANCE_TYPE JUMP_AMI_SSM_PARAM LOG_DIR
  APP_PORTS NODE_TO_NODE PRESERVE_CLIENT_IP "
ip_to_int() {  # dotted IPv4 -> integer, or fail if malformed
  local IFS=. o n=0
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  for o in $1; do o=$((10#$o)); [[ $o -le 255 ]] || return 1; n=$((n * 256 + o)); done
  echo "$n"
}
usable_ip() {  # ip cidr -> 0 if ip is a host address AWS lets you assign (it reserves the first four and the last)
  local ip net bits size
  ip=$(ip_to_int "$1") && net=$(ip_to_int "${2%/*}") || return 1
  bits=${2#*/}; size=$((1 << (32 - bits)))
  [[ $ip -ge $((net + 4)) && $ip -lt $((net + size - 1)) ]]
}
cidr_ok() {  # cidr -> 0 if it is a network address with a /16 to /28 prefix (what AWS allows)
  local net bits
  [[ "$1" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || return 1
  net=$(ip_to_int "${1%/*}") || return 1; bits=$((10#${1#*/}))
  [[ $bits -ge 16 && $bits -le 28 && $((net % (1 << (32 - bits)))) -eq 0 ]]
}
cidr_within() {  # inner outer -> 0 if inner lies inside outer
  local i o ib ob
  i=$(ip_to_int "${1%/*}") && o=$(ip_to_int "${2%/*}") || return 1
  ib=$((10#${1#*/})); ob=$((10#${2#*/}))
  [[ $ib -ge $ob && $((i - i % (1 << (32 - ob)))) -eq $o ]]
}
check_config() {  # sets CONFIG_PROBLEMS
  local bad=() name p
  for name in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$CONFIG"); do
    if [[ "$KNOWN_SETTINGS" != *[[:space:]]"$name"[[:space:]]* ]]; then
      bad+=("$CONFIG sets $name, which no script reads (a typo?).")
    fi
  done
  if [[ ! "$REGION" =~ ^[a-z]{2}(-gov|-iso[a-z]*)?-[a-z]+-[0-9]$ ]]; then bad+=("REGION '$REGION' is not an AWS region name (for example us-gov-west-1)."); fi
  if [[ ! "$NAME_PREFIX" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,18}[A-Za-z0-9])?$ ]]; then
    bad+=("NAME_PREFIX '$NAME_PREFIX': use up to 20 letters, digits and dashes, not starting or ending with a dash."); fi
  if [[ -n "${AMI_ID:-}" && ! "${AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]]; then bad+=("AMI_ID '$AMI_ID' is not an AMI ID (ami-0123456789abcdef0)."); fi
  if [[ "$ACCESS_METHOD" != eice && "$ACCESS_METHOD" != ssm ]]; then bad+=("ACCESS_METHOD '$ACCESS_METHOD': use eice or ssm."); fi
  if [[ ! "$APP_COUNT" =~ ^[1-9]$ ]]; then bad+=("APP_COUNT '$APP_COUNT': use 3 for a cluster or 1 for a single node."); fi
  if [[ ! "$INSTANCE_TYPE" =~ ^[a-z][a-z0-9-]*\.[a-z0-9]+$ ]]; then bad+=("INSTANCE_TYPE '$INSTANCE_TYPE' is not an instance type (m5.2xlarge)."); fi
  if [[ ! "$ROOT_VOLUME_SIZE_GB" =~ ^[0-9]+$ ]]; then bad+=("ROOT_VOLUME_SIZE_GB '$ROOT_VOLUME_SIZE_GB': a whole number of GB, at least 300."); fi
  if [[ ! "$DATA_VOLUME_SIZE_GB" =~ ^[0-9]+$ ]] || (( DATA_VOLUME_SIZE_GB < 1 || DATA_VOLUME_SIZE_GB > 16384 )); then
    bad+=("DATA_VOLUME_SIZE_GB '$DATA_VOLUME_SIZE_GB': a whole number of GB from 1 to 16384."); fi
  if [[ ! "$DATA_VOLUME_COUNT" =~ ^[1-6]$ ]]; then bad+=("DATA_VOLUME_COUNT '$DATA_VOLUME_COUNT': use 1; the AMI builds its storage pool on one data disk."); fi
  if ! cidr_ok "$VPC_CIDR"; then bad+=("VPC_CIDR '$VPC_CIDR': a network address with a /16 to /28 prefix (10.0.0.0/16)."); fi
  if ! cidr_ok "$PRIVATE_CIDR"; then bad+=("PRIVATE_CIDR '$PRIVATE_CIDR': a network address with a /16 to /28 prefix (10.0.11.0/24).")
  elif cidr_ok "$VPC_CIDR" && ! cidr_within "$PRIVATE_CIDR" "$VPC_CIDR"; then bad+=("PRIVATE_CIDR $PRIVATE_CIDR is not inside VPC_CIDR $VPC_CIDR."); fi
  if [[ -n "$NLB_PRIVATE_IP" ]] && ! usable_ip "$NLB_PRIVATE_IP" "$PRIVATE_CIDR"; then
    bad+=("NLB_PRIVATE_IP '$NLB_PRIVATE_IP' is not an address AWS lets you assign in PRIVATE_CIDR $PRIVATE_CIDR (it keeps the first four and the last)."); fi
  for p in $APP_PORTS; do
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then bad+=("APP_PORTS has '$p', which is not a port number."); fi
  done
  if [[ "$NODE_TO_NODE" != true && "$NODE_TO_NODE" != false ]]; then bad+=("NODE_TO_NODE '$NODE_TO_NODE': use true."); fi
  if [[ "$PRESERVE_CLIENT_IP" != true && "$PRESERVE_CLIENT_IP" != false ]]; then bad+=("PRESERVE_CLIENT_IP '$PRESERVE_CLIENT_IP': use false."); fi
  if [[ -z "$SSH_USER" ]]; then bad+=("SSH_USER is empty; use kairos."); fi
  # Allowed, but each breaks the install or the tools:
  for p in 443 6443 30003; do
    if [[ " $APP_PORTS " != *" $p "* ]]; then warn "APP_PORTS leaves out $p, which the cluster needs behind the VIP."; fi
  done
  if [[ "$NODE_TO_NODE" == false && "$APP_COUNT" != 1 ]]; then warn "NODE_TO_NODE=false: the nodes can't link or form a cluster."; fi
  if [[ "$PRESERVE_CLIENT_IP" == true ]]; then warn "PRESERVE_CLIENT_IP=true: a node can't reach its own API through the VIP."; fi
  if [[ "$APP_COUNT" =~ ^[0-9]+$ && $((APP_COUNT % 2)) -eq 0 ]]; then warn "APP_COUNT=$APP_COUNT: use an odd number (3) so etcd keeps a majority."; fi
  if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then warn "SSH_KEY_FILE $SSH_KEY_FILE doesn't exist."; fi
  for p in ${bad[@]+"${bad[@]}"}; do warn "$p"; done
  CONFIG_PROBLEMS=${#bad[@]}
  logf INFO "Settings check: $CONFIG_PROBLEMS problem(s)"
}
check_config

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
      ssh|ssh-add|ssh-agent|ssh-keygen|curl) echo "it ships with macOS; check your PATH" ;;
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
    jq|curl)
      if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $1"
      else echo "sudo dnf install -y $1"; fi ;;
    ssh|ssh-add|ssh-agent|ssh-keygen)
      if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y openssh-client"
      else echo "sudo dnf install -y openssh-clients"; fi ;;
    *) echo "install $1 with your package manager" ;;
  esac
}

require_tools() {  # tool... -> stop, with an install command per tool, if any is missing
  local t missing=""
  for t in "$@"; do   # type -P: the program on PATH (aws is also a logging function here)
    if type -P "$t" >/dev/null 2>&1; then logf DEBUG "found $t: $(type -P "$t")"
    else warn "$t not found. Install: $(install_hint "$t")"; missing=1; fi
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
  logf INFO "AWS CLI ${v#aws-cli/}; identity $CALLER_ARN; partition $PARTITION; region $REGION"
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo "?"; }  # GNU, then BSD stat
ssh_key_info() {  # private-key-file -> "mode 600, SHA256:... (RSA)", for the log
  local fp
  fp=$(ssh-keygen -y -P '' -f "$1" 2>/dev/null | ssh-keygen -l -f - 2>/dev/null | awk '{print $2, $NF}')
  printf 'mode %s, %s' "$(file_mode "$1")" "${fp:-public key unreadable (passphrase-protected, too open, or not a key)}"
}
check_ssh_key() {  # warn now if SSH_KEY_FILE won't let ./connect.sh sign in to the nodes as SSH_USER
  local mode mine theirs
  if [[ -z "$SSH_KEY_FILE" ]]; then logf INFO "SSH_KEY_FILE not set (./connect.sh needs it for eice, and for ssh with ssm)"; return 0; fi
  if [[ ! -f "$SSH_KEY_FILE" ]]; then warn "SSH_KEY_FILE $SSH_KEY_FILE doesn't exist; ./connect.sh needs it."; return 0; fi
  logf INFO "SSH key $SSH_KEY_FILE: $(ssh_key_info "$SSH_KEY_FILE")"
  mode=$(file_mode "$SSH_KEY_FILE")
  if [[ "$mode" =~ ^[0-7]+$ ]] && (( 8#$mode & 8#077 )); then
    warn "ssh won't use $SSH_KEY_FILE while others can read it (mode $mode). Run: chmod 600 $SSH_KEY_FILE"
    return 0
  fi
  mine=$(ssh-keygen -y -P '' -f "$SSH_KEY_FILE" 2>/dev/null | awk '{print $2}')
  theirs=$(none_to_empty "$(aws_q ec2 describe-key-pairs --key-names "$KEY_NAME" --include-public-key --query 'KeyPairs[0].PublicKey')" | awk '{print $2}')
  if [[ -z "$mine" || -z "$theirs" ]]; then logf INFO "Could not compare SSH_KEY_FILE with key pair $KEY_NAME's public key"
  elif [[ "$mine" == "$theirs" ]]; then ok "SSH_KEY_FILE is the private key for key pair $KEY_NAME"
  else warn "SSH_KEY_FILE $SSH_KEY_FILE is not the private key for key pair $KEY_NAME; ./connect.sh won't be able to sign in as $SSH_USER."
  fi
}

port_open() {  # host port -> 0 if something accepts TCP connections there (bash /dev/tcp; no nc needed)
  (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
}

# --- Live progress: in-place spinner lines in a terminal, plain lines otherwise -------------
SPIN=('|' '/' '-' '\')
GREEN_CHECK=$'\033[1;32m✓\033[0m'
TERM_COLS=$( (tput cols 2>/dev/null || echo 120) | tr -dc '0-9' ); TERM_COLS=${TERM_COLS:-120}
spin_line() {  # tick text: one in-place line with a spinner (terminals only), cut to the terminal's width
  local t=$2
  if (( ${#t} > TERM_COLS - 6 )); then t="${t:0:$((TERM_COLS - 7))}~"; fi   # a wrapped line can't be redrawn
  if [[ -t 1 ]]; then printf '\r\033[K  %s %s' "${SPIN[$(($1 % 4))]}" "$t"; fi
}
check_line() {  # text: finish the current line with a green check
  if [[ -t 1 ]]; then printf '\r\033[K'; fi
  printf '  %s %s\n' "$GREEN_CHECK" "$1"; logf OK "$1"
}
end_line() { if [[ -t 1 ]]; then printf '\n'; fi; }
stop_line() {  # text: finish the current line with a yellow "!" (a wait that failed or timed out)
  if [[ -t 1 ]]; then printf '\r\033[K'; fi
  printf '\033[1;33m  !\033[0m %s\n' "$1"; logf WARN "$1"
}
wait_until() {  # waiting-text done-text timeout-seconds poll-seconds command...
  # One live line ("| waiting-text: state 1m05s") until command succeeds, then "✓ done-text after 1m05s".
  # command runs every poll-seconds in this shell; it sets WAIT_STATE (shown on the line) and
  # returns 0 when done, 1 to keep waiting, 2 when it has failed. Returns 0 done, 1 timed out,
  # 2 failed (WAIT_STATE says why). Not a terminal: one line per change of state.
  local what=$1 done_text=$2 limit=$3 every=$4 start=$SECONDS tick=0 rc el last="-"
  shift 4
  WAIT_STATE=""
  while :; do
    el=$(elapsed $((SECONDS - start)))
    if (( tick % (every * 4) == 0 )); then
      rc=0; "$@" || rc=$?
      if [[ "$WAIT_STATE" != "$last" ]]; then
        logf INFO "$what: ${WAIT_STATE:-waiting} (after $el)"; last=$WAIT_STATE
        if [[ ! -t 1 && $rc -ne 0 ]]; then echo "  $what: ${WAIT_STATE:-waiting} $el"; fi
      fi
      if [[ $rc -eq 0 ]]; then check_line "$done_text after $el"; return 0; fi
      if [[ $rc -eq 2 ]]; then stop_line "$what: ${WAIT_STATE:-failed} after $el"; return 2; fi
      if (( SECONDS - start >= limit )); then stop_line "$what: still ${WAIT_STATE:-waiting} after $el; gave up"; return 1; fi
    fi
    spin_line "$tick" "$what: ${WAIT_STATE:-checking} $el"
    sleep 0.25; tick=$((tick + 1))
  done
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# --- Reaching the nodes: ssh through the EC2 Instance Connect Endpoint, or SSM port forwards ---
need_key() {
  require_tools ssh
  [[ -n "$SSH_KEY_FILE" ]] || die "Set SSH_KEY_FILE in $CONFIG to the private key for $KEY_NAME."
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH_KEY_FILE in $CONFIG points to $SSH_KEY_FILE, which doesn't exist."
  logf DEBUG "SSH key $SSH_KEY_FILE: $(ssh_key_info "$SSH_KEY_FILE")"
}
eice_opts() {  # sets EICE_OPTS: the ssh options that reach a node through the endpoint
  need_key
  EICE_OPTS=(-i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
             -o ProxyCommand="aws ec2-instance-connect open-tunnel --region $REGION --instance-id %h")
}
eice_ssh() {  # extra ssh options... -> ssh to a node through the endpoint (logged with its exit code)
  local rc=0 t0
  eice_opts
  logf INFO "ssh $(_quote_args "${EICE_OPTS[@]}" "$@")"
  t0=$(_clock)
  ssh "${EICE_OPTS[@]}" "$@" || rc=$?
  logf INFO "ssh exited $rc after $(_took "$t0")"
  return $rc
}
ssm_forward() {  # remote-host remote-port local-port  (runs in the background; output in the run log)
  # Errors also show on the console unless SSM_QUIET=true (link draws progress lines instead).
  local jump bg
  require_tools session-manager-plugin
  jump=$(instance_id jump); [[ -n "$jump" ]] || die "No jump host for $NAME_PREFIX (ACCESS_METHOD=ssm)."
  bg="$_LOG_TMP/ssm-localhost-$3.bg"
  if [[ "${SSM_QUIET:-}" == "true" ]]; then
    command aws ssm start-session --target "$jump" --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"$2\"],\"localPortNumber\":[\"$3\"]}" >"$bg" 2>&1 &
  else
    command aws ssm start-session --target "$jump" --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"$2\"],\"localPortNumber\":[\"$3\"]}" >>"$bg" 2> >(tee -a "$bg" >&2) &
  fi
  logf INFO "SSM port forward localhost:$3 -> $1:$2 through jump host $jump (pid $!)"
}
port_listening() {  # wait_until check: something listens on WAIT_PORT
  if port_open localhost "$WAIT_PORT"; then WAIT_STATE="open"; return 0; fi
  WAIT_STATE="connecting"; return 1
}
wait_port() {  # local-port [process-output-file]: wait until something listens on it
  WAIT_PORT=$1
  wait_until "Forward to localhost:$1" "Forward on localhost:$1 open" 30 1 port_listening && return 0
  if [[ -s "${2:-}" ]]; then warn "Forward output: $(tail -3 "$2" | tr '\n' ' ')"; fi
  die "Nothing listening on localhost:$1 after 30 seconds."
}

free_port() { local p=$1; while port_open localhost "$p"; do p=$((p + 1)); done; echo "$p"; }  # first free local port from $1
port_wait() { local i; for ((i = 0; i < $2; i++)); do port_open localhost "$1" && return 0; sleep 1; done; return 1; }  # port seconds

NODE_SSH_PORTS=()   # ssm: local port forwarded to each node's port 22
node_ssh() {  # [--quiet] index command: run command on node index+1 (IDS/IPS) as SSH_USER, never prompting
  # stdout is returned; the command, exit code, time, output (unless --quiet) and errors are logged.
  local quiet="" rc=0 outf errf t0 n
  if [[ "$1" == --quiet ]]; then quiet=1; shift; fi
  n=$1; shift
  outf=$(mktemp "$_LOG_TMP/ssh.XXXXXX"); errf="$outf.err"; t0=$(_clock)
  if [[ "$ACCESS_METHOD" == "eice" ]]; then
    if [[ -z "${EICE_OPTS+set}" ]]; then eice_opts; fi
    ssh "${EICE_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=30 "$SSH_USER@${IDS[$n]}" "$1" >"$outf" 2>"$errf" || rc=$?
  else
    need_key
    if [[ -z "${NODE_SSH_PORTS[$n]:-}" ]] || ! port_open localhost "${NODE_SSH_PORTS[$n]}"; then
      KILL_JOBS_ON_EXIT=true; SSM_QUIET=true
      NODE_SSH_PORTS[$n]=$(free_port $((12222 + n)))
      ssm_forward "${IPS[$n]}" 22 "${NODE_SSH_PORTS[$n]}"; port_wait "${NODE_SSH_PORTS[$n]}" 30 || true
    fi
    ssh -i "$SSH_KEY_FILE" -p "${NODE_SSH_PORTS[$n]}" -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$SSH_USER@localhost" "$1" >"$outf" 2>"$errf" || rc=$?
  fi
  logf DEBUG "ssh node $((n + 1)) (${IDS[$n]}): ${1//$'\n'/; }  -> exit $rc in $(_took "$t0")"
  if [[ -z "$quiet" ]]; then log_file out "$outf"; else logf DEBUG "  (output not logged: $(wc -c <"$outf" | tr -d ' ') bytes)"; fi
  log_file err "$errf"
  cat "$outf"; rm -f "$outf" "$errf"
  return $rc
}

# --- The data drive: the EBS volume attached as /dev/sdb, under the name the node's OS gives it -----
# Nitro instance types (m5 and most current ones) present EBS volumes as NVMe devices: the root is
# normally /dev/nvme0n1 and the data volume /dev/nvme1n1, but AWS doesn't guarantee that order, so
# data_drive_script finds the volume on the node by its ID. Xen types present it as /dev/xvdb.
# The cluster profile's Storage Pool Drive must name it.
expected_data_drive() {  # nvme-support -> the device name the data volume normally gets
  case "$1" in required|supported) echo /dev/nvme1n1 ;; *) echo /dev/xvdb ;; esac
}
data_drive_script() {  # volume-id -> a script for a node that prints "<device> <bytes> <volume-group or ->"
  local v=${1//-/}   # an EBS volume's NVMe serial is its ID without the dash
  cat <<EOF
v=$v; dev=""
if [ -e /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_\$v ]; then dev=\$(readlink -f /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_\$v); fi
if [ -z "\$dev" ]; then for s in /sys/block/nvme*n1; do
  if [ "\$(tr -d ' ' < \$s/device/serial 2>/dev/null)" = "\$v" ]; then dev=/dev/\${s##*/}; break; fi
done; fi
if [ -z "\$dev" ]; then for c in /dev/xvdb /dev/sdb; do if [ -b \$c ]; then dev=\$c; break; fi; done; fi
if [ -z "\$dev" ]; then echo none; exit 0; fi
echo "\$dev \$(lsblk -dnbo SIZE \$dev 2>/dev/null || echo 0) \$(sudo pvs --noheadings -o vg_name \$dev 2>/dev/null | tr -d ' ' | grep . || echo -)"
EOF
}
save_output() {  # key value: set key=value in this deployment's outputs file
  local tmp
  tmp=$(mktemp "$_LOG_TMP/out.XXXXXX")
  { if [[ -f "$OUTPUT_FILE" ]]; then grep -v "^$1=" "$OUTPUT_FILE" || true; fi; echo "$1=$2"; } >"$tmp"
  cat "$tmp" >"$OUTPUT_FILE"; rm -f "$tmp"
  logf INFO "$OUTPUT_FILE: $1=$2"
}
