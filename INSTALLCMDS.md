# VerteX appliance on AWS, private subnets only: commands

The commands from [INSTALL.md](INSTALL.md), in order, with their options; section numbers
match INSTALL.md's steps. Run them from this directory. Every script also takes `-c <file>` to use a config other than `config.env`.

## 1. Configure

```bash
cp config.env.example config.env
cp user-data.yaml.example user-data.yaml    # set the Local UI password and your SSH public key
ssh-keygen -y -f <key>.pem                  # prints the public key for ssh_authorized_keys (one line)
```

Settings in `config.env`:

```bash
# REQUIRED
REGION="us-gov-west-1"
NAME_PREFIX="vxp"                    # unique per deployment; up to 20 letters, digits, dashes
AMI_ID="<appliance-ami-id>"
KEY_NAME="<key-pair-name>"           # EC2 key pair; installed for kairos
SSH_KEY_FILE="<path-to-key.pem>"     # KEY_NAME's private key
NLB_PRIVATE_IP="10.0.11.210"         # the VIP: a free IP in PRIVATE_CIDR

# OPTIONAL: nodes
APP_COUNT="3"                        # 3 | 1
INSTANCE_TYPE="m5.2xlarge"
ROOT_VOLUME_SIZE_GB="300"            # at least 300
DATA_VOLUME_SIZE_GB="500"
USER_DATA_FILE="user-data.yaml"

# OPTIONAL: network
AZ=""                                # empty = first zone that offers INSTANCE_TYPE
VPC_CIDR="10.0.0.0/16"
PRIVATE_CIDR="10.0.11.0/24"

# OPTIONAL: access
ACCESS_METHOD="eice"                 # eice | ssm
JUMP_INSTANCE_TYPE="t3.micro"        # ssm only
SSH_USER="kairos"
LOCALUI_USER=""                      # empty = the first user in user-data.yaml

# OPTIONAL: logs
LOG_DIR="logs"
```

## 2. Network

```bash
./create-aws-infra.sh             # options: -c <file>
```

## 3-5. Security groups, access path, nodes (no NLB yet)

```bash
./deploy.sh --preflight-only      # checks settings, tools and credentials; creates nothing
./deploy.sh --no-nlb              # security groups, EICE or SSM access, nodes; not the NLB
                                  # options: -c <file>  --preflight-only  --no-nlb  -h
```

By hand, EICE endpoint:

```bash
aws ec2 create-instance-connect-endpoint --subnet-id <private-subnet-id> \
  --security-group-ids <access-sg-id> --no-preserve-client-ip
```

## 6. Wait for Local UI (25-30 minutes), then forward it

```bash
./connect.sh nodes                # node number, instance ID and private IP
./connect.sh localui              # node 1 https://localhost:5080
                                  # node 2 https://127.0.0.1:5081
                                  # node 3 https://[::1]:5082   (Ctrl-C to stop)
```

By hand, SSH through EICE, and an SSM port forward:

```bash
ssh -i <key>.pem -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id %h" kairos@<node-instance-id>

aws ssm start-session --target <jump-host-id> --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<node-ip>"],"portNumber":["5080"],"localPortNumber":["5080"]}'
```

## 7-8. Link the nodes, create the cluster, then the NLB

Link nodes 2 and 3 to node 1, in Local UI or through its API:

```bash
./connect.sh link                 # signs in with the user and password in user-data.yaml
                                  # (LOCALUI_USER, LOCALUI_PASSWORD override; asks if hashed)
                                  # waits until node 1 shows every node Ready, Synced, Healthy
                                  # then prints each node's data drive (Storage Pool Drive)
                                  # safe to re-run; needs curl and jq
./connect.sh disks                # just the data drive check: Storage Pool Drive for the profile
```

In Local UI, create the cluster with VIP = `NLB_PRIVATE_IP`, your Ubuntu Pro token, and Storage
Pool Drive = the data drive printed above (`/dev/nvme1n1` on m5), and click **Deploy Cluster**.
Within a minute:

```bash
./deploy.sh                       # creates the NLB on the VIP, target groups and listeners
./status.sh --watch               # live: NLB state and each port's health with elapsed time,
                                  # until all are healthy (6443, then 30003, then 443); also
                                  # watches the install on node 1 and repairs the storage and
                                  # MongoDB key failures (Troubleshooting) if they occur
                                  # options: -c <file>  --watch (without it: a snapshot)
                                  #          --no-repair (with --watch: report, don't change)
./connect.sh ssh 1                # options: ssh [N], N = node number (default 1)
sudo journalctl -u stylus-agent -f    # on the node: follow the install
```

