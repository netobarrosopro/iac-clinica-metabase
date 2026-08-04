data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.prefix}-${var.environment}"

  # Exatamente duas AZs, conforme requisito de HA
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Buckets com dado regeneravel/derivado: teardown livre fora de prod.
  # Em prod a delecao volta a exigir esvaziamento manual (freio deliberado).
  bucket_force_destroy = var.environment != "prod"

  # Nomes de Athena/Glue derivados do ambiente por padrao (evita colisao
  # dev/prod na mesma conta); as variaveis permitem override se necessario.
  athena_workgroup = coalesce(var.athena_workgroup_name, "${local.name}-silver")
  glue_database    = coalesce(var.glue_database_name, replace("${local.name}_silver", "-", "_"))
}
