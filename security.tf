# -----------------------------------------------------------------------------
# Security Groups — regras como recursos separados
# (aws_vpc_security_group_{ingress,egress}_rule), nunca blocos inline:
# regras inline geram identity churn e conflitos de gerenciamento.
# -----------------------------------------------------------------------------

# --- ALB ---------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB do Metabase - entrada web restrita aos CIDRs permitidos"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_allowed_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP de CIDR permitido"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = var.certificate_arn != null ? toset(var.alb_allowed_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS de CIDR permitido"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Saida apenas para as tasks do Metabase"
  referenced_security_group_id = aws_security_group.metabase_task.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# --- Tasks ECS ---------------------------------------------------------------
resource "aws_security_group" "metabase_task" {
  name        = "${local.name}-task"
  description = "Tasks Fargate do Metabase - entrada somente via ALB"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-task" }
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.metabase_task.id
  description                  = "Porta 3000 apenas a partir do ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_https_out" {
  security_group_id = aws_security_group.metabase_task.id
  description       = "HTTPS de saida (pull da imagem, Secrets Manager, logs)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_to_rds" {
  security_group_id            = aws_security_group.metabase_task.id
  description                  = "PostgreSQL para o RDS"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# --- RDS ---------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL - entrada somente das tasks do Metabase"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_tasks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL apenas das tasks do Metabase"
  referenced_security_group_id = aws_security_group.metabase_task.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
