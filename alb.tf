resource "aws_lb" "metabase" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = module.vpc.public_subnets # duas AZs
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "metabase" {
  name        = local.name
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.metabase.arn
  port              = 80
  protocol          = "HTTP"

  # Com certificado: HTTP vira redirect 301 para HTTPS.
  # Sem certificado: encaminha direto (aceitavel apenas com TLS externo).
  dynamic "default_action" {
    for_each = var.certificate_arn != null ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.certificate_arn == null ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.metabase.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn != null ? 1 : 0

  load_balancer_arn = aws_lb.metabase.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.metabase.arn
  }
}
