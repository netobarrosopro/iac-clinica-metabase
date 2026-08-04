module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0" # pin exato em prod

  name = local.name
  cidr = var.vpc_cidr_block

  azs = local.azs

  # Tasks Fargate rodam em subnets publicas com IP publico (protegidas por SG
  # que so aceita trafego do ALB). Isso elimina o NAT Gateway (~USD 45/mes em
  # sa-east-1), que seria o maior custo da stack — decisao consciente de
  # custo vs. postura de rede; veja tradeoffs no README.
  public_subnets = [
    cidrsubnet(var.vpc_cidr_block, 8, 0),
    cidrsubnet(var.vpc_cidr_block, 8, 1),
  ]

  # RDS fica em subnets isoladas (sem rota para internet)
  database_subnets = [
    cidrsubnet(var.vpc_cidr_block, 8, 10),
    cidrsubnet(var.vpc_cidr_block, 8, 11),
  ]
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway   = false
  enable_dns_support   = true
  enable_dns_hostnames = true
}
