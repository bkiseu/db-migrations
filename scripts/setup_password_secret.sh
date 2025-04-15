#!/bin/bash
# Script to create the database password secret in AWS Secrets Manager
# This should be run before applying the Terraform configuration

# Configuration
SECRET_NAME="db-migration-admin-password"
REGION="us-east-1"  # Change to match your AWS region

# Generate a secure random password
PASSWORD_LENGTH=32
DB_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH | tr -dc 'a-zA-Z0-9' | fold -w $PASSWORD_LENGTH | head -n 1)

# Create the secret
aws secretsmanager create-secret \
  --name $SECRET_NAME \
  --description "Database password for RDS instance" \
  --secret-string "{\"password\":\"$DB_PASSWORD\"}" \
  --region $REGION

if [ $? -eq 0 ]; then
  echo "Secret $SECRET_NAME created successfully!"
  echo "You can now apply the Terraform configuration."
else
  echo "Failed to create secret. Please check your AWS credentials and permissions."
  exit 1
fi