# How you reach the nodes, as ../deploy.sh:
#   eice: an EC2 Instance Connect Endpoint in the subnet (no instance, no IAM role, no hourly charge)
#   ssm:  the ssm, ssmmessages and ec2messages interface endpoints, an IAM role, and a small Amazon
#         Linux jump host with no inbound ports

# --- eice ---------------------------------------------------------------------------------------

resource "aws_ec2_instance_connect_endpoint" "eice" {
  count     = var.access_method == "eice" ? 1 : 0
  subnet_id = aws_subnet.private.id
  # Client IP not preserved: the node sees the endpoint's address, which the app group's
  # "all ports from access" rule matches.
  security_group_ids = [aws_security_group.access.id]
  preserve_client_ip = false
  tags               = { Name = "${var.name_prefix}-eice" }
}

# --- ssm ----------------------------------------------------------------------------------------

resource "aws_vpc_endpoint" "ssm" {
  for_each            = var.access_method == "ssm" ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_iam_role" "jump" {
  count = var.access_method == "ssm" ? 1 : 0
  name  = "${var.name_prefix}-jump"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "jump_ssm" {
  count      = var.access_method == "ssm" ? 1 : 0
  role       = aws_iam_role.jump[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jump" {
  count = var.access_method == "ssm" ? 1 : 0
  name  = "${var.name_prefix}-jump"
  role  = aws_iam_role.jump[0].name
}

data "aws_ssm_parameter" "al2023" {
  count = var.access_method == "ssm" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "jump" {
  count                  = var.access_method == "ssm" ? 1 : 0
  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.jump_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.access.id]
  iam_instance_profile   = aws_iam_instance_profile.jump[0].name
  tags                   = { Name = "${var.name_prefix}-jump" }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # A newer Amazon Linux image doesn't replace a running jump host.
  lifecycle {
    ignore_changes = [ami]
  }

  # It registers with Session Manager through the endpoints.
  depends_on = [aws_vpc_endpoint.ssm, aws_iam_role_policy_attachment.jump_ssm]
}
