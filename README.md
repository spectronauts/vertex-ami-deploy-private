# ami-deploy-private: the VerteX appliance with no public subnets

Deploys the appliance into networks that allow **no public subnets**: no internet gateway,
no NAT gateway, no public IPs, no route to the internet anywhere in the VPC. There is no
bastion; you reach the nodes through AWS's own services, picked per deployment with
`ACCESS_METHOD`. Everything learned from testing the airgap guide is built in: a 300 GB root volume (so kubelet doesn't garbage-collect the preloaded images),
node-to-node rules, client IP preservation off, and the NLB created on a fixed VIP after
Deploy Cluster.

## Access methods

| | `eice` (default) | `ssm` |
| --- | --- | --- |
| What gets built | One EC2 Instance Connect Endpoint in the subnet | ssm, ssmmessages and ec2messages interface endpoints, an IAM role, a t3.micro Amazon Linux jump host (no inbound ports) |
| Hourly cost | None | Three endpoints plus the jump host |
| How you get in | SSH (port 22) through the endpoint; Local UI and the API ride `ssh -L` through node 1 | `aws ssm start-session` port forwarding to any node port |
| Needs on your workstation | AWS CLI v2.12+, OpenSSH, your EC2 private key (`SSH_KEY_FILE`) | AWS CLI v2, `session-manager-plugin`; the key only for `ssh` |

`./connect.sh` hides the difference: the same commands work for both.

## Files

| File | What it does |
| --- | --- |
| `INSTALL.md` | The install guide: quick steps, then every step in full, with troubleshooting |
| `architecture.svg` | The architecture diagram shown in INSTALL.md |
| `architecture.excalidraw` | Its editable source; open at excalidraw.com or in the VS Code Excalidraw extension |
| `config.env.example` | Settings; copy to `config.env` |
| `user-data.yaml.example` | The airgap guide's user data (`fusion` user); copy to `user-data.yaml`, set password and key |
| `create-vpc.sh` | VPC and one private subnet; refuses any internet gateway or default route |
| `deploy.sh` | Security groups, the access path, the nodes, and (without `--no-nlb`) the NLB on the VIP |
| `connect.sh` | `localui`, `ssh [N]`, `api`, `kubeconfig`, `nodes` from your workstation |
| `status.sh` | Instances, access path, NLB and target health |
| `teardown.sh` | Deletes everything, VPC and IAM role included; `--nlb-only` deletes just the NLB |

## Run

Works from macOS or Linux, on x86_64 or arm64. Each script checks for the tools and AWS
credentials it needs first, and prints the install command for your platform if something is
missing (INSTALL.md, "Before you start").

```bash
cp config.env.example config.env               # AMI_ID, KEY_NAME, SSH_KEY_FILE, ACCESS_METHOD
cp user-data.yaml.example user-data.yaml       # set the password and your SSH public key
./create-vpc.sh
./deploy.sh --no-nlb                           # everything except the NLB
./connect.sh localui                           # after ~25-30 min: https://localhost:5080, :5081, :5082
```

Then in Local UI (node 1 at `https://localhost:5080`): sign in with the user-data user,
generate a link token, and link the other nodes at `https://127.0.0.1:5081` and
`https://[::1]:5082` (different host names keep each node's login separate). Create the
cluster with **VIP = `NLB_PRIVATE_IP`** and click **Deploy Cluster**. Right after:

```bash
./deploy.sh                                    # creates the NLB on the VIP
./status.sh                                    # 6443, 30003, 443 turn healthy as the cluster comes up
```

The NLB must not exist when you enter the VIP: Local UI refuses an IP that any device
already owns, and an NLB's IP belongs to its network interface.

## Known issues

See the install guide's Troubleshooting table. The ones most likely here: a node that hangs
on its first active boot (EC2 status "impaired"; reboot it), and `mongo-0` stuck in `Init`
with "mongo.key is empty" (set the key by hand).
