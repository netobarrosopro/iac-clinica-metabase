output "metabase_url" {
  description = "URL do Metabase via ALB (https quando ha certificado ACM; sem ele, o listener 80 encaminha direto)"
  value       = "${var.certificate_arn != null ? "https" : "http"}://${aws_lb.metabase.dns_name}"
}

output "alb_dns_name" {
  description = "DNS do load balancer (aponte seu CNAME/Cloudflare aqui)"
  value       = aws_lb.metabase.dns_name
}

output "rds_endpoint" {
  description = "Endpoint do RDS PostgreSQL (application database)"
  value       = aws_db_instance.metabase_appdb.address
}

output "db_master_secret_arn" {
  description = "ARN do segredo (Secrets Manager) gerenciado pelo RDS com as credenciais master"
  value       = aws_db_instance.metabase_appdb.master_user_secret[0].secret_arn
}

output "ecs_cluster_name" {
  description = "Nome do cluster ECS"
  value       = aws_ecs_cluster.metabase.name
}

output "athena_workgroup_name" {
  description = "Workgroup do Athena - preencher no campo 'Workgroup' do Metabase"
  value       = aws_athena_workgroup.metabase_silver.name
}

output "athena_results_s3_uri" {
  description = "S3 staging directory - preencher no campo 'S3 Staging Directory' do Metabase"
  value       = "s3://${aws_s3_bucket.athena_results.id}/"
}

output "glue_database_name" {
  description = "Database (namespace) no Glue Data Catalog correspondente a camada silver"
  value       = aws_glue_catalog_database.silver.name
}

output "silver_bucket" {
  description = "Bucket S3 da camada silver (Parquet gerado pelo Glue job)"
  value       = aws_s3_bucket.silver.bucket
}

output "glue_etl_job_name" {
  description = "Glue Job raw->silver (tambem orquestrado pela state machine; para rodar avulso: aws glue start-job-run --job-name <nome>)"
  value       = aws_glue_job.raw_to_silver.name
}