By hand, the NLB:

```bash
aws elbv2 create-load-balancer --name <prefix>-nlb --type network --scheme internal \
  --subnet-mappings SubnetId=<private-subnet-id>,PrivateIPv4Address=10.0.11.210 \
  --security-groups <nlb-sg-id>

for port in 443 6443 30003 5080; do
  tg=$(aws elbv2 create-target-group --name <prefix>-tg-$port --protocol TCP --port $port \
         --vpc-id <vpc-id> --target-type instance --health-check-protocol TCP \
         --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 modify-target-group-attributes --target-group-arn "$tg" \
    --attributes Key=preserve_client_ip.enabled,Value=false
  aws elbv2 register-targets --target-group-arn "$tg" \
    --targets Id=<node-1-instance-id> Id=<node-2-instance-id> Id=<node-3-instance-id>
  aws elbv2 create-listener --load-balancer-arn <nlb-arn> --protocol TCP --port $port \
    --default-actions Type=forward,TargetGroupArn=$tg
done
```

## 9. Validate

```bash
./status.sh                       # snapshot: all four target groups healthy on every node
./connect.sh ssh 1                # then, on node 1:
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes      # three Ready control-plane nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A    # all Running or Completed
curl -sk https://10.0.11.210:6443/healthz                           # ok (or 401/403)
curl -m 5 https://example.com                                       # must fail: no egress
```

The VerteX console from your workstation:

```bash
./connect.sh console              # VIP 443 -> https://localhost:8443 (/system: system console)
                                  # options: console [port]   (Ctrl-C to stop)
```

kubectl from your workstation:

```bash
./connect.sh kubeconfig           # writes kubeconfig-<NAME_PREFIX>; options: kubeconfig [file]
./connect.sh api                  # in another terminal: VIP 6443 -> localhost:6443 (Ctrl-C to stop)
kubectl --kubeconfig kubeconfig-<NAME_PREFIX> get nodes
```

By hand, point a copied `admin.conf` at the forward:

```bash
kubectl --kubeconfig <file> config set-cluster kubernetes \
  --server=https://localhost:6443 --tls-server-name=kubernetes
```

## 10. Configure the system console and a tenant

```bash
cp system.env.example system.env && chmod 600 system.env    # fill in; only the admin block is required
./configure.sh --dry-run          # check settings and sign in; change nothing
./configure.sh                    # options: -c <file>  -s <system.env>  --url https://<host>  --dry-run
```

With `TENANT_ADMIN_PASSWORD` set, it activates the tenant (sets the admin's password through
the activation link). Without it, it prints the activation link to open (through
`./connect.sh console`: `https://localhost:8443/auth/password/.../activate`).

## Troubleshooting

Every run writes a log in `logs/` (passwords and tokens masked). The newest, and following
one live:

```bash
ls -t logs/ | head -5
tail -f "$(ls -t logs/*.log | head -1)"
```

Node status check stays "impaired" after its reset:

```bash
aws ec2 reboot-instances --instance-ids <node-instance-id>
```

`zot-pvc` Pending and no `linstor-*` storage classes, with `invalid ownership metadata` for
`custom-loader-image` in the `stylus-operator` log (`./status.sh --watch` repairs this):

```bash
kubectl get packs -A | grep piraeus          # the namespace is cluster-<id>
kubectl label linstorsatelliteconfiguration custom-loader-image app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate linstorsatelliteconfiguration custom-loader-image --overwrite \
  meta.helm.sh/release-name=piraeusoperator-piraeus-cluster meta.helm.sh/release-namespace=piraeus-system
kubectl -n cluster-<id> delete pack piraeus-operator
./connect.sh ssh 1                           # then on node 1:
sudo systemctl restart stylus-operator
```

`mongo-0` stuck in `Init:0/1` with "mongo.key is empty" (`./status.sh --watch` repairs this):

```bash
kubectl -n hubble-system patch secret spectro-mongodb-replicaset-key --type merge \
  -p "{\"stringData\":{\"mongo.key\":\"$(openssl rand -base64 756 | tr -d '\n')\"}}"
```

"VIP address is already assigned to a device on the network": remove the NLB, wait about a
minute, create the cluster, then run `./deploy.sh`:

```bash
./teardown.sh --nlb-only
```

## Teardown

```bash
./teardown.sh                     # everything, after you type NAME_PREFIX to confirm
./teardown.sh --nlb-only          # just the NLB and its listeners
                                  # options: -c <file>  --nlb-only
```
