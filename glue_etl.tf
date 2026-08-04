# -----------------------------------------------------------------------------
# ETL raw (CSV) -> silver (Parquet) via Glue Python Shell
#
# Python Shell a 0.0625 DPU e a menor unidade de computacao do Glue - custo de
# centavos por execucao, adequado a CSVs de pequeno/medio volume. O script
# registra as tabelas direto no Glue Catalog, eliminando a dependencia do
# crawler (cujo classificador CSV falha com separador ';').
# -----------------------------------------------------------------------------

# Bucket dedicado ao script do job. Nao reutilizamos o bucket de resultados do
# Athena porque a lifecycle rule dele expira objetos em 7 dias - apagaria o
# script silenciosamente.
resource "aws_s3_bucket" "glue_assets" {
  bucket = "${local.name}-glue-assets-${data.aws_caller_identity.current.account_id}"

  # Permite deletar o bucket mesmo com objetos
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "glue_assets" {
  bucket                  = aws_s3_bucket.glue_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "glue_assets" {
  bucket = aws_s3_bucket.glue_assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "etl_script" {
  bucket = aws_s3_bucket.glue_assets.id
  key    = "scripts/etl_raw_to_silver.py"
  source = "${path.module}/glue/etl_raw_to_silver.py"
  etag   = filemd5("${path.module}/glue/etl_raw_to_silver.py")
}

# --- IAM do job --------------------------------------------------------------
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_etl_job" {
  name               = "${local.name}-glue-etl-job"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

data "aws_iam_policy_document" "glue_etl_job" {
  statement {
    sid     = "ReadRawCsv"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.etl_raw.arn,
      "${aws_s3_bucket.etl_raw.arn}/*",
    ]
  }

  statement {
    sid    = "WriteSilverParquet"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # mode=overwrite remove os parquet da carga anterior
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.silver.arn,
      "${aws_s3_bucket.silver.arn}/*",
    ]
  }

  statement {
    sid     = "ReadScript"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.glue_assets.arn}/scripts/*",
    ]
  }

  statement {
    sid    = "CatalogRegisterTables"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable", # mode=overwrite recria a definicao da tabela
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${local.glue_database}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.glue_database}/*",
    ]
  }

  statement {
    sid    = "JobLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_etl_job" {
  name   = "${local.name}-glue-etl-job"
  role   = aws_iam_role.glue_etl_job.id
  policy = data.aws_iam_policy_document.glue_etl_job.json
}

# --- O job -------------------------------------------------------------------
resource "aws_glue_job" "raw_to_silver" {
  name     = "${local.name}-raw-to-silver"
  role_arn = aws_iam_role.glue_etl_job.arn

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.glue_assets.id}/${aws_s3_object.etl_script.key}"
  }

  # Menor capacidade possivel do Glue. Se o volume crescer (arquivos de
  # centenas de MB), suba para 1.0 antes de migrar para Spark.
  max_capacity = 0.0625
  max_retries  = 0
  timeout      = 30 # minutos

  default_arguments = {
    "--library-set"   = "analytics" # inclui awswrangler + pandas
    "--RAW_BUCKET"    = aws_s3_bucket.etl_raw.bucket
    "--RAW_PREFIX"    = "incoming/"
    "--SILVER_BUCKET" = aws_s3_bucket.silver.bucket
    "--GLUE_DATABASE" = local.glue_database
    "--CSV_SEP"       = var.raw_csv_separator
    "--CSV_ENCODING"  = var.raw_csv_encoding
  }

  execution_property {
    max_concurrent_runs = 1 # cargas concorrentes com overwrite se corromperiam
  }
}