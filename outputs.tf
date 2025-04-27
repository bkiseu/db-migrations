output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnets
}

output "database_subnet_ids" {
  description = "List of database subnet IDs"
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Name of database subnet group"
  value       = module.vpc.database_subnet_group_name
}

output "rds_primary_hostname" {
  description = "Primary RDS instance hostname (writer)"
  value       = aws_db_instance.database_primary.address
  sensitive   = true
}

output "rds_replica_hostname" {
  description = "Read replica RDS instance hostname (reader)"
  value       = var.environment != "dev" ? aws_db_instance.database_replica[0].address : "No replica in dev environment"
  sensitive   = true
}

output "rds_port" {
  description = "RDS instance port"
  value       = aws_db_instance.database_primary.port
  sensitive   = true
}

output "rds_username" {
  description = "RDS instance root username"
  value       = aws_db_instance.database_primary.username
  sensitive   = true
}

output "db_credentials_secret_arn" {
  description = "ARN of the secret containing database credentials"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "github_connection_arn" {
  description = "ARN of the GitHub connection"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Status of the GitHub connection"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "codepipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.db_migration_pipeline.name
}

output "artifacts_bucket_name" {
  description = "Name of the S3 bucket for artifacts"
  value       = aws_s3_bucket.artifacts_bucket.bucket
}