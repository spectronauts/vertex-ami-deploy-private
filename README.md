# Deploy the VerteX Appliance in an Airgapped environment

Deploys the appliance into networks that allow **no public subnets**: no internet gateway,
no NAT gateway, no public IPs, no route to the internet anywhere in the VPC. There is no
bastion; you reach the nodes through AWS's own services, picked per deployment with
`ACCESS_METHOD`. Everything learned from testing the airgap guide is built in: a 300 GB root
volume (so kubelet doesn't garbage-collect the preloaded images), node-to-node rules, client
IP preservation off, and the NLB created on a fixed VIP after Deploy Cluster.

## Access methods

| | `eice` (default) | `ssm` |
| --- | --- | --- |
| What gets built | One EC2 Instance Connect Endpoint in the subnet | ssm, ssmmessages and ec2messages interface endpoints, an IAM role, a t3.micro Amazon Linux jump host (no inbound ports) |
| Hourly cost | None | Three endpoints plus the jump host |
| How you get in | SSH (port 22) through the endpoint; Local UI and the API ride `ssh -L` through node 1 | `aws ssm start-session` port forwarding to any node port |
| Needs on your workstation | AWS CLI v2.12+, OpenSSH, your EC2 private key (`SSH_KEY_FILE`) | AWS CLI v2, `session-manager-plugin`; the key only for `ssh` |

`./connect.sh` hides the difference: the same commands work for both. `./connect.sh link` also
needs `curl` and `jq`.

## Files

| File | What it does |
| --- | --- |
| `INSTALL.md` | The install guide: quick steps, then every step in full, with troubleshooting |
| `INSTALLCMDS.md` | The guide's commands only, in order, with their options |
| `architecture.svg` | The architecture diagram shown in INSTALL.md |
| `architecture.excalidraw` | Its editable source; open at excalidraw.com or in the VS Code Excalidraw extension |
| `config.env.example` | Settings; copy to `config.env` |
| `user-data.yaml.example` | The airgap guide's user data (`fusion` user); copy to `user-data.yaml`, set password and key |
| `create-vpc.sh` | VPC and one private subnet; refuses any internet gateway or default route |
| `deploy.sh` | Security groups, the access path, the nodes, and (without `--no-nlb`) the NLB on the VIP |
| `connect.sh` | `localui`, `link`, `ssh [N]`, `api`, `kubeconfig`, `nodes` from your workstation |
| `status.sh` | Instances, access path, NLB and target health; `--watch` updates live until all are healthy |
| `teardown.sh` | Deletes everything, VPC and IAM role included; `--nlb-only` deletes just the NLB |
| `logs/` | One log per script run (see Logs) |

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
./connect.sh link                              # links nodes 2 and 3 to node 1, waits until all are ready
```

`./connect.sh link` signs in with the user and password from `user-data.yaml`. Then in Local
UI on node 1 (`https://localhost:5080`), create the cluster with **VIP = `NLB_PRIVATE_IP`** and
your Ubuntu Pro token, and click **Deploy Cluster**. Right after:

```bash
./deploy.sh                                    # creates the NLB on the VIP
./status.sh --watch                            # live until 6443, 30003, 443 are healthy on every node
```

The NLB must not exist when you enter the VIP: Local UI refuses an IP that any device
already owns, and an NLB's IP belongs to its network interface.

## Logs

Every run writes a log and prints its path first: `logs/<script>-<NAME_PREFIX>-<UTC time>.log`
(`connect.sh` adds the command, as in `logs/connect-link-vxp-20261016T150000Z.log`). The
console stays short; the log has the detail:

- the run: arguments, config file and settings, workstation, tool versions, AWS identity
- every AWS CLI call: its arguments, exit code, time taken, output, and any error, including
  errors the console doesn't show
- every Local UI API call `./connect.sh link` makes: method, path, HTTP status, time taken,
  request and response
- ssh and SSM forwards (with `ssh -v` output for `link`), kubectl steps, each check made
  while waiting, and the AWS resources before `./teardown.sh` deletes them
- where the run stopped and why, if it fails

Passwords, Local UI sign-in tokens, link tokens and AWS secret keys are written as
`<redacted>`, and only you can read the files. Set `LOG_DIR` in `config.env` to keep them
elsewhere. To follow a run from another terminal: `tail -f "$(ls -t logs/*.log | head -1)"`.

## Known issues

See the install guide's Troubleshooting table. The ones most likely here: a node that hangs
on its first active boot (EC2 status "impaired"; reboot it), and `mongo-0` stuck in `Init`
with "mongo.key is empty" (set the key by hand).
