# The appliance nodes, as ../deploy.sh: the appliance AMI, a root volume of at least 300 GB, one
# data volume the AMI builds its storage pool on (attached as /dev/sdb; the node sees it as
# /dev/nvme1n1 on Nitro types), and your user data.

data "aws_ami" "appliance" {
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

data "aws_key_pair" "nodes" {
  key_name = var.key_name
}

data "aws_ec2_instance_type" "node" {
  instance_type = var.instance_type
}

locals {
  # Sensitive: it holds the Local UI password, so plans and logs show "(sensitive value)".
  user_data = sensitive(file(var.user_data_file))
  # What Local UI's Storage Pool Drive must name: the data volume as the node's OS sees it.
  data_drive = contains(["required", "supported"], data.aws_ec2_instance_type.node.ebs_nvme_support) ? "/dev/nvme1n1" : "/dev/xvdb"
}

resource "aws_instance" "node" {
  count                  = var.app_count
  ami                    = data.aws_ami.appliance.id
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.nodes.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = local.user_data

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_size           = var.data_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  volume_tags = {
    Name             = "${var.name_prefix}-node-${count.index + 1}"
    "vxp:deployment" = var.name_prefix
  }
  tags = { Name = "${var.name_prefix}-node-${count.index + 1}" }

  lifecycle {
    # A running cluster node is never replaced or restarted because the AMI or user data in this
    # configuration changed; both only matter at first boot.
    ignore_changes = [ami, user_data, user_data_base64]

    precondition {
      condition     = startswith(local.user_data, "#cloud-config")
      error_message = "${var.user_data_file} must start with '#cloud-config'."
    }
    precondition {
      condition     = !strcontains(local.user_data, "ssh-rsa abc@spectrocloud.com")
      error_message = "Replace the placeholder SSH key in ${var.user_data_file} with your public key."
    }
  }
}
