# S3 via Gateway endpoint: gratuito, basta anexar as route tables
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.database_route_table_ids
}

# SG do endpoint: HTTPS a partir de todo consumidor de Secrets Manager na VPC
resource "aws_security_group" "vpce" {
  name_prefix = "${local.name}-vpce-"
  description = "Interface endpoints (HTTPS interno)"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS a partir das Lambdas do ETL"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.etl_lambda.id
}

# private_dns_enabled abaixo sequestra secretsmanager.<regiao>.amazonaws.com
# para a VPC INTEIRA, nao so para as subnets onde o endpoint tem ENI. Logo as
# tasks Fargate — mesmo em subnet publica com IP publico e rota pela IGW —
# passam a resolver o nome para os IPs privados do endpoint e nunca mais saem
# para o endpoint publico. Sem este ingress, o agente do Fargate nao consegue
# buscar o segredo do RDS e a task morre no boot com
# "ResourceInitializationError: unable to pull secrets ... context deadline
# exceeded" (timeout de SG, nao problema de IAM).
resource "aws_vpc_security_group_ingress_rule" "vpce_https_ecs" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS a partir das tasks do Metabase (fetch do segredo no boot)"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.metabase_task.id
}

# Secrets Manager via Interface endpoint (~US$ 8/mes por AZ + trafego)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.database_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
}