# -----------------------------------------------------------------------------
# Athena — consulta aos Parquet da camada silver via Glue Data Catalog
#
# Design: o silver e ARTEFATO INTERNO desta stack - quem escreve nele e o
# proprio Glue job do projeto, entao ele e gerenciado aqui como recurso
# (a versao anterior o referenciava como data source "externo" apontando um
# bucket criado a mao, que envelheceu e causou o incidente do crawler).
# Metastore (Glue) e compute (Athena Workgroup) sao criados aqui porque hoje
# so o Metabase consome esse catalogo; se outras ferramentas (Spark, dbt,
# outro BI) passarem a consumir, promova para um modulo/state proprio.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "silver" {
  bucket = "${local.name}-silver-${data.aws_caller_identity.current.account_id}"

  # Dado derivado (regeneravel a partir do raw): teardown livre fora de prod
  force_destroy = local.bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Bucket de resultados do Athena (staging, transitorio) --------------------
resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name}-athena-results-${data.aws_caller_identity.current.account_id}"

  # Permite deletar o bucket mesmo com objetos
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7 # resultados sao cache transitorio, nao dado de negocio
    }
  }
}

# --- Workgroup dedicado --------------------------------------------------------
# enforce_workgroup_configuration = true trava a config abaixo no servidor:
# mesmo que alguem preencha outro S3 staging directory no client (Metabase),
# a AWS ignora e usa esta. Isolamento de custo: metricas e cutoff por query
# ficam neste workgroup, nunca misturados com "primary".
resource "aws_athena_workgroup" "metabase_silver" {
  name  = local.athena_workgroup
  state = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# --- Glue Data Catalog: namespace da camada silver -----------------------------
resource "aws_glue_catalog_database" "silver" {
  name = local.glue_database
}


