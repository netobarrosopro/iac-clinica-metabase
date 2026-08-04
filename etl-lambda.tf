locals {
  # Funcoes que acessam o RDS (precisam de VPC e da lib pg8000)
  etl_db_functions = toset(["carregar", "validar"])

  db_master_secret_arn = aws_db_instance.metabase_appdb.master_user_secret[0].secret_arn

  etl_db_env = {
    DB_HOST       = aws_db_instance.metabase_appdb.address
    DB_NAME       = "analytics"
    DB_SECRET_ARN = local.db_master_secret_arn
  }

  # Windows nao tem o executavel "python3": o que existe em WindowsApps e um
  # alias da Microsoft Store que apenas imprime "Python nao foi encontrado" e
  # sai com codigo 9009, derrubando o local-exec do build. Em Linux/macOS o
  # inverso e verdade ("python" frequentemente nao existe). Por isso o default
  # e detectado por plataforma em vez de fixo.
  #
  # A deteccao usa abspath(path.root) - no Windows retorna "C:/..." (letra de
  # drive) e no Unix "/...". Preferido a pathexpand("~") por nao depender de
  # HOME/USERPROFILE, que shells emulados (Git Bash, MSYS) podem exportar em
  # formato Unix e fariam a deteccao errar.
  is_windows   = length(regexall("^[A-Za-z]:/", abspath(path.root))) > 0
  build_python = coalesce(var.build_python, local.is_windows ? "python" : "python3")
}

# ----------------------------------------------------------------------------
# Rede: SG das Lambdas + liberacao no SG do RDS
# ----------------------------------------------------------------------------
resource "aws_security_group" "etl_lambda" {
  name_prefix = "${local.name}-etl-lambda-"
  description = "Lambdas do pipeline ETL"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "etl_lambda_all" {
  security_group_id = aws_security_group.etl_lambda.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_etl_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL a partir das Lambdas do ETL"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.etl_lambda.id
}

# ----------------------------------------------------------------------------
# IAM: role das Lambdas com menor privilegio
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "etl_lambda" {
  name_prefix        = "${local.name}-etl-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "etl_lambda_vpc" {
  role       = aws_iam_role.etl_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "etl_lambda" {
  statement {
    sid       = "LerBucketRaw"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.etl_raw.arn}/*"]
  }
  statement {
    sid       = "LerSenhaDoBanco"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_master_secret_arn]
  }
}

resource "aws_iam_role_policy" "etl_lambda" {
  name   = "acesso-etl"
  role   = aws_iam_role.etl_lambda.id
  policy = data.aws_iam_policy_document.etl_lambda.json
}

# ----------------------------------------------------------------------------
# Empacotamento
# - extrair: sem dependencias -> zip direto do .py
# - carregar/validar: pip install pg8000 no diretorio de build (requer
#   pip disponivel na maquina que roda o terraform apply)
# ----------------------------------------------------------------------------
data "archive_file" "etl_extrair" {
  type        = "zip"
  source_file = "${path.module}/lambda/extrair.py"
  output_path = "${path.module}/build/extrair.zip"
}

resource "null_resource" "etl_build" {
  for_each = local.etl_db_functions

  triggers = {
    source_hash = filesha256("${path.module}/lambda/${each.key}.py")
  }

  # Build multiplataforma: o proprio Python faz limpeza, pip install e copia.
  # Funciona identico em Windows, Linux, macOS e CI - a versao anterior usava
  # PowerShell e quebrava qualquer apply fora do Windows.
  provisioner "local-exec" {
    interpreter = [local.build_python, "-c"]
    command     = <<-EOT
      import pathlib, shutil, subprocess, sys
      base = pathlib.Path(r"${path.module}") / "build" / "${each.key}"
      shutil.rmtree(base, ignore_errors=True)
      base.mkdir(parents=True, exist_ok=True)
      subprocess.check_call([sys.executable, "-m", "pip", "install", "pg8000",
                             "--quiet", "--target", str(base)])
      shutil.copy(pathlib.Path(r"${path.module}") / "lambda" / "${each.key}.py", base)
    EOT
  }
}

data "archive_file" "etl_db_fn" {
  for_each    = local.etl_db_functions
  type        = "zip"
  source_dir  = "${path.module}/build/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"

  depends_on = [null_resource.etl_build]
}

# ----------------------------------------------------------------------------
# Funcoes
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "etl_lambda" {
  for_each          = setunion(local.etl_db_functions, ["extrair"])
  name              = "/aws/lambda/${local.name}-etl-${each.key}"
  retention_in_days = 30
}

resource "aws_lambda_function" "etl_extrair" {
  function_name    = "${local.name}-etl-extrair"
  runtime          = var.etl_lambda_runtime
  handler          = "extrair.handler"
  role             = aws_iam_role.etl_lambda.arn
  filename         = data.archive_file.etl_extrair.output_path
  source_code_hash = data.archive_file.etl_extrair.output_base64sha256
  timeout          = 60
  memory_size      = 256

  depends_on = [aws_cloudwatch_log_group.etl_lambda]
}

resource "aws_lambda_function" "etl_db" {
  for_each         = local.etl_db_functions
  function_name    = "${local.name}-etl-${each.key}"
  runtime          = var.etl_lambda_runtime
  handler          = "${each.key}.handler"
  role             = aws_iam_role.etl_lambda.arn
  filename         = data.archive_file.etl_db_fn[each.key].output_path
  source_code_hash = data.archive_file.etl_db_fn[each.key].output_base64sha256
  timeout          = 300
  memory_size      = 512

  vpc_config {
    subnet_ids         = module.vpc.database_subnets
    security_group_ids = [aws_security_group.etl_lambda.id]
  }

  environment {
    variables = local.etl_db_env
  }

  depends_on = [aws_cloudwatch_log_group.etl_lambda]
}

# Cria o database "analytics" na instancia RDS uma unica vez, via invocacao
# da propria Lambda de carga (acao de setup idempotente)
resource "aws_lambda_invocation" "criar_database_analytics" {
  function_name = aws_lambda_function.etl_db["carregar"].function_name
  input         = jsonencode({ acao = "criar_database" })

  # Sem triggers, a invocacao roda apenas na criacao do recurso. Se o RDS for
  # destruido e recriado (novo id), o database "analytics" nao existiria e o
  # pipeline falharia silenciosamente na primeira carga.
  triggers = {
    rds_instance = aws_db_instance.metabase_appdb.id
  }

  depends_on = [
    aws_db_instance.metabase_appdb,
    aws_vpc_security_group_ingress_rule.rds_from_etl_lambda,
    # Sem os endpoints, a Lambda (em subnet isolada, sem rota p/ internet)
    # nao alcanca o Secrets Manager e a invocacao de setup expira em timeout
    aws_vpc_endpoint.secretsmanager,
    aws_vpc_endpoint.s3
  ]
}
