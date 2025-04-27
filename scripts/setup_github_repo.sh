#!/bin/bash
# Script to set up a GitHub repository with initial migrations

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MIGRATIONS_DIR="${ROOT_DIR}/migrations"
GITHUB_REPO="$1"  # GitHub repo in format owner/repo

if [ -z "$GITHUB_REPO" ]; then
  echo "Error: GitHub repository must be provided"
  echo "Usage: $0 <owner/repo>"
  exit 1
fi

echo "Setting up GitHub repository with initial migrations..."

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Initialize git repository
git init

# Create migrations directory
mkdir -p migrations

# Copy the SQL migration files if they exist
cp -r "${MIGRATIONS_DIR}"/*.sql migrations/ 2>/dev/null || true

# If no migrations exist, create sample files
if [ ! "$(ls -A migrations)" ]; then
  echo "Creating sample migration files..."
  
  # Create V001__initial_schema.sql
  cat > "migrations/V001__initial_schema.sql" << 'EOF'
-- V001__initial_schema.sql
-- Initial database schema migration

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create users table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) NOT NULL UNIQUE,
    username VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create profile table with reference to users
CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bio TEXT,
    avatar_url VARCHAR(255),
    location VARCHAR(100),
    website VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_user_profile UNIQUE (user_id)
);

-- Create categories table
CREATE TABLE IF NOT EXISTS categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create products table
CREATE TABLE IF NOT EXISTS products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    category_id UUID REFERENCES categories(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(10, 2) NOT NULL,
    stock_quantity INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_username ON users(username);

-- Add comments
COMMENT ON TABLE users IS 'Table storing user account information';
COMMENT ON TABLE profiles IS 'Table storing user profile information';
COMMENT ON TABLE categories IS 'Product categories';
COMMENT ON TABLE products IS 'Products available for purchase';
EOF

  # Create V002__add_orders_table.sql
  cat > "migrations/V002__add_orders_table.sql" << 'EOF'
-- V002__add_orders_table.sql
-- Add orders schema

-- Create order status enum type
CREATE TYPE order_status AS ENUM (
    'pending',
    'processing',
    'shipped',
    'delivered',
    'cancelled',
    'refunded'
);

-- Create payment method enum type
CREATE TYPE payment_method AS ENUM (
    'credit_card',
    'debit_card',
    'paypal',
    'bank_transfer',
    'crypto'
);

-- Create orders table
CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status order_status NOT NULL DEFAULT 'pending',
    total_amount DECIMAL(12, 2) NOT NULL,
    payment_method payment_method,
    shipping_address_line1 VARCHAR(255) NOT NULL,
    shipping_address_line2 VARCHAR(255),
    shipping_city VARCHAR(100) NOT NULL,
    shipping_state VARCHAR(100),
    shipping_postal_code VARCHAR(20) NOT NULL,
    shipping_country VARCHAR(100) NOT NULL,
    shipping_fee DECIMAL(10, 2) DEFAULT 0.00,
    tax_amount DECIMAL(10, 2) DEFAULT 0.00,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create order_items table
CREATE TABLE IF NOT EXISTS order_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10, 2) NOT NULL,
    total_price DECIMAL(12, 2) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_order_product UNIQUE (order_id, product_id)
);

-- Create indexes
CREATE INDEX idx_orders_user ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);
EOF
fi

# Copy the buildspec.yml file
cat > "buildspec.yml" << 'EOF'
version: 0.2

phases:
  install:
    runtime-versions:
      nodejs: 18
    commands:
      - echo Installing required packages
      - apt-get update -y
      - apt-get install -y postgresql-client
      - npm install -g pg
  
  pre_build:
    commands:
      - echo Retrieving database credentials from AWS Secrets Manager
      - DB_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id $DB_CREDENTIALS_SECRET_ARN --query SecretString --output text)
      - DB_HOST=$(echo $DB_CREDENTIALS | jq -r '.host')
      - DB_PORT=$(echo $DB_CREDENTIALS | jq -r '.port')
      - DB_NAME=$(echo $DB_CREDENTIALS | jq -r '.dbname')
      - DB_USER=$(echo $DB_CREDENTIALS | jq -r '.username')
      - DB_PASSWORD=$(echo $DB_CREDENTIALS | jq -r '.password')
      - echo Retrieved database connection information
      
  build:
    commands:
      - echo Starting validation of SQL migration scripts
      - echo "Identifying migration files..."
      - MIGRATION_FILES=$(find migrations -type f -name "*.sql" | sort)
      - |
        if [ -z "$MIGRATION_FILES" ]; then
          echo "No SQL migration files found."
          exit 0
        fi
      
      - echo "Found the following migration files:"
      - echo "$MIGRATION_FILES"
      
      - echo "Validating SQL syntax..."
      - |
        for file in $MIGRATION_FILES; do
          echo "Validating syntax for $file"
          # Use psql to check syntax without executing
          PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "\\set ON_ERROR_STOP on" -f $file -v ON_ERROR_STOP=1 --echo-all --no-psqlrc -c "ROLLBACK;"
          if [ $? -ne 0 ]; then
            echo "Error in SQL file: $file"
            exit 1
          fi
          echo "Syntax validation passed for $file"
        done
      
      - echo "Creating metadata file for execution..."
      - |
        cat > migrations-metadata.json << EOMETA
        {
          "migrationFiles": [
            $(for file in $MIGRATION_FILES; do echo "\"$file\","; done | sed '$s/,$//')
          ],
          "timestamp": "$(date +%Y%m%d%H%M%S)",
          "buildId": "$CODEBUILD_BUILD_ID"
        }
        EOMETA
      
      - echo "SQL validation completed successfully"
  
  post_build:
    commands:
      - echo "Build completed successfully"

artifacts:
  files:
    - migrations/**/*
    - migrations-metadata.json
    - buildspec.yml
  discard-paths: no
