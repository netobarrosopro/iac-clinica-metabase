# =============================================================================
# Monitoramento e observabilidade — CloudWatch (desenhado para o always free)
#
# Orcamento free respeitado por construcao:
#   - 10 alarmes            -> usamos exatamente 10 (o de Lambdas soma as 3
#                              funcoes via metric math, contando como 1)
#   - 3 dashboards          -> usamos 1
#   - 10 metricas custom    -> usamos 0 (so metricas nativas)
#   - 2 budgets             -> usamos 1
#   - Regras EventBridge para eventos AWS (Glue FAILED, interrupcao Spot)
#     sao gratuitas e substituem alarmes onde o evento nativo e mais rico.
#
# Todos os alarmes publicam no topico SNS etl_alerts ja existente (mesma
# subscription de e-mail ja confirmada — zero novo opt-in).
# =============================================================================

# --- Variaveis ---------------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Teto mensal de custo (USD) para o AWS Budget. Alertas em 80% real e 100% projetado. A stack dev custa ~30-45 USD/mes em sa-east-1"
  type        = number
  default     = 50
}

variable "monitoring_thresholds" {
  description = "Overrides pontuais dos limiares dos alarmes (merge sobre os defaults em locals.mon). Ex.: { rds_cpu_pct = 80 }"
  type        = map(number)
  default     = {}
}

locals {
  # Limiares default. Racional de cada um nos comentarios dos alarmes.
  mon = merge(
    {
      alb_5xx_count          = 5          # erros 5xx do target em 5 min
      ecs_cpu_pct            = 85         # media em 10 min
      ecs_memory_pct         = 90         # JVM perto do OOM-kill
      rds_cpu_pct            = 90         # media em 10 min
      rds_free_storage_bytes = 3221225472 # 3 GiB de 20 GB alocados
      rds_freeable_mem_bytes = 104857600  # 100 MiB de 1 GiB do t4g.micro
      rds_cpu_credits        = 20         # familia T: throttle silencioso
      lambda_error_count     = 1          # qualquer erro em 5 min
      sfn_failed_count       = 1          # qualquer execucao falha
    },
    var.monitoring_thresholds
  )

  alarm_actions = [aws_sns_topic.etl_alerts.arn]
}

# =============================================================================
# 1-2) ALB — o BI do cliente esta no ar e saudavel?
# =============================================================================

# O alarme mais importante da stack: zero targets saudaveis = cliente sem BI.
# treat_missing = breaching de proposito — se a metrica sumir (ALB/TG
# deletado, regiao com problema), a AUSENCIA de dado tambem e incidente.
resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
  alarm_name        = "${local.name}-alb-sem-targets-saudaveis"
  alarm_description = "Nenhuma task do Metabase saudavel atras do ALB - BI fora do ar"
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.metabase.arn_suffix
    TargetGroup  = aws_lb_target_group.metabase.arn_suffix
  }
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Metabase de pe porem quebrando (erros de app, banco inacessivel, etc).
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name        = "${local.name}-alb-target-5xx"
  alarm_description = "Respostas 5xx vindas do Metabase acima do tolerado"
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HTTPCode_Target_5XX_Count"
  dimensions = {
    LoadBalancer = aws_lb.metabase.arn_suffix
    TargetGroup  = aws_lb_target_group.metabase.arn_suffix
  }
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.mon.alb_5xx_count
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching" # sem trafego/sem erro = sem dado, e esta ok
  alarm_actions       = local.alarm_actions
}

# =============================================================================
# 3-4) ECS — as tasks do Metabase estao saturadas?
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name        = "${local.name}-ecs-cpu-alta"
  alarm_description = "CPU media do service acima do limiar - dashboards ficarao lentos"
  namespace         = "AWS/ECS"
  metric_name       = "CPUUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.metabase.name
    ServiceName = aws_ecs_service.metabase.name
  }
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.mon.ecs_cpu_pct
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching" # service parado ja dispara o alarme 1
  alarm_actions       = local.alarm_actions
}

