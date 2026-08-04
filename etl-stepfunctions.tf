# ----------------------------------------------------------------------------
# IAM da maquina de estados: invocar as Lambdas, publicar no SNS e
# entregar logs no CloudWatch
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "etl_sfn" {
  name_prefix        = "${local.name}-sfn-"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "etl_sfn" {
  statement {
    sid     = "InvocarLambdas"
    actions = ["lambda:InvokeFunction"]
    resources = concat(
      [aws_lambda_function.etl_extrair.arn],
      [for fn in aws_lambda_function.etl_db : fn.arn]
    )
  }

  statement {
    sid       = "ExecutarGlueJob"
    actions   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
    resources = [aws_glue_job.raw_to_silver.arn]
  }

  statement {
    sid       = "PublicarAlertas"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.etl_alerts.arn]
  }

  # Permissoes exigidas pelo Step Functions para log delivery
  statement {
    sid = "EntregarLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "etl_sfn" {
  name   = "executar-etl"
  role   = aws_iam_role.etl_sfn.id
  policy = data.aws_iam_policy_document.etl_sfn.json
}

resource "aws_cloudwatch_log_group" "etl_sfn" {
  name              = "/aws/states/${local.name}-etl"
  retention_in_days = 30
}

# ----------------------------------------------------------------------------
# Maquina de estados (ASL definida em HCL via jsonencode)
# ----------------------------------------------------------------------------
resource "aws_sfn_state_machine" "etl" {
  name     = "${local.name}-etl"
  type     = "STANDARD"
  role_arn = aws_iam_role.etl_sfn.arn

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.etl_sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  definition = jsonencode({
    Comment = "ETL de atendimentos da clinica"
    StartAt = "ExtrairDados"
    States = {
      ExtrairDados = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.etl_extrair.function_name
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 5
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.erro"
          Next        = "NotificarFalha"
        }]
        Next = "GerarSilver"
      }

      # Roda o Glue job (raw -> silver Parquet + registro no Catalog) de forma
      # sincrona: a maquina espera concluir e qualquer falha cai no mesmo
      # funil de alerta. ResultPath preserva o payload original (bucket/key/
      # dataset) para os estados seguintes - sem ele, o retorno do Glue
      # substituiria o payload e o CarregarDados quebraria.
      GerarSilver = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.raw_to_silver.name
        }
        ResultPath = "$.glue"
        # ConcurrentRunsExceeded tem retry proprio e paciente: subir varios
        # CSVs de uma vez dispara N execucoes contra um job com
        # max_concurrent_runs = 1 - as demais precisam esperar a execucao
        # corrente (minutos) terminar, nao 30s. Como o job e full-refresh
        # idempotente, execucoes "repetidas" apenas reconvergem o silver.
        Retry = [
          {
            ErrorEquals     = ["Glue.ConcurrentRunsExceededException"]
            IntervalSeconds = 60
            MaxAttempts     = 6
            BackoffRate     = 1.5
          },
          {
            ErrorEquals     = ["Glue.AWSGlueException"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2
          }
        ]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.erro"
          Next        = "NotificarFalha"
        }]
        Next = "CarregarDados"
      }

      CarregarDados = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.etl_db["carregar"].function_name
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.SdkClientException"]
          IntervalSeconds = 10
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.erro"
          Next        = "NotificarFalha"
        }]
        Next = "ValidarQualidade"
      }

      ValidarQualidade = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.etl_db["validar"].function_name
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.SdkClientException"]
          IntervalSeconds = 10
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.erro"
          Next        = "NotificarFalha"
        }]
        Next = "QualidadeOk"
      }

      QualidadeOk = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.qualidade.aprovado"
          BooleanEquals = true
          Next          = "Sucesso"
        }]
        Default = "NotificarFalha"
      }

      NotificarFalha = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.etl_alerts.arn
          Subject     = "Falha no ETL da clinica"
          "Message.$" = "States.JsonToString($)"
        }
        Next = "Falha"
      }

      Falha = {
        Type  = "Fail"
        Error = "ETLFalhou"
        Cause = "Veja o alerta SNS e os logs no CloudWatch"
      }

      Sucesso = { Type = "Succeed" }
    }
  })
}
