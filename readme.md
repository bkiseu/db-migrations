## Migration Management with Flyway

This solution uses [Flyway](https://flywaydb.org/) to manage database migrations:

1. **Version-based Migrations**:
   - Migrations are automatically applied in order based on their version numbers
   - Each migration is applied exactly once
   - Flyway tracks applied migrations in a schema history table

2. **Migration Naming Convention**:
   - Follow Flyway's naming convention: `V{number}__{description}.sql`
   - Example: `V001__initial_schema.sql`, `V002__add_users_table.sql`
   - Version numbers should be sequential

3. **Execution Process**:
   - The Lambda function downloads Flyway at runtime
   - Migration files are extracted from the CodePipeline artifact
   - Flyway applies all pending migrations in order
   - The history table tracks which migrations have been applied

4. **Benefits of Flyway**:
   - Reliable, transaction-based migrations
   - Automatic schema history tracking
   - Support for baseline migrations
   - Industry-standard approach to database versioning## Lambda Deployment

The Lambda function that executes database migrations is built and deployed using Terraform:

1. **Lambda Layer**:
   - Dependencies (like `psycopg2` and `boto3`) are installed in a Lambda Layer
   - The layer is automatically rebuilt when `requirements.txt` changes
   - This approach separates the function code from its dependencies

2. **Lambda Function**:
   - Connects to the primary (writer) database instance
   - Executes SQL migrations in a transactional manner
   - Records completed migrations to prevent duplicate execution
   - Deployed with VPC access to reach the database

3. **Monitoring**:
   - CloudWatch logs are configured with appropriate retention
   - CloudWatch dashboard provides visibility into the migration process
   - Alarms notify administrators of execution failures

You can view logs and execution statistics in the CloudWatch dashboard that's created automatically.# Database Migration Pipeline

This repository contains Terraform configurations for setting up a secure database migration pipeline using AWS CodePipeline, CodeCommit, and CodeDeploy. The solution ensures that database changes are only applied through a controlled PR process.

## Architecture

![Architecture Diagram](https://via.placeholder.com/800x500)

The solution includes:

1. **VPC with Private Subnets**: RDS instances are deployed in private subnets (10.0.201.0/24, 10.0.202.0/24, 10.0.203.0/24), inaccessible from the internet.
2. **RDS with Writer/Reader Setup**: 
   - Primary instance for write operations and database changes
   - Read replica for scaling read operations (in staging/production environments)
3. **GitHub Repository**: Stores SQL migration scripts with version control.
4. **AWS CodeStar Connection**: Securely integrates GitHub with AWS services.
5. **CodePipeline**: Orchestrates the workflow from code commit to deployment.
6. **CodeBuild**: Validates the SQL scripts before deployment.
7. **Lambda Function with Flyway**: Executes the approved migrations using Flyway.
8. **Secrets Manager**: Securely stores database credentials.

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
- `github_repository` (format: "owner/repo")
- `github_branch` (default: "main")

### 5. Create a GitHub repository for migrations

Create a GitHub repository that will store your migration files and prepare it with the included script:

```bash
chmod +x scripts/setup_github_repo.sh
./scripts/setup_github_repo.sh your-org/your-repo-name
```

Follow the instructions provided by the script to complete the GitHub repository setup.

### 6. Apply Terraform configuration

```bash
terraform apply
```

### 7. Complete the GitHub connection

After deploying the infrastructure:

1. Go to the AWS Console
2. Navigate to Developer Tools > Settings > Connections
3. Find the connection for your pipeline (name will match your project name)
4. Click "Update pending connection"
5. Follow the steps to authorize the connection with GitHub

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

### 8. Submit database changes via GitHub Pull Requests

For each database change:

1. Clone your GitHub migrations repository:
   ```bash
   git clone https://github.com/your-org/your-repo-name.git
   cd your-repo-name
   ```

2. Create a branch for your changes:
   ```bash
   git checkout -b feature/new-table
   ```

3. Add your SQL migration file:
   ```bash
   # Create your migration file
   vim migrations/V003__add_new_table.sql
   
   # Add it to git
   git add migrations/V003__add_new_table.sql
   git commit -m "Add new table for customer data"
   git push --set-upstream origin feature/new-table
   ```

4. Create a Pull Request in the GitHub web interface

5. After review and approval, merge the PR to trigger the pipeline

6. Monitor the pipeline execution in the AWS CodePipeline console

7. Approve the changes in the manual approval stage

The Lambda function will then apply the approved changes to the database using Flyway. -m "Add new table for customer data"
   git push --set-upstream origin feature/new-table
   ```

4. Create a Pull Request in the AWS CodeCommit console

5. After review and approval, merge the PR to trigger the pipeline

6. Monitor the pipeline execution in the AWS CodePipeline console

7. Approve the changes in the manual approval stage

The Lambda function will then apply the approved changes to the database.

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

# Testing pipeline trigger try 4
