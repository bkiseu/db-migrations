aws_region         = "us-east-1"
project_name       = "db-migration"
environment        = "dev"

vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
database_subnet_cidrs = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]

db_allocated_storage = 20
db_engine_version    = "16.8"  # Downgraded to a more widely available version
db_instance_class    = "db.t3.small"
db_replica_instance_class = "db.t3.small"
db_name              = "appdb"
db_username          = "dbadmin"
db_password_secret_name = "db-migration-admin-password"

# GitHub configuration
github_repository = "your-org/db-migrations"
github_branch     = "main"

common_tags = {
  Project     = "db-migration"
  ManagedBy   = "terraform"
  Environment = "dev"
  Owner       = "infrastructure-team"
}