# ----------------------------------------------------------------------------
# EventBridge: CSV criado em incoming/ no bucket raw -> inicia o pipeline
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "etl_events" {
  name_prefix        = "${local.name}-evt-"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "etl_events" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.etl.arn]
  }
}

resource "aws_iam_role_policy" "etl_events" {
  name   = "iniciar-etl"
  role   = aws_iam_role.etl_events.id
  policy = data.aws_iam_policy_document.etl_events.json
}

resource "aws_cloudwatch_event_rule" "csv_chegou" {
  name        = "${local.name}-etl-csv-chegou"
  description = "Dispara o ETL quando um CSV chega em incoming/"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.etl_raw.bucket] }
      object = { key = [{ wildcard = "incoming/*.csv" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "iniciar_etl" {
  rule     = aws_cloudwatch_event_rule.csv_chegou.name
  arn      = aws_sfn_state_machine.etl.arn
  role_arn = aws_iam_role.etl_events.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<-EOT
      {"bucket": <bucket>, "key": <key>}
    EOT
  }
}
