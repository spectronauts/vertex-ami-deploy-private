# VerteX appliance on AWS, private subnets only: commands

The commands from [INSTALL.md](INSTALL.md), in order, with their options. Run them from this
directory. Every script also takes `-c <file>` to use a config other than `config.env`.

## 0. Configure

```bash
cp config.env.example config.env
cp user-data.yaml.example user-data.yaml    # set the Local UI password and your SSH public key
```

Settings in `config.env`:

```bash
REGION="us-gov-west-1"            # required
AMI_ID="<appliance-ami-id>"       # required: the VerteX appliance AMI
KEY_NAME="<key-pair-name>"        # required: EC2 key pair for SSH to the nodes
SSH_KEY_FILE="<path-to-key.pem>"  # private key for KEY_NAME, used by connect.sh
ACCESS_METHOD="eice"              # eice | ssm
NLB_PRIVATE_IP="10.0.11.210"      # the VIP: a free IP in PRIVATE_CIDR
APP_COUNT=3                       # 1 | 3 nodes
ROOT_VOLUME_SIZE_GB=300           # at least 300
DATA_VOLUME_COUNT=1               # one 500 GB data volume
AZ=""                             # empty = first zone that offers the instance type
VPC_CIDR="10.0.0.0/16"
PRIVATE_CIDR="10.0.11.0/24"
NAME_PREFIX="vxp"                 # name and tag prefix for every resource
```

## 1. Network

```bash
./create-vpc.sh                   # options: -c <file>
```

## 2-4. Security groups, access path, nodes (no NLB yet)

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

## 5. Wait for Local UI (25-30 minutes), then forward it

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

Node status check stays "impaired" after its reset:

```bash
aws ec2 reboot-instances --instance-ids <node-instance-id>
```

## 6-7. Link the nodes, create the cluster, then the NLB

In Local UI, link nodes 2 and 3 to node 1, then create the cluster with VIP = `NLB_PRIVATE_IP`
and your Ubuntu Pro token, and click **Deploy Cluster**. Within a minute:

```bash
./deploy.sh                       # creates the NLB on the VIP, target groups and listeners
./status.sh                       # 6443, then 30003, then 443 turn healthy; options: -c <file>
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

## 8. Validate

```bash
./status.sh                       # all four target groups healthy on every node
./connect.sh ssh 1                # then, on node 1:
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes      # three Ready control-plane nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A    # all Running or Completed
curl -sk https://10.0.11.210:6443/healthz                           # ok (or 401/403)
curl -m 5 https://example.com                                       # must fail: no egress
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

## Troubleshooting

`mongo-0` stuck in `Init:0/1` with "mongo.key is empty":

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
