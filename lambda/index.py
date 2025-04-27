import os
import json
import boto3
import logging
import hashlib
import zipfile
import tempfile
import subprocess
import shutil
from pathlib import Path

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
secrets_client = boto3.client('secrets_manager')
s3_client = boto3.client('s3')
codepipeline_client = boto3.client('codepipeline')

# Flyway constants
FLYWAY_VERSION = "8.5.13"
FLYWAY_FOLDER = f"/tmp/flyway-{FLYWAY_VERSION}"
FLYWAY_BINARY = f"{FLYWAY_FOLDER}/flyway"

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

def setup_flyway():
    """Download and configure Flyway if not already present"""
    if os.path.exists(FLYWAY_BINARY):
        logger.info(f"Flyway already exists at {FLYWAY_BINARY}")
        return
    
    logger.info(f"Setting up Flyway {FLYWAY_VERSION}...")
    
    flyway_url = f"https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/{FLYWAY_VERSION}/flyway-commandline-{FLYWAY_VERSION}-linux-x64.tar.gz"
    tar_file = "/tmp/flyway.tar.gz"
    
    # Download Flyway
    try:
        logger.info(f"Downloading Flyway from {flyway_url}")
        subprocess.run(["curl", "-L", flyway_url, "-o", tar_file], check=True)
        
        # Extract Flyway
        logger.info(f"Extracting Flyway to {FLYWAY_FOLDER}")
        os.makedirs("/tmp/flyway-extract", exist_ok=True)
        subprocess.run(["tar", "-xzf", tar_file, "-C", "/tmp/flyway-extract"], check=True)
        
        # Move to final location
        extracted_dir = f"/tmp/flyway-extract/flyway-{FLYWAY_VERSION}"
        shutil.move(extracted_dir, FLYWAY_FOLDER)
        
        # Make Flyway executable
        os.chmod(FLYWAY_BINARY, 0o755)
        logger.info("Flyway setup complete")
    except Exception as e:
        logger.error(f"Error setting up Flyway: {str(e)}")
        raise Exception(f"Failed to set up Flyway: {str(e)}")

def download_migration_files(bucket, key):
    """Download and extract migration files from S3"""
    try:
        logger.info(f"Downloading migration package from s3://{bucket}/{key}")
        
        # Create a temporary directory to store files
        migrations_dir = "/tmp/migrations"
        os.makedirs(migrations_dir, exist_ok=True)
        
        # Download the artifact zip file
        zip_path = f"/tmp/artifact.zip"
        s3_client.download_file(bucket, key, zip_path)
        
        # Extract the zip file
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall("/tmp")
        
        # Identify SQL migration files and move them to the migrations directory
        for root, dirs, files in os.walk("/tmp"):
            for file in files:
                if file.endswith(".sql") and "V" in file:
                    source_path = os.path.join(root, file)
                    target_path = os.path.join(migrations_dir, file)
                    shutil.copy(source_path, target_path)
                    logger.info(f"Added migration: {file}")
        
        return migrations_dir
    
    except Exception as e:
        logger.error(f"Error downloading migration files: {str(e)}")
        raise Exception(f"Failed to download migration files: {str(e)}")

def execute_migrations(credentials, migrations_dir):
    """Execute database migrations using Flyway"""
    logger.info(f"Executing migrations from {migrations_dir}")
    
    # Set up Flyway
    setup_flyway()
    
    # Create flyway.conf file
    flyway_conf = f"{FLYWAY_FOLDER}/conf/flyway.conf"
    with open(flyway_conf, 'w') as f:
        f.write(f"flyway.url=jdbc:postgresql://{credentials['host']}:{credentials['port']}/{credentials['dbname']}\n")
        f.write(f"flyway.user={credentials['username']}\n")
        f.write(f"flyway.password={credentials['password']}\n")
        f.write("flyway.connectRetries=3\n")
        f.write("flyway.validateOnMigrate=true\n")
        f.write("flyway.baselineOnMigrate=true\n")
        f.write("flyway.locations=filesystem:{migrations_dir}\n".format(migrations_dir=migrations_dir))
    
    # Run Flyway migration
    try:
        logger.info("Starting Flyway migration")
        result = subprocess.run(
            [FLYWAY_BINARY, "migrate", "-locations", f"filesystem:{migrations_dir}"],
            capture_output=True,
            text=True
        )
        
        # Log the output
        logger.info(f"Flyway stdout: {result.stdout}")
        if result.stderr:
            logger.warning(f"Flyway stderr: {result.stderr}")
        
        # Check return code
        if result.returncode != 0:
            raise Exception(f"Flyway migration failed with return code {result.returncode}")
        
        logger.info("Flyway migration completed successfully")
    except subprocess.SubprocessError as e:
        logger.error(f"Error executing Flyway: {str(e)}")
        raise Exception(f"Failed to execute Flyway: {str(e)}")

def handler(event, context):
    """Lambda handler function"""
    logger.info("Starting database migration execution with Flyway")
    logger.info(f"Event: {json.dumps(event)}")
    
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
            migrations_dir = download_migration_files(bucket_name, object_key)
            
            # Get database credentials
            credentials = get_database_credentials()
            
            # Execute migrations using Flyway
            execute_migrations(credentials, migrations_dir)
            
            # Put job success result
            codepipeline_client.put_job_success_result(jobId=job_id)
            
            return {
                'statusCode': 200,
                'body': json.dumps('Migrations executed successfully using Flyway')
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
