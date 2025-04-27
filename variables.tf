variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
  default     = "your-org/db-migrations"
}

variable "github_branch" {
  description = "Branch name to monitor for changes"
  type        = string
  default     = "main"
}
variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used for naming resources"
  type        = string
  default     = "db-migration"
}

variable "environment" {
  description = "Environment (dev, staging, production)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
  default     = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]
}

variable "db_allocated_storage" {
  description = "Allocated storage for the RDS instance in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "Engine version for PostgreSQL"
  type        = string
  default     = "14.7"
}

variable "db_instance_class" {
  description = "Instance class for the primary RDS instance"
  type        = string
  default     = "db.t3.small"
}

variable "db_replica_instance_class" {
  description = "Instance class for the read replica RDS instance"
  type        = string
  default     = "db.t3.small"
}

variable "db_name" {
  description = "Name of the database"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Username for the database"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_password_secret_name" {
  description = "Name of the AWS Secrets Manager secret containing the database password"
  type        = string
  default     = "db-migration-admin-password"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "db-migration"
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}