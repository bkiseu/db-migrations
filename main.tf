provider "aws" {
  region = var.aws_region
}

# Random string for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Create VPC and networking components
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  private_subnets  = var.private_subnet_cidrs
  public_subnets   = var.public_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  # Enable NAT Gateway for private subnet internet access
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "production" # Use multiple NAT gateways in production

  # Enable DNS hostnames for RDS connectivity
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Database subnet group
  create_database_subnet_group = true

  tags = var.common_tags
}

# Security group for RDS
resource "aws_security_group" "db_security_group" {
  name        = "${var.project_name}-db-sg"
  description = "Security group for RDS database"
  vpc_id      = module.vpc.vpc_id

  # No direct inbound access from internet
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.db_migration_sg.id]
    description     = "Allow PostgreSQL access from DB migration lambda/services only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${var.project_name}-db-sg"
    }
  )
}

# Security group for DB migration services (Lambda, CodeBuild)
resource "aws_security_group" "db_migration_sg" {
  name        = "${var.project_name}-migration-sg"
  description = "Security group for database migration services"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${var.project_name}-migration-sg"
    }
  )
}

# Get the database password from Secrets Manager
data "aws_secretsmanager_secret" "db_password" {
  name = var.db_password_secret_name
}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = data.aws_secretsmanager_secret.db_password.id
}

locals {
  db_password = jsondecode(data.aws_secretsmanager_secret_version.db_password.secret_string)["password"]
}

# RDS Instance - Primary (Writer)
resource "aws_db_instance" "database_primary" {
  identifier           = "${var.project_name}-db-primary-${random_string.suffix.result}"
  allocated_storage    = var.db_allocated_storage
  storage_type         = "gp3"
  engine               = "postgres"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  db_name              = var.db_name
  username             = var.db_username
  password             = local.db_password
  parameter_group_name = "default.postgres16"
  skip_final_snapshot  = var.environment != "production"

  vpc_security_group_ids = [aws_security_group.db_security_group.id]
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  
  multi_az               = var.environment == "production"
  backup_retention_period = var.environment == "production" ? 7 : 1
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:30-sun:05:30"
  
  # Enable deletion protection in production
  deletion_protection = var.environment == "production"
  
  # Enable encryption
  storage_encrypted = true
  
  tags = merge(
    var.common_tags,
    {
      Name = "${var.project_name}-database-primary"
      Role = "writer"
    }
  )
}

# RDS Instance - Read Replica (Reader)
resource "aws_db_instance" "database_replica" {
  identifier           = "${var.project_name}-db-replica-${random_string.suffix.result}"
  replicate_source_db  = aws_db_instance.database_primary.identifier
  instance_class       = var.db_replica_instance_class
  parameter_group_name = "default.postgres16"
  
  vpc_security_group_ids = [aws_security_group.db_security_group.id]
  
  # No backups needed for replica
  backup_retention_period = 0
  skip_final_snapshot     = true
  
  # Auto minor version upgrades
  auto_minor_version_upgrade = true
  
  tags = merge(
    var.common_tags,
    {
      Name = "${var.project_name}-database-replica"
      Role = "reader"
    }
  )
  
  # Only create replica in production/staging environments
  count = var.environment != "dev" ? 1 : 0
}

# Store DB credentials in Secrets Manager
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project_name}/db-credentials-${random_string.suffix.result}"
  description = "Database credentials for ${var.project_name}"
  
  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = local.db_password
    engine   = "postgres"
    host     = aws_db_instance.database_primary.address
    reader_host = var.environment != "dev" ? aws_db_instance.database_replica[0].address : aws_db_instance.database_primary.address
    port     = 5432
    dbname   = var.db_name
  })
}

# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "${var.project_name}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for CodeBuild
resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild_role.id
  name = "${var.project_name}-codebuild-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs",
          "ec2:CreateNetworkInterfacePermission", # Added permission
          "ec2:AssignPrivateIpAddresses",        # Added permission
          "ec2:UnassignPrivateIpAddresses"       # Added permission
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetObjectVersion",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.artifacts_bucket.arn,
          "${aws_s3_bucket.artifacts_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# GitHub connection for CodePipeline
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project_name}-github-connection"
  provider_type = "GitHub"
  
  tags = var.common_tags
}

# S3 Bucket for Pipeline artifacts
resource "aws_s3_bucket" "artifacts_bucket" {
  bucket = "${var.project_name}-artifacts-${random_string.suffix.result}"
  
  tags = var.common_tags
}

# S3 Bucket versioning
resource "aws_s3_bucket_versioning" "artifacts_bucket_versioning" {
  bucket = aws_s3_bucket.artifacts_bucket.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts_bucket_encryption" {
  bucket = aws_s3_bucket.artifacts_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM Role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name = "${var.project_name}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for CodePipeline
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${var.project_name}-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning"
        ]
        Resource = [
          aws_s3_bucket.artifacts_bucket.arn,
          "${aws_s3_bucket.artifacts_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection"
        ]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.db_migration_executor.arn
      }
    ]
  })
}

