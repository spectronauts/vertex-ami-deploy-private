# One VPC and one private subnet whose route table has no default route: no internet gateway,
# no NAT gateway. DNS support and DNS hostnames are on (the SSM endpoints' private DNS and Route 53
# private hosted zones need them). As ../create-aws-infra.sh.

data "aws_partition" "current" {}

# The first zone, in name order, that offers the node type (and the jump host type for ssm).
data "aws_ec2_instance_type_offerings" "node" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ec2_instance_type_offerings" "jump" {
  count         = var.access_method == "ssm" ? 1 : 0
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.jump_instance_type]
  }
}

locals {
  candidate_zones = sort(var.access_method == "ssm"
    ? tolist(setintersection(data.aws_ec2_instance_type_offerings.node.locations, data.aws_ec2_instance_type_offerings.jump[0].locations))
  : data.aws_ec2_instance_type_offerings.node.locations)
  az = var.az != "" ? var.az : try(local.candidate_zones[0], "")

  # The VIP must be an address AWS lets you assign in the subnet: inside it, and not the first
  # four or the last.
  private_prefix = tonumber(split("/", var.private_cidr)[1])
  vip_in_subnet  = cidrsubnet("${var.nlb_private_ip}/${local.private_prefix}", 0, 0) == cidrsubnet(var.private_cidr, 0, 0)
  vip_reserved   = contains(concat([for i in range(4) : cidrhost(var.private_cidr, i)], [cidrhost(var.private_cidr, -1)]), var.nlb_private_ip)
  subnet_in_vpc = (local.private_prefix >= tonumber(split("/", var.vpc_cidr)[1])
  && cidrsubnet("${cidrhost(var.private_cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0, 0) == cidrsubnet(var.vpc_cidr, 0, 0))
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-private" }

  lifecycle {
    precondition {
      condition     = local.az != ""
      error_message = "No zone in ${var.region} offers ${var.instance_type}${var.access_method == "ssm" ? " and ${var.jump_instance_type}" : ""}."
    }
    precondition {
      condition     = local.subnet_in_vpc
      error_message = "private_cidr ${var.private_cidr} is not inside vpc_cidr ${var.vpc_cidr}."
    }
    precondition {
      condition     = local.vip_in_subnet && !local.vip_reserved
      error_message = "nlb_private_ip ${var.nlb_private_ip} is not an address AWS lets you assign in ${var.private_cidr} (inside it, not the first four or the last)."
    }
  }
}

# The route table has only the VPC's local route: nothing in this VPC reaches the internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-private-rtb" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
