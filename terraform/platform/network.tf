module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 48)]

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_security_group      = var.enable_interface_vpc_endpoints
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "HTTPS from the Iris MLOps VPC to AWS PrivateLink endpoints"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC workloads"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${local.name}-s3" }
      }
    },
    var.enable_interface_vpc_endpoints ? {
      ecr_api = {
        service             = "ecr.api"
        private_dns_enabled = true
      }
      ecr_dkr = {
        service             = "ecr.dkr"
        private_dns_enabled = true
      }
      ec2 = {
        service             = "ec2"
        private_dns_enabled = true
      }
      eks = {
        service             = "eks"
        private_dns_enabled = true
      }
      eks_auth = {
        service             = "eks-auth"
        private_dns_enabled = true
      }
      elasticloadbalancing = {
        service             = "elasticloadbalancing"
        private_dns_enabled = true
      }
      autoscaling = {
        service             = "autoscaling"
        private_dns_enabled = true
      }
      logs = {
        service             = "logs"
        private_dns_enabled = true
      }
      sts = {
        service             = "sts"
        private_dns_enabled = true
      }
      secretsmanager = {
        service             = "secretsmanager"
        private_dns_enabled = true
      }
      sqs = {
        service             = "sqs"
        private_dns_enabled = true
      }
    } : {}
  )
}
