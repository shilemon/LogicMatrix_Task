locals {
  name_prefix = "${var.cluster_name}-${var.environment}"
  common_tags = {
    Project     = "devops-assessment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Network: VPC with public subnets (ALB/NAT) and private subnets (EKS nodes,
# RDS). Worker nodes and the database live only in private subnets - they
# have no route to/from the public internet except outbound via NAT.
# ---------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  tags        = local.common_tags
}

# ---------------------------------------------------------------------------
# Container registry for backend + frontend images
# ---------------------------------------------------------------------------
module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  tags        = local.common_tags
}

# ---------------------------------------------------------------------------
# EKS cluster + managed node group, deployed into the private subnets.
# Also wires up CloudWatch Container Insights for monitoring/logging.
# ---------------------------------------------------------------------------
module "eks" {
  source = "./modules/eks"

  cluster_name        = var.cluster_name
  kubernetes_version   = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  node_instance_type  = var.node_instance_type
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# Private RDS database - no public IP, deployed only in private subnets,
# reachable only from the EKS node/pod security group.
# ---------------------------------------------------------------------------
module "rds" {
  source = "./modules/rds"

  name_prefix           = local.name_prefix
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  db_instance_class     = var.db_instance_class
  db_name               = var.db_name
  db_username           = var.db_username
  allowed_security_group_id = module.eks.node_security_group_id
  tags                  = local.common_tags
}