EOF

# Create a README with Flyway information
cat > "README.md" << 'EOF'
# Database Migration Repository

This repository contains SQL migration scripts that are applied to the database through a controlled CI/CD pipeline using Flyway.

## How to Add New Migrations

1. Create a new SQL migration file in the `migrations/` directory
2. Follow Flyway's naming convention: `V{number}__{description}.sql` (e.g., `V002__add_orders_table.sql`)
3. Write your SQL statements in the file
4. Commit and push your changes
5. Submit a Pull Request for review
6. After approval, the changes will be automatically applied to the database

## Flyway Migration Best Practices

- Migrations are applied in version order (V001, V002, etc.)
- Each migration runs exactly once
- Use descriptive names in the migration files
- Keep migrations focused on a single logical change
- Test migrations locally before committing

## Migration Pipeline

The migration process:

1. SQL files are validated for syntax
2. A manual approval step is required
3. Flyway applies migrations in a transaction
4. Flyway maintains a schema history table to track applied migrations
EOF

# Add everything to git
git add .
git config --local user.name "Setup Script"
git config --local user.email "setup@example.com"
git commit -m "Initial commit with Flyway migration structure"

echo "Local repository prepared."
echo ""
echo "MANUAL STEPS REQUIRED:"
echo "======================="
echo "1. Create a new GitHub repository at: https://github.com/new"
echo "   - Repository name: ${GITHUB_REPO#*/}"
echo "   - Set visibility as needed (public or private)"
echo ""
echo "2. Push this repository to GitHub:"
echo "   git remote add origin https://github.com/${GITHUB_REPO}.git"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "3. After deploying the AWS infrastructure, go to the AWS console:"
echo "   - Navigate to Developer Tools > Settings > Connections"
echo "   - Find the connection for your pipeline and click 'Update pending connection'"
echo "   - Complete the GitHub authorization process"
echo ""
echo "Files are prepared in: ${TEMP_DIR}"
echo "Remember to keep this directory until you've completed the GitHub setup!"