# Memoria e mais critica que CPU aqui: a JVM estourando o limite da task
# leva a OOM-kill e restart em loop.
resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name        = "${local.name}-ecs-memoria-alta"
  alarm_description = "Memoria do service proxima do limite da task - risco de OOM-kill da JVM"
  namespace         = "AWS/ECS"
  metric_name       = "MemoryUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.metabase.name
    ServiceName = aws_ecs_service.metabase.name
  }
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.mon.ecs_memory_pct
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# =============================================================================
# 5-8) RDS — o banco (t4g.micro, 1 GiB RAM, 20 GB gp3) esta saudavel?
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu-alta"
  alarm_description   = "CPU do RDS acima do limiar por periodo sustentado"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.metabase_appdb.identifier }
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.mon.rds_cpu_pct
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# Storage-full trava o RDS em estado que exige intervencao manual - alarme
# com folga (3 GiB) para agir com calma (aumentar allocated_storage e apply).
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${local.name}-rds-pouco-storage"
  alarm_description   = "Storage livre do RDS abaixo de 3 GiB - aumente db_allocated_storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.metabase_appdb.identifier }
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = local.mon.rds_free_storage_bytes
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "breaching" # RDS sumir com a metrica tambem e incidente
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "${local.name}-rds-pouca-memoria"
  alarm_description   = "FreeableMemory abaixo de 100 MiB no t4g.micro - risco de swap e degradacao"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.metabase_appdb.identifier }
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = local.mon.rds_freeable_mem_bytes
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# O alarme que quase todo mundo esquece na familia T: creditos de burst
# zerados degradam o banco de forma silenciosa - parece query lenta, mas e
# throttle de CPU. Antecede o alarme de CPU em dias, nao minutos.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_credits" {
  alarm_name          = "${local.name}-rds-creditos-baixos"
  alarm_description   = "CPUCreditBalance baixo no t4g.micro - throttle iminente; avalie subir a classe da instancia"
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.metabase_appdb.identifier }
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = local.mon.rds_cpu_credits
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# =============================================================================
# 9) Step Functions — complementa o Catch/SNS interno da state machine:
# pega execucoes abortadas SEM passar pelo NotificarFalha (timeout da propria
# maquina, erro de permissao do role, execucao morta por States.Runtime).
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name          = "${local.name}-etl-execucao-falhou"
  alarm_description   = "Execucao da state machine do ETL terminou em falha"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.etl.arn }
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.mon.sfn_failed_count
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching" # pipeline parado nao e falha
  alarm_actions       = local.alarm_actions
}

# =============================================================================
# 10) Lambdas — metric math soma os Errors das 3 funcoes num alarme so
# (conta como 1 alarme no free tier, em vez de 3). Pega invocacoes com erro
# fora da state machine (ex.: a aws_lambda_invocation de setup).
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-etl-lambda-erros"
  alarm_description   = "Alguma Lambda do ETL (extrair/carregar/validar) registrou erro"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.mon.lambda_error_count
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  metric_query {
    id          = "total"
    expression  = "extrair + carregar + validar"
    label       = "Erros somados das Lambdas do ETL"
    return_data = true
  }

  metric_query {
    id = "extrair"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.etl_extrair.function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "carregar"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.etl_db["carregar"].function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "validar"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.etl_db["validar"].function_name }
      period      = 300
      stat        = "Sum"
    }
  }
}

# =============================================================================
# EventBridge -> SNS: eventos nativos no lugar de alarmes (gratuitos e mais
# ricos - trazem nome do job, run id e mensagem de erro no corpo)
# =============================================================================

# Glue job FAILED/TIMEOUT. O Step Functions ja captura falha do job quando o
# dispara, mas execucoes avulsas (aws glue start-job-run manual) nao passam
# pela state machine - este evento cobre todas as origens.
resource "aws_cloudwatch_event_rule" "glue_job_falhou" {
  name        = "${local.name}-glue-job-falhou"
  description = "Glue job raw->silver terminou em FAILED ou TIMEOUT"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.raw_to_silver.name]
      state   = ["FAILED", "TIMEOUT"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_job_falhou_sns" {
  rule = aws_cloudwatch_event_rule.glue_job_falhou.name
  arn  = aws_sns_topic.etl_alerts.arn
}

# Interrupcao de Fargate Spot. Nao e acionavel (o ECS repoe a task e ha
# base=1 on-demand), mas registra a frequencia - insumo para decidir se Spot
# segue valendo a pena por cliente.
resource "aws_cloudwatch_event_rule" "spot_interrompido" {
  name        = "${local.name}-spot-interrompido"
  description = "Task Fargate Spot do Metabase interrompida pela AWS"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.metabase.arn]
      stopCode   = ["TerminationNotice"]
    }
  })
}

