# Security groups that reference each other by ID, as ../deploy.sh: access, app (the nodes), nlb,
# and for ssm the endpoints group. Terraform removes AWS's default allow-all egress from each group;
# every outbound rule is spelled out below.

resource "aws_security_group" "access" {
  name        = "${var.name_prefix}-access-sg"
  description = var.access_method == "eice" ? "EC2 Instance Connect Endpoint: all ports to app and NLB" : "SSM jump host: all ports to app and NLB; 443 to the SSM endpoints"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-access-sg" }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Appliance nodes: all from access; app ports from NLB; node to node"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-app-sg" }
}

resource "aws_security_group" "nlb" {
  name        = "${var.name_prefix}-nlb-sg"
  description = "Internal NLB: all from access; app ports from app; app ports to app"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-nlb-sg" }
}

resource "aws_security_group" "endpoints" {
  count       = var.access_method == "ssm" ? 1 : 0
  name        = "${var.name_prefix}-endpoints-sg"
  description = "SSM interface endpoints: 443 from the jump host"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-endpoints-sg" }
}

locals {
  sg = {
    access    = aws_security_group.access.id
    app       = aws_security_group.app.id
    nlb       = aws_security_group.nlb.id
    endpoints = var.access_method == "ssm" ? aws_security_group.endpoints[0].id : ""
  }

  # Each rule: the group it belongs to, the peer group, protocol ("-1" = all) and port.
  ingress_rules = merge(
    {
      app_from_access = { sg = "app", peer = "access", proto = "-1", port = null, desc = "all ports from access" }
      nlb_from_access = { sg = "nlb", peer = "access", proto = "-1", port = null, desc = "all ports from access" }
    },
    { for p in var.app_ports : "app_from_nlb_${p}" => { sg = "app", peer = "nlb", proto = "tcp", port = p, desc = "from NLB" } },
    { for p in var.app_ports : "nlb_from_app_${p}" => { sg = "nlb", peer = "app", proto = "tcp", port = p, desc = "from app" } },
    var.node_to_node ? { app_from_app = { sg = "app", peer = "app", proto = "-1", port = null, desc = "node to node" } } : {},
    var.access_method == "ssm" ? { endpoints_from_access = { sg = "endpoints", peer = "access", proto = "tcp", port = 443, desc = "from jump host" } } : {},
  )
  egress_rules = merge(
    {
      access_to_app = { sg = "access", peer = "app", proto = "-1", port = null, desc = "all ports to app" }
      access_to_nlb = { sg = "access", peer = "nlb", proto = "-1", port = null, desc = "all ports to NLB" }
    },
    { for p in var.app_ports : "app_to_nlb_${p}" => { sg = "app", peer = "nlb", proto = "tcp", port = p, desc = "to NLB" } },
    { for p in var.app_ports : "nlb_to_app_${p}" => { sg = "nlb", peer = "app", proto = "tcp", port = p, desc = "to app" } },
    var.node_to_node ? { app_to_app = { sg = "app", peer = "app", proto = "-1", port = null, desc = "node to node" } } : {},
    var.access_method == "ssm" ? { access_to_endpoints = { sg = "access", peer = "endpoints", proto = "tcp", port = 443, desc = "to SSM endpoints" } } : {},
  )
}

resource "aws_vpc_security_group_ingress_rule" "rule" {
  for_each                     = local.ingress_rules
  security_group_id            = local.sg[each.value.sg]
  referenced_security_group_id = local.sg[each.value.peer]
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.desc
}

resource "aws_vpc_security_group_egress_rule" "rule" {
  for_each                     = local.egress_rules
  security_group_id            = local.sg[each.value.sg]
  referenced_security_group_id = local.sg[each.value.peer]
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.desc
}
