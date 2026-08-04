resource "aws_cloudwatch_log_group" "metabase" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "metabase" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # habilitar em prod; gera custo de CloudWatch
  }
}

resource "aws_ecs_cluster_capacity_providers" "metabase" {
  cluster_name       = aws_ecs_cluster.metabase.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Estrategia padrao do cluster: 1 task on-demand garantida (base) e o
  # excedente em Spot. Obs.: o service abaixo define a propria estrategia,
  # que SEMPRE prevalece sobre esta - mantida identica por coerencia.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 0
    base              = 1
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "metabase" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.metabase_execution.arn
  task_role_arn            = aws_iam_role.metabase_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "metabase"
      image     = var.metabase_image
      essential = true

      portMappings = [
        {
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "MB_DB_TYPE", value = "postgres" },
        { name = "MB_DB_DBNAME", value = var.db_name },
        { name = "MB_DB_HOST", value = aws_db_instance.metabase_appdb.address },
        { name = "MB_DB_PORT", value = "5432" },
        # Limita a heap da JVM para caber na memoria da task
        { name = "JAVA_OPTS", value = "-Xmx${floor(var.task_memory * 0.75)}m" }
      ]

      # Credenciais extraidas do segredo gerenciado pelo RDS em runtime —
      # nunca em texto plano no task definition nem no state.
      secrets = [
        {
          name      = "MB_DB_USER"
          valueFrom = "${aws_db_instance.metabase_appdb.master_user_secret[0].secret_arn}:username::"
        },
        {
          name      = "MB_DB_PASS"
          valueFrom = "${aws_db_instance.metabase_appdb.master_user_secret[0].secret_arn}:password::"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:3000/api/health || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 120 # Metabase (JVM + migracoes) demora para subir
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.metabase.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "metabase"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "metabase" {
  name            = local.name
  cluster         = aws_ecs_cluster.metabase.id
  task_definition = aws_ecs_task_definition.metabase.arn
  desired_count   = var.metabase_desired_count

  # base=1 no FARGATE garante ao menos 1 task on-demand sempre viva; o
  # restante (weight) vai para Spot. O codigo anterior prometia isso no
  # comentario, mas colocava 100% em Spot - interrupcao simultanea das duas
  # tasks derrubaria o BI do cliente.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 0
    base              = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.metabase_task.id]
    assign_public_ip = true # necessario sem NAT para pull da imagem
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.metabase.arn
    container_name   = "metabase"
    container_port   = 3000
  }

  # Duas AZs: em Fargate, o scheduler distribui as tasks entre as subnets
  # informadas (uma por AZ) automaticamente — placement strategy explicita
  # nao e suportada (apenas launch type EC2).
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Deploy de imagem/config quebrada (ex.: tag inexistente, migracao que
  # falha) reverte sozinho para a task definition anterior em vez de ficar
  # em loop de tasks morrendo ate alguem intervir.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 180

  # Nada no service referencia o endpoint/SG do Secrets Manager, entao sem este
  # depends_on um apply limpo pode lancar a primeira task antes de o caminho de
  # rede existir. A task falharia no boot e o circuit breaker poderia reverter o
  # deployment por um problema apenas de ordenacao.
  depends_on = [
    aws_lb_listener.http,
    aws_vpc_endpoint.secretsmanager,
    aws_vpc_security_group_ingress_rule.vpce_https_ecs
  ]

  lifecycle {
    ignore_changes = [desired_count] # permite ajuste manual/auto scaling sem drift
  }
}
