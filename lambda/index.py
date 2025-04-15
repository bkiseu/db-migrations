import os
import json
import boto3
import psycopg2
import logging
import hashlib
import zipfile
import tempfile
from pathlib import Path

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
secrets_client = boto3.client('secrets_manager')
s3_client = boto3.client('s3')
codepipeline_client = boto3.client('codepipeline')

def get_database_credentials():
    """Retrieve database credentials from AWS Secrets Manager"""
    try:
        secret_id = os.environ['DB_CREDENTIALS_SECRET_ARN']
        response = secrets_client.get_secret_value(SecretId=secret_id)
        secret_string = response['SecretString']
        credentials = json.loads(secret_string)
        return credentials
    except Exception as e:
        logger.error(f"Error retrieving database credentials: {str(e)}")
        raise Exception(f"Failed to retrieve database credentials: {str(e)}")

def connect_to_database(credentials):
    """Connect to the PostgreSQL database"""
    try:
        # Always connect to the primary (writer) instance for migrations
        conn = psycopg2.connect(
            host=credentials['host'],  # This is the primary/writer endpoint
            port=credentials['port'],
            dbname=credentials['dbname'],
            user=credentials['username'],
            password=credentials['password']
        )
        conn.autocommit = False
        return conn
    except Exception as e:
        logger.error(f"Error connecting to database: {str(e)}")
        raise Exception(f"Failed to connect to database: {str(e)}")

def calculate_checksum(content):
    """Calculate MD5 checksum of file content"""
    return hashlib.md5(content.encode('utf-8')).hexdigest()

def download_migration_files(bucket, key):
    """Download and extract migration files from S3"""
    try:
        logger.info(f"Downloading migration package from s3://{bucket}/{key}")
        
        # Create a temporary directory to store files
        with tempfile.TemporaryDirectory() as tmp_dir:
            # Download the artifact zip file
            zip_path = f"{tmp_dir}/artifact.zip"
            s3_client.download_file(bucket, key, zip_path)
            
            # Extract the zip file
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(tmp_dir)
            
            # Read the metadata file to get the list of migrations
            metadata_path = f"{tmp_dir}/migrations-metadata.json"
            with open(metadata_path, 'r') as f:
                metadata = json.load(f)
            
            # Read each migration file
            migrations = []
            for file_path in metadata['migrationFiles']:
                base_name = Path(file_path).name
                full_path = f"{tmp_dir}/{base_name}"
                
                if not os.path.exists(full_path):
                    full_path = f"{tmp_dir}/migrations/{base_name}"
                
                with open(full_path, 'r') as f:
                    content = f.read()
                
                migrations.append({
                    'filename': base_name,
                    'content': content,
                    'checksum': calculate_checksum(content)
                })
            
            return migrations
    
    except Exception as e:
        logger.error(f"Error downloading migration files: {str(e)}")
        raise Exception(f"Failed to download migration files: {str(e)}")

def execute_migrations(conn, migrations):
    """Execute SQL migrations in the database"""
    logger.info(f"Found {len(migrations)} migration files to execute")
    cursor = conn.cursor()
    
    try:
        # Start a transaction
        cursor.execute("BEGIN")
        
        # Create migrations table if it doesn't exist
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS db_migrations (
                id SERIAL PRIMARY KEY,
                filename VARCHAR(255) NOT NULL UNIQUE,
                applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                checksum VARCHAR(255),
                execution_time INTEGER
            )
        """)
        
        # Get already applied migrations
        cursor.execute("SELECT filename FROM db_migrations")
        applied_migrations = [row[0] for row in cursor.fetchall()]
        
        # Execute each migration file that hasn't been applied yet
        for migration in migrations:
            filename = migration['filename']
            
            # Skip if migration already applied
            if filename in applied_migrations:
                logger.info(f"Migration {filename} already applied, skipping")
                continue
            
            logger.info(f"Executing migration: {filename}")
            
            # Execute the SQL script
            cursor.execute(migration['content'])
            
            # Record the migration in the db_migrations table
            cursor.execute(
                "INSERT INTO db_migrations (filename, checksum) VALUES (%s, %s)",
                (filename, migration['checksum'])
            )
            
            logger.info(f"Migration {filename} completed successfully")
        
        # Commit the transaction
        conn.commit()
        logger.info("All migrations completed successfully")
        
    except Exception as e:
        # Rollback the transaction on error
        conn.rollback()
        logger.error(f"Error executing migrations: {str(e)}")
        raise Exception(f"Migration execution failed: {str(e)}")
    
    finally:
        cursor.close()

def handler(event, context):
    """Lambda handler function"""
    logger.info("Starting database migration execution")
    logger.info(f"Event: {json.dumps(event)}")
    
    conn = None
    job_id = None
    
    try:
        # Extract information from the CodePipeline event
        if 'CodePipeline.job' in event:
            job_id = event['CodePipeline.job']['id']
            artifact_data = event['CodePipeline.job']['data']['inputArtifacts'][0]
            s3_location = artifact_data['location']['s3Location']
            bucket_name = s3_location['bucketName']
            object_key = s3_location['objectKey']
            
            # Download migration files from S3
            migrations = download_migration_files(bucket_name, object_key)
            
            # Get database credentials
            credentials = get_database_credentials()
            
            # Connect to the database
            conn = connect_to_database(credentials)
            
            # Execute migrations
            execute_migrations(conn, migrations)
            
            # Put job success result
            codepipeline_client.put_job_success_result(jobId=job_id)
            
            return {
                'statusCode': 200,
                'body': json.dumps('Migrations executed successfully')
            }
        else:
            logger.error("Invalid event format, expected CodePipeline job")
            raise Exception("Invalid event format, expected CodePipeline job")
            
    except Exception as e:
        logger.error(f"Error: {str(e)}")
        
        # Put job failure result if this was triggered by CodePipeline
        if job_id:
            codepipeline_client.put_job_failure_result(
                jobId=job_id,
                failureDetails={
                    'message': str(e),
                    'type': 'JobFailed',
                    'externalExecutionId': context.aws_request_id
                }
            )
        
        raise e
    
    finally:
        # Close database connection
        if conn:
            conn.close()