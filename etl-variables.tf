# ----------------------------------------------------------------------------
# Variaveis do pipeline ETL (Step Functions)
# ----------------------------------------------------------------------------
variable "alert_email" {
  description = "E-mail que recebe alertas de falha do ETL (vazio = sem inscricao; confirme o e-mail de subscription apos o apply)"
  type        = string
  default     = "" # defina no terraform.tfvars - nunca hardcode dado pessoal em codigo versionado
}

variable "etl_lambda_runtime" {
  description = "Runtime das Lambdas do ETL"
  type        = string
  default     = "python3.12"
}

variable "build_python" {
  description = "Executavel Python usado no build local das Lambdas (pip install pg8000). Deixe null para detectar por plataforma (Windows: \"python\"; Linux/macOS/CI: \"python3\"). Defina explicitamente para apontar um venv, ex.: \".venv/bin/python\""
  type        = string
  default     = null
}
