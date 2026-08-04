variable "aws_region" {
  description = "Regiao AWS onde a stack sera provisionada"
  type        = string
  default     = "sa-east-1"
}

variable "environment" {
  description = "Nome do ambiente (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment deve ser dev, staging ou prod."
  }
}

variable "prefix" {
  description = "Prefixo aplicado ao nome de todos os recursos"
  type        = string
  default     = "metabase"
}

variable "vpc_cidr_block" {
  description = "CIDR da VPC dedicada ao Metabase"
  type        = string
  default     = "10.20.0.0/16"
}

variable "metabase_image" {
  description = "Imagem Docker do Metabase. Sempre pinar tag exata — nunca usar :latest (tag mutavel quebra reprodutibilidade e rollback)"
  type        = string
  default     = "metabase/metabase:v0.62.1.3"
}

variable "metabase_desired_count" {
  description = "Numero de tasks do Metabase (>= 2 para HA em duas AZs)"
  type        = number
  default     = 2

  validation {
    condition     = var.metabase_desired_count >= 1
    error_message = "desired_count deve ser >= 1 (use 2+ para HA em duas AZs; 1 e aceitavel em dev)."
  }
}

variable "task_cpu" {
  description = "CPU da task Fargate (unidades). Metabase e JVM: 1024 (1 vCPU) e o minimo pratico - com 512 o boot (JVM + migrations) fica lento a ponto de flertar com o healthcheck"
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Memoria da task Fargate em MiB. Metabase recomenda >= 2048"
  type        = number
  default     = 2048
}

variable "db_engine_version" {
  description = "Versao do PostgreSQL no RDS. Use apenas a major (ex: \"17\"): o RDS resolve a minor mais recente disponivel, e auto_minor_version_upgrade cuida dos patches. Confirme com: aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'"
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  description = "Classe da instancia RDS (perfil dev/test de menor custo)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Storage inicial do RDS em GB (gp3). Para free tier, 20GB e suficiente para Metabase dev/test"
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 100
    error_message = "Storage deve ser entre 20GB (minimo) e 100GB (maximo razoavel para dev/test)."
  }
}

variable "db_name" {
  description = "Nome do application database do Metabase"
  type        = string
  default     = "metabaseappdb"
}

variable "db_username" {
  description = "Usuario master do RDS. A senha e gerenciada pelo proprio RDS via Secrets Manager (nunca passa pelo Terraform nem pelo state)"
  type        = string
  default     = "metabase_admin"
}

variable "alb_allowed_cidr_blocks" {
  description = "CIDRs autorizados a acessar o ALB. Restrinja ao IP do escritorio/VPN — evite 0.0.0.0/0 em qualquer ambiente com dados reais"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "certificate_arn" {
  description = "ARN de certificado ACM para HTTPS no ALB. Se null, apenas HTTP e exposto (aceitavel somente atras de proxy TLS, ex.: Cloudflare)"
  type        = string
  default     = null
}

# --- Athena / Glue (camada silver) -------------------------------------------

variable "glue_database_name" {
  description = "Override do nome do database no Glue Data Catalog (null = derivado do ambiente: <prefix>_<env>_silver)"
  type        = string
  default     = null
  nullable    = true
}

variable "athena_workgroup_name" {
  description = "Override do nome do Athena workgroup (null = derivado do ambiente: <prefix>-<env>-silver). Nunca usar 'primary' compartilhado"
  type        = string
  default     = null
  nullable    = true
}

variable "athena_bytes_scanned_cutoff" {
  description = "Limite de bytes escaneados por query no workgroup, em bytes (controle de custo). Minimo AWS: 10485760 (10 MB). Default aqui: 5 GB"
  type        = number
  default     = 5368709120

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "athena_bytes_scanned_cutoff deve ser >= 10485760 bytes (10 MB), minimo aceito pela AWS."
  }
}



variable "raw_csv_separator" {
  description = "Separador dos CSVs da camada raw. 'auto' detecta por arquivo (recomendado: cobre tanto ',' do Synthea quanto ';' de sistemas BR)"
  type        = string
  default     = "auto"
}

variable "raw_csv_encoding" {
  description = "Encoding dos CSVs da camada raw. 'auto' tenta utf-8 e cai para latin-1 (recomendado)"
  type        = string
  default     = "auto"
}
