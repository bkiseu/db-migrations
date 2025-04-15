# Database Migration Pipeline

This repository contains Terraform configurations for setting up a secure database migration pipeline using AWS CodePipeline, CodeCommit, and CodeDeploy. The solution ensures that database changes are only applied through a controlled PR process.

## Architecture

![Architecture Diagram](https://via.placeholder.com/800x500)

The solution includes:

1. **VPC with Private Subnets**: RDS database is deployed in private subnets, inaccessible from the internet.
2. **CodeCommit Repository**: Stores SQL migration scripts.
3. **CodePipeline**: Orchestrates the workflow from code commit to deployment.
4. **CodeBuild**: Validates the SQL scripts before deployment.
5. **Lambda Function**: Executes the approved migrations against the database.
6. **Secrets Manager**: Securely stores database credentials.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform 1.0+ installed
- Git installed

## Getting Started

### 1. Clone this repository

```bash
git clone <repository-url>
cd db-migration-pipeline
```

### 2. Set up the database password in AWS Secrets Manager

Run the provided setup script to create a secure password in AWS Secrets Manager:

```bash
chmod +x scripts/setup_password_secret.sh
./scripts/setup_password_secret.sh
```

This script creates a secret named `db-migration-admin-password` with a randomly generated secure password.

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Configure variables

Edit `terraform.tfvars` to set the necessary variables:

- `aws_region`
- `project_name`
- `environment`
- `db_password_secret_name` (if you used a different name in step 2)

### 5. Apply Terraform configuration

```bash
terraform apply
```

### 5. Set up the CodeCommit repository

Once Terraform has completed, you'll get the CodeCommit repository URL. Clone it locally:

```bash
git clone <codecommit-repository-url>
cd <repository-name>
```

### 6. Add your SQL migration files

Place your SQL migration files in the repository. Follow the naming convention:

```
V001__description.sql
V002__description.sql
...
```

### 7. Submit database changes via PR workflow

- Create a branch: `git checkout -b feature/new-table`
- Add your SQL files: `git add .`
- Commit changes: `git commit -m "Add new customer table"`
- Push changes: `git push origin feature/new-table`
- Create a Pull Request in the AWS CodeCommit console
- After review, merge the PR to trigger the pipeline

## How It Works

1. **PR and Code Review**: Database changes are submitted via PRs for review.
2. **Validation**: CodeBuild validates the SQL syntax without executing it.
3. **Approval**: Manual approval step in the pipeline before changes are executed.
4. **Execution**: Python Lambda function applies the changes to the database.
5. **Tracking**: Migrations are tracked in a `db_migrations` table.

### Lambda Migration Executor

The solution uses a Python Lambda function to execute SQL migrations. This function:

- Retrieves database credentials from AWS Secrets Manager
- Downloads migration files from S3
- Connects to the PostgreSQL database
- Creates a migrations table if it doesn't exist
- Executes migrations that haven't been applied yet
- Records each successful migration with a checksum
- Handles transactions to ensure atomicity

## Security Considerations

- Database is in a private subnet and not directly accessible
- Least privilege IAM permissions throughout the solution
- Database password stored securely in AWS Secrets Manager, not in Terraform state
- Credentials for migration execution stored in AWS Secrets Manager
- Secure communication within VPC
- All database changes tracked and auditable

## Customizing Migrations

The migrations are managed via SQL files in the CodeCommit repository. Each migration file should:

1. Be idempotent where possible
2. Use versioned naming (`V001__name.sql`, `V002__name.sql`, etc.)
3. Include detailed comments explaining the changes

## Troubleshooting

- Check CloudWatch Logs for each component:
  - `/aws/codebuild/<project-name>-db-migration-build`
  - `/aws/lambda/<project-name>-db-migration-executor`
- Verify security group rules to ensure components can communicate
- Check event triggers between CodeCommit and CodePipeline

## Maintenance

- Regularly update dependencies in Terraform
- Monitor pipeline executions for failures
- Consider implementing database backups before migrations

## License

[Add your license information here]