# -----------------------------------------------------------------------------
# RDS PostgreSQL — perfil dev/test (menor custo)
#
# Segredo: a senha master e criada e rotacionavel pelo proprio RDS via
# manage_master_user_password. Ela NUNCA aparece em variaveis, tfvars ou no
# state (diferente de random_password, cujo valor fica gravado no state
# mesmo com sensitive = true).
# -----------------------------------------------------------------------------

resource "aws_db_instance" "metabase_appdb" {
  identifier = "${local.name}-appdb"

  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3" # gp3: mesmo preco ou menor que gp2, com baseline melhor
  storage_encrypted = true  # criptografia at-rest NAO tem custo adicional; obrigatoria p/ dado de saude

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Perfil dev/test: Single-AZ. O subnet group cobre duas AZs, entao em caso
  # de falha da AZ o RDS pode ser restaurado/movido para a outra — mas ha
  # downtime. Multi-AZ dobra o custo (~2x); ative em prod.
  multi_az = false

  # 7 dias em prod; 1 dia em dev (backups manuais seguem possiveis)
  backup_retention_period = var.environment == "prod" ? 7 : 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Postura por ambiente: dev destroi facil; prod exige snapshot final e
  # protege contra delecao acidental - sem depender de ninguem lembrar de editar.
  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = "${local.name}-appdb-final"

  performance_insights_enabled = false # nao suportado/necessario no t4g.micro dev

  tags = { Name = "${local.name}-appdb" }
}
