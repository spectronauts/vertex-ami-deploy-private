# The internal NLB on the VIP (nlb_private_ip), as ../deploy.sh: one TCP listener and target group
# per app port, the nodes as targets, client IP preservation off.
#
# Created only when create_nlb = true. Local UI refuses a VIP that any device already owns, and an
# NLB's IP belongs to its network interface: so apply with create_nlb = false, enter the VIP in
# Local UI and click Deploy Cluster, then set create_nlb = true and apply again.

locals {
  nlb_ports = var.create_nlb ? { for p in var.app_ports : tostring(p) => p } : {}
  # One attachment per port and node.
  nlb_targets = {
    for pair in setproduct(keys(local.nlb_ports), range(var.app_count)) :
    "${pair[0]}-node-${pair[1] + 1}" => { port = pair[0], node = pair[1] }
  }
}

resource "aws_lb" "nlb" {
  count              = var.create_nlb ? 1 : 0
  name               = "${var.name_prefix}-nlb"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  tags               = { Name = "${var.name_prefix}-nlb" }

  subnet_mapping {
    subnet_id            = aws_subnet.private.id
    private_ipv4_address = var.nlb_private_ip
  }
}

resource "aws_lb_target_group" "port" {
  for_each    = local.nlb_ports
  name        = "${var.name_prefix}-tg-${each.key}"
  port        = each.value
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  # Off: with it on, a node can't reach itself through the VIP.
  preserve_client_ip = tostring(var.preserve_client_ip)

  health_check {
    protocol = "TCP"
  }
}

resource "aws_lb_target_group_attachment" "node" {
  for_each         = local.nlb_targets
  target_group_arn = aws_lb_target_group.port[each.value.port].arn
  target_id        = aws_instance.node[each.value.node].id
  port             = local.nlb_ports[each.value.port]
}

resource "aws_lb_listener" "port" {
  for_each          = local.nlb_ports
  load_balancer_arn = aws_lb.nlb[0].arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.port[each.key].arn
  }
}