# CodeBuild Project
resource "aws_codebuild_project" "db_migration_build" {
  name          = "${var.project_name}-db-migration-build"
  description   = "CodeBuild project for database migration validation"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 15
  
  artifacts {
    type = "CODEPIPELINE"
  }
  
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false
    
    environment_variable {
      name  = "DB_CREDENTIALS_SECRET_ARN"
      value = aws_secretsmanager_secret.db_credentials.arn
    }
  }
  
  vpc_config {
    vpc_id             = module.vpc.vpc_id
    subnets            = module.vpc.private_subnets
    security_group_ids = [aws_security_group.db_migration_sg.id]
  }
  
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
  
  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-db-migration-build"
      stream_name = "build-log"
    }
  }
  
  tags = var.common_tags
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.artifacts_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# Lambda Function to execute DB migrations
resource "aws_lambda_function" "db_migration_executor" {
  function_name    = "${var.project_name}-db-migration-executor"
  description      = "Executes database migration scripts"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "python3.9"
  timeout          = 300
  memory_size      = 1024

  # Use local file for deployment
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  environment {
    variables = {
      DB_CREDENTIALS_SECRET_ARN = aws_secretsmanager_secret.db_credentials.arn
    }
  }
  
  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.db_migration_sg.id]
  }
  
  tags = var.common_tags
  
}

# Upload Lambda code
resource "null_resource" "install_lambda_dependencies" {
  triggers = {
    requirements_md5 = filemd5("${path.module}/lambda/requirements.txt")
    lambda_code_md5  = filemd5("${path.module}/lambda/index.py")
  }

  provisioner "local-exec" {
    command = <<EOT
      # Create lambda layer directory structure
      mkdir -p ${path.module}/lambda_layer/python
      
      # Install dependencies into the lambda layer directory
      pip install -r ${path.module}/lambda/requirements.txt -t ${path.module}/lambda_layer/python --no-cache-dir
      
      # Clean up unnecessary files to reduce package size
      find ${path.module}/lambda_layer -type d -name "__pycache__" -exec rm -rf {} +
      find ${path.module}/lambda_layer -type d -name "*.dist-info" -exec rm -rf {} +
      find ${path.module}/lambda_layer -type d -name "*.egg-info" -exec rm -rf {} +
      find ${path.module}/lambda_layer -type f -name "*.pyc" -delete
      find ${path.module}/lambda_layer -type f -name "*.pyo" -delete
      find ${path.module}/lambda_layer -type f -name "*.pyd" -delete
    EOT
  }
}

# Lambda package creation
# Note: For a production setup, we would use a null_resource with local-exec
# to run the build_lambda.sh script instead of this simple archive
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  
  source_dir = "${path.module}/lambda"
  excludes   = ["__pycache__", "*.pyc"]
}

# CodePipeline
resource "aws_codepipeline" "db_migration_pipeline" {
  name     = "${var.project_name}-db-migration-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn
  
  artifact_store {
    location = aws_s3_bucket.artifacts_bucket.bucket
    type     = "S3"
  }
  
  stage {
    name = "Source"
    
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.github_branch
      }
    }
  }
  
  stage {
    name = "Validate"
    
    action {
      name             = "ValidateMigrations"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"
      
      configuration = {
        ProjectName = aws_codebuild_project.db_migration_build.name
      }
    }
  }
  
  stage {
    name = "Approve"
    
    action {
      name     = "ApproveChanges"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      
      configuration = {
        CustomData = "Please review the database changes before approving"
      }
    }
  }
  
  stage {
    name = "Deploy"
    
    action {
      name            = "ExecuteMigrations"
      category        = "Invoke"
      owner           = "AWS"
      provider        = "Lambda"
      input_artifacts = ["build_output"]
      version         = "1"
      
      configuration = {
        FunctionName   = aws_lambda_function.db_migration_executor.function_name
        UserParameters = "migrations"
      }
    }
  }
  
  tags = var.common_tags
}


# Remove the CloudWatch Event Rule since GitHub webhooks will handle this
# Commenting out rather than deleting for reference
# 
# # CloudWatch Event Rule for CodeCommit
# resource "aws_cloudwatch_event_rule" "codecommit_trigger" {
#   name        = "${var.project_name}-codecommit-trigger"
#   description = "Trigger CodePipeline on CodeCommit repository changes"
#   
#   event_pattern = jsonencode({
#     source      = ["aws.codecommit"]
#     detail-type = ["CodeCommit Repository State Change"]
#     resources   = [aws_codecommit_repository.db_migrations_repo.arn]
#     detail = {
#       event         = ["referenceCreated", "referenceUpdated"]
#       referenceType = ["branch"]
#       referenceName = ["main"]
#     }
#   })
# }
# 
# # CloudWatch Event Target
# resource "aws_cloudwatch_event_target" "codecommit_target" {
#   rule     = aws_cloudwatch_event_rule.codecommit_trigger.name
#   arn      = aws_codepipeline.db_migration_pipeline.arn
#   role_arn = aws_iam_role.cloudwatch_role.arn
# }
# 
# # IAM Role for CloudWatch Event
# resource "aws_iam_role" "cloudwatch_role" {
#   name = "${var.project_name}-cloudwatch-role"
#   
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "events.amazonaws.com"
#         }
#       }
#     ]
#   })
#   
#   tags = var.common_tags
# }
# 
# # IAM Policy for CloudWatch Event
# resource "aws_iam_role_policy" "cloudwatch_policy" {
#   name = "${var.project_name}-cloudwatch-policy"
#   role = aws_iam_role.cloudwatch_role.id
#   
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Action = [
#           "codepipeline:StartPipelineExecution"
#         ]
#         Resource = aws_codepipeline.db_migration_pipeline.arn
#       }
#     ]
#   })
# }