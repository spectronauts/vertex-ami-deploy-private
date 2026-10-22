# The same settings as ../config.env.example, with the same checks. Set them in terraform.tfvars
# (copy terraform.tfvars.example).

# --- Required -----------------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy in."
  type        = string
  default     = "us-gov-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov|-iso[a-z]*)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name, for example us-gov-west-1."
  }
}

variable "name_prefix" {
  description = "Prefix for every resource's name and tag; unique per deployment."
  type        = string
  default     = "vxp"

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,18}[A-Za-z0-9])?$", var.name_prefix))
    error_message = "name_prefix: up to 20 letters, digits and dashes, not starting or ending with a dash."
  }
}

variable "ami_id" {
  description = "The VerteX appliance AMI in the region."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI ID, for example ami-0123456789abcdef0."
  }
}

variable "key_name" {
  description = "EC2 key pair; the AMI installs it for the kairos user."
  type        = string
}

variable "ssh_key_file" {
  description = "key_name's private key (.pem). Not used by Terraform; written into the config_env output for ../connect.sh."
  type        = string
  default     = ""
}

variable "nlb_private_ip" {
  description = "The cluster VIP: a free address in private_cidr. Enter it in Local UI before the NLB exists."
  type        = string
  default     = "10.0.11.210"

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.nlb_private_ip))
    error_message = "nlb_private_ip must be an IPv4 address."
  }
}

variable "create_nlb" {
  description = "Create the internal NLB on nlb_private_ip. Leave false until you have clicked Deploy Cluster in Local UI (it refuses a VIP that a device owns), then set true and apply again."
  type        = bool
  default     = false
}

# --- Optional: nodes ----------------------------------------------------------------------------

variable "app_count" {
  description = "Number of nodes: 3 for a cluster, 1 for a single node."
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.app_count)
    error_message = "app_count: 3 for a cluster, or 1."
  }
}

variable "instance_type" {
  description = "Node instance type."
  type        = string
  default     = "m5.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root volume in GB; at least 300 (below that kubelet can delete preloaded images during install)."
  type        = number
  default     = 300

  validation {
    condition     = var.root_volume_size_gb >= 300
    error_message = "root_volume_size_gb must be at least 300 (INSTALL.md Step 5)."
  }
}

variable "data_volume_size_gb" {
  description = "Data volume in GB; the AMI builds its storage pool on it."
  type        = number
  default     = 500

  validation {
    condition     = var.data_volume_size_gb >= 1 && var.data_volume_size_gb <= 16384
    error_message = "data_volume_size_gb: 1 to 16384."
  }
}

variable "user_data_file" {
  description = "Node user data (copy ../user-data.yaml.example; set the password and your SSH public key). Relative to this folder."
  type        = string
  default     = "../user-data.yaml"
}

# --- Optional: network --------------------------------------------------------------------------

variable "az" {
  description = "Availability zone; empty picks the first zone that offers instance_type (and the jump host's type for ssm)."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC address range."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 28
    error_message = "vpc_cidr: a network with a /16 to /28 prefix, for example 10.0.0.0/16."
  }
}

variable "private_cidr" {
  description = "The only subnet: nodes, NLB and access endpoint."
  type        = string
  default     = "10.0.11.0/24"

  validation {
    condition     = can(cidrhost(var.private_cidr, 0)) && tonumber(split("/", var.private_cidr)[1]) >= 16 && tonumber(split("/", var.private_cidr)[1]) <= 28
    error_message = "private_cidr: a network with a /16 to /28 prefix, for example 10.0.11.0/24."
  }
}

# --- Optional: access ---------------------------------------------------------------------------

variable "access_method" {
  description = "eice: EC2 Instance Connect Endpoint (no hourly cost). ssm: jump host and SSM endpoints (billed hourly; needs session-manager-plugin on your workstation)."
  type        = string
  default     = "eice"

  validation {
    condition     = contains(["eice", "ssm"], var.access_method)
    error_message = "access_method: eice or ssm."
  }
}

variable "jump_instance_type" {
  description = "Jump host instance type (access_method = ssm only)."
  type        = string
  default     = "t3.micro"
}

# --- Fixed by the design; change only if you know why -------------------------------------------

variable "app_ports" {
  description = "Ports the NLB forwards to the nodes: 443 (VerteX), 6443 (Kubernetes API), 30003 (registry), 5080 (Local UI)."
  type        = list(number)
  default     = [443, 6443, 30003, 5080]
}

variable "preserve_client_ip" {
  description = "Client IP preservation on the target groups; off, so a node can reach its own API through the VIP."
  type        = bool
  default     = false
}

variable "node_to_node" {
  description = "Allow all traffic between nodes (linking, etcd, kubelet, CNI, DRBD)."
  type        = bool
  default     = true
}
