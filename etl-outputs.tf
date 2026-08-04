output "etl_raw_bucket" {
  description = "Bucket onde os CSVs devem ser enviados (prefixo incoming/)"
  value       = aws_s3_bucket.etl_raw.bucket
}

output "etl_state_machine_arn" {
  description = "ARN da maquina de estados do ETL"
  value       = aws_sfn_state_machine.etl.arn
}

output "etl_alerts_topic_arn" {
  description = "Topico SNS de alertas de falha"
  value       = aws_sns_topic.etl_alerts.arn
}