resource "aws_cloudwatch_event_target" "spot_interrompido_sns" {
  rule = aws_cloudwatch_event_rule.spot_interrompido.name
  arn  = aws_sns_topic.etl_alerts.arn
}

# Politica do topico: EventBridge (events.amazonaws.com) precisa de permissao
# explicita para publicar. Alarmes CloudWatch NAO precisam (a policy default
# do SNS ja permite cloudwatch.amazonaws.com da mesma conta). O statement
# do owner e preservado para nao perder o gerenciamento via console/CLI.
data "aws_iam_policy_document" "etl_alerts_topic" {
  
  statement {
    sid = "OwnerFullAccess"
    actions = [
      "sns:AddPermission",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
    ]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = [aws_sns_topic.etl_alerts.arn]
  }

  statement {
    sid     = "EventBridgePublish"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.etl_alerts.arn]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.glue_job_falhou.arn,
        aws_cloudwatch_event_rule.spot_interrompido.arn,
      ]
    }
  }
}

resource "aws_sns_topic_policy" "etl_alerts" {
  arn    = aws_sns_topic.etl_alerts.arn
  policy = data.aws_iam_policy_document.etl_alerts_topic.json
}

# =============================================================================
# AWS Budget — guarda-chuva de custo da conta (2 budgets sao always free).
# Alerta em 80% do teto (gasto real) e 100% (projecao do mes).
# So cria se ha e-mail configurado - budget sem destinatario e inutil.
# =============================================================================

resource "aws_budgets_budget" "mensal" {
  count = var.alert_email != "" ? 1 : 0

  name        = "${local.name}-mensal"
  budget_type = "COST"

  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# =============================================================================
# Dashboard consolidado (1 dos 3 gratuitos) — BI, compute, banco e pipeline
# numa tela. ~22 metricas, bem abaixo do teto de 50.
# =============================================================================

resource "aws_cloudwatch_dashboard" "principal" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      # --- Faixa 1: BI (ALB) -------------------------------------------------
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6
        properties = {
          title  = "Requests e latencia p95"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.metabase.arn_suffix],
            [".", "TargetResponseTime", ".", ".", { stat = "p95", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6
        properties = {
          title  = "Erros 5xx (target e ALB)"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.metabase.arn_suffix, "TargetGroup", aws_lb_target_group.metabase.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.metabase.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6
        properties = {
          title  = "Targets saudaveis"
          region = var.aws_region
          stat   = "Minimum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.metabase.arn_suffix, "TargetGroup", aws_lb_target_group.metabase.arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },

      # --- Faixa 2: Compute (ECS) --------------------------------------------
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS - CPU e memoria do service (%)"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.metabase.name, "ServiceName", aws_ecs_service.metabase.name],
            [".", "MemoryUtilization", ".", ".", ".", "."],
          ]
        }
      },

      # --- Faixa 2: Banco (RDS) ----------------------------------------------
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "RDS - CPU, creditos e conexoes"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.metabase_appdb.identifier],
            [".", "CPUCreditBalance", ".", ".", { yAxis = "right" }],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "RDS - memoria e storage livres (bytes)"
          region = var.aws_region
          stat   = "Minimum"
          period = 300
          metrics = [
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", aws_db_instance.metabase_appdb.identifier],
            [".", "FreeStorageSpace", ".", ".", { yAxis = "right" }],
          ]
        }
      },

      # --- Faixa 3: Pipeline (Step Functions + Lambdas) ----------------------
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "ETL - execucoes da state machine"
          region = var.aws_region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.etl.arn],
            [".", "ExecutionsSucceeded", ".", "."],
            [".", "ExecutionsFailed", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 18, width = 24, height = 6
        properties = {
          title  = "ETL - erros e duracao das Lambdas"
          region = var.aws_region
          period = 3600
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.etl_extrair.function_name, { stat = "Sum" }],
            [".", "Errors", ".", aws_lambda_function.etl_db["carregar"].function_name, { stat = "Sum" }],
            [".", "Errors", ".", aws_lambda_function.etl_db["validar"].function_name, { stat = "Sum" }],
            [".", "Duration", ".", aws_lambda_function.etl_db["carregar"].function_name, { stat = "p95", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
