# ----------------------------------------------------------------------------
# Bucket de entrada (raw). A clinica/voce sobe CSVs em incoming/ e o
# EventBridge dispara o pipeline.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "etl_raw" {
  bucket = "${local.name}-etl-raw-${data.aws_caller_identity.current.account_id}"

  # Dev: teardown livre (force_destroy remove objetos E versoes).
  # Prod: dado bruto de cliente - delecao exige esvaziamento manual deliberado.
  force_destroy = local.bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "etl_raw" {
  bucket                  = aws_s3_bucket.etl_raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "etl_raw" {
  bucket = aws_s3_bucket.etl_raw.id
  versioning_configuration {
    # Versionamento e a protecao contra sobrescrita/delecao acidental de dado
    # de cliente. "Suspended para facilitar delecao" atacava o sintoma errado:
    # quem resolve o teardown e o force_destroy acima, que apaga versoes tambem.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etl_raw" {
  bucket = aws_s3_bucket.etl_raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Habilita o envio de eventos do bucket para o EventBridge
resource "aws_s3_bucket_notification" "etl_raw" {
  bucket      = aws_s3_bucket.etl_raw.id
  eventbridge = true
}

# ----------------------------------------------------------------------------
# SNS para alertas de falha do pipeline
# ----------------------------------------------------------------------------
resource "aws_sns_topic" "etl_alerts" {
  name = "${local.name}-etl-alertas"
}

resource "aws_sns_topic_subscription" "etl_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.etl_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Marcador do prefixo incoming/ (a "pasta" que aparece no console)
resource "aws_s3_object" "incoming_prefix" {
  bucket       = aws_s3_bucket.etl_raw.id
  key          = "incoming/"
  content_type = "application/x-directory"
}