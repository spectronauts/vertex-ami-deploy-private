# VerteX appliance on AWS with Terraform

An alternative to `../create-aws-infra.sh`, `../deploy.sh` and `../teardown.sh`: the same AWS
resources, with the same names and tags, built and removed with Terraform. Because the names
and tags match, the helper scripts work on what Terraform builds: `../connect.sh` (Local UI,
linking, ssh, the console), `../status.sh` and `../configure.sh`.

| Script | Terraform |
| --- | --- |
| `./create-aws-infra.sh` | `network.tf`: VPC, one private subnet, a route table with no default route |
| `./deploy.sh --no-nlb` | `security.tf`, `access.tf`, `nodes.tf`: security groups, the EC2 Instance Connect Endpoint (or SSM endpoints, IAM role and jump host), the nodes |
| `./deploy.sh` (after Deploy Cluster) | `nlb.tf` with `create_nlb = true`: the internal NLB on the VIP, target groups and listeners |
| `./teardown.sh` | `terraform destroy` |

Use one or the other for a deployment: don't run `../deploy.sh` or `../teardown.sh` on a
`name_prefix` that Terraform manages.

## Before you start

- Terraform 1.5 or later.
- AWS credentials for the region (Terraform uses the same ones as the AWS CLI).
- For the steps after Terraform, the tools in `../INSTALL.md` "Before you start".
- `../user-data.yaml`: copy `../user-data.yaml.example`, then set the password and your SSH
  public key (`../INSTALL.md` Step 5).

## Flow

1. Settings:

   ```
   cd terraform
   cp terraform.tfvars.example terraform.tfvars    # set the values under REQUIRED
   ```

2. Everything except the NLB (leave `create_nlb = false`):

   ```
   terraform init
   terraform apply
   ```

   It prints the node IPs, the VIP, the Storage Pool Drive and the next steps
   (`terraform output next_steps` shows them again).

3. Settings for the helper scripts, once:

   ```
   terraform output -raw config_env > ../config.env
   ```

4. From the repository folder: wait for Local UI, link the nodes, create the cluster.

   ```
   cd ..
   ./connect.sh wait          # one line per node until every Local UI answers (25-30 minutes)
   ./connect.sh link          # link nodes 2 and 3 to node 1; confirms the Storage Pool Drive
   ./connect.sh localui       # Local UI on node 1: https://localhost:5080
   ```

   In Local UI, create the cluster with the VIP (`nlb_private_ip`), your Ubuntu Pro token and
   the Storage Pool Drive, and click **Deploy Cluster** (`../INSTALL.md` Step 8).

5. Right after Deploy Cluster, the NLB: set `create_nlb = true` in `terraform.tfvars`, then

   ```
   cd terraform
   terraform apply
   ```

   The NLB has to wait until now: Local UI refuses a VIP that any device already owns, and an
   NLB's IP belongs to its network interface.

6. From the repository folder:

   ```
   cd ..
   ./status.sh --watch        # until 6443, 30003 and 443 are healthy (usually 20-30 minutes)
   ./connect.sh console       # VerteX at https://localhost:8443/system
   ./configure.sh             # system console settings and a tenant, from system.env
   ```

## Teardown

```
cd terraform
terraform destroy
```

It deletes everything this configuration created, the nodes' volumes included. To remove just
the NLB, set `create_nlb = false` and apply.

## Notes

- **Checks:** the variables carry the same checks as `../config.env` (names, CIDRs, a root
  volume of at least 300 GB). Before creating anything, Terraform also checks that the AMI and
  the key pair exist, that the VIP is an address AWS lets you assign in the subnet, and that the
  user data starts with `#cloud-config` and has your SSH key.
- **Changing nodes later:** a node is never replaced or restarted because `ami_id` or the user
  data changed; both only matter at first boot. Changing the instance type stops and starts the
  nodes; don't do that to a running cluster.
- **State:** `terraform.tfstate` is kept in this folder unless you add a backend
  (`versions.tf` has an S3 example). It holds the deployment's resource IDs and the nodes' user
  data, which includes your Local UI password, so keep it private (an encrypted S3 bucket with
  restricted access, for a shared deployment). Plans show the user data as
  `(sensitive value)`. Keep the state, too: without it, Terraform can't update or remove what it
  built.
