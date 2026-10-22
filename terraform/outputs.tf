output "availability_zone" {
  value = local.az
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_id" {
  value = aws_subnet.private.id
}

output "node_ids" {
  description = "Node instance IDs, node 1 first."
  value       = aws_instance.node[*].id
}

output "node_private_ips" {
  description = "Node private IPs, node 1 first."
  value       = aws_instance.node[*].private_ip
}

output "vip" {
  description = "The VIP for Local UI's Cluster Config: the NLB's private IP."
  value       = var.nlb_private_ip
}

output "storage_pool_drive" {
  description = "The data drive as the nodes see it: Local UI's Storage Pool Drive (./connect.sh link confirms it on each node)."
  value       = local.data_drive
}

output "access" {
  description = "The access path."
  value       = var.access_method == "eice" ? "EC2 Instance Connect Endpoint ${aws_ec2_instance_connect_endpoint.eice[0].id}" : "SSM jump host ${aws_instance.jump[0].id}"
}

output "nlb_dns" {
  value = var.create_nlb ? aws_lb.nlb[0].dns_name : "(not created yet: set create_nlb = true after Deploy Cluster, then apply)"
}

# The same settings as config.env for the helper scripts (../connect.sh, ../status.sh,
# ../configure.sh), which find this deployment's resources by name and tag:
#   terraform output -raw config_env > ../config.env
output "config_env" {
  description = "A config.env for ../connect.sh, ../status.sh and ../configure.sh."
  value       = <<-EOT
    # Written from Terraform (terraform output -raw config_env); terraform.tfvars is the source.
    REGION="${var.region}"
    NAME_PREFIX="${var.name_prefix}"
    AMI_ID="${var.ami_id}"
    KEY_NAME="${var.key_name}"
    SSH_KEY_FILE="${var.ssh_key_file}"
    NLB_PRIVATE_IP="${var.nlb_private_ip}"
    APP_COUNT="${var.app_count}"
    INSTANCE_TYPE="${var.instance_type}"
    ROOT_VOLUME_SIZE_GB="${var.root_volume_size_gb}"
    DATA_VOLUME_SIZE_GB="${var.data_volume_size_gb}"
    USER_DATA_FILE="${abspath(var.user_data_file)}"
    AZ="${local.az}"
    VPC_CIDR="${var.vpc_cidr}"
    PRIVATE_CIDR="${var.private_cidr}"
    ACCESS_METHOD="${var.access_method}"
    JUMP_INSTANCE_TYPE="${var.jump_instance_type}"
  EOT
}

locals {
  # Each step: the command, then its description (continuation lines start with a newline).
  steps_before_nlb = compact([
    "./connect.sh wait       one line per node until every Local UI answers",
    var.app_count > 1 ? "./connect.sh link       link nodes 2-${var.app_count} to node 1; confirms the Storage Pool Drive" : "",
    join("\n", [
      "./connect.sh localui    in Local UI on node 1 (https://localhost:5080): Cluster > Create cluster",
      "                          Profile Config  OCI Pack Registry Password; Ubuntu Pro Token;",
      "                                          Storage Pool Drive ${local.data_drive}; Root Domain",
      "                          Cluster Config  VIP ${var.nlb_private_ip}",
      "                          Node Config     all ${var.app_count} node(s) in control-plane-pool",
      "                        and click Deploy Cluster",
    ]),
    "right after Deploy Cluster: set create_nlb = true in terraform.tfvars, then terraform apply",
  ])
  steps_after_nlb = [
    "./status.sh --watch     until 6443, then 30003, then 443 are healthy (usually 20-30 minutes)",
    join("\n", [
      "./connect.sh console    VerteX at https://localhost:8443/system",
      "./configure.sh          system console settings and a tenant, from system.env",
    ]),
  ]
  steps = var.create_nlb ? local.steps_after_nlb : local.steps_before_nlb
}

output "next_steps" {
  description = "What to do next."
  value = join("\n", concat(
    var.create_nlb ? [] : [
      "Local UI is up on the nodes about 25-30 minutes after launch.",
      "If you have no ../config.env yet: terraform output -raw config_env > ../config.env",
    ],
    ["Next steps, from the repository folder (cd ..):"],
    [for i, step in local.steps : "  ${i + 1}. ${replace(step, "\n", "\n     ")}"],
    var.create_nlb ? ["Teardown: terraform destroy (not ../teardown.sh, which would leave this state behind)."] : [],
  ))
}
