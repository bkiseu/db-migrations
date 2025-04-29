import os
import json
import boto3
import logging
import hashlib
import zipfile
import tempfile
import subprocess
import shutil
import traceback
import urllib.request
import tarfile
from pathlib import Path

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
secrets_client = boto3.client('secretsmanager')
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
    
    # Download Flyway using urllib instead of curl
    try:
        logger.info(f"Downloading Flyway from {flyway_url}")
        urllib.request.urlretrieve(flyway_url, tar_file)
        
        # Extract Flyway using tarfile module
        logger.info(f"Extracting Flyway to {FLYWAY_FOLDER}")
        os.makedirs("/tmp/flyway-extract", exist_ok=True)
        
        with tarfile.open(tar_file, "r:gz") as tar:
            tar.extractall(path="/tmp/flyway-extract")
        
        # Move to final location
        extracted_dir = f"/tmp/flyway-extract/flyway-{FLYWAY_VERSION}"
        if os.path.exists(extracted_dir):
            shutil.move(extracted_dir, FLYWAY_FOLDER)
        else:
            # List the directories to see what's there
            extract_contents = os.listdir("/tmp/flyway-extract")
            logger.info(f"Extracted contents: {extract_contents}")
            
            # Try to find a directory with flyway in the name
            flyway_dirs = [d for d in extract_contents if 'flyway' in d.lower()]
            if flyway_dirs:
                shutil.move(f"/tmp/flyway-extract/{flyway_dirs[0]}", FLYWAY_FOLDER)
            else:
                raise Exception(f"Could not find Flyway directory in extracted contents: {extract_contents}")
        
        # Make Flyway executable
        os.chmod(FLYWAY_BINARY, 0o755)
        logger.info("Flyway setup complete")
        
        # List the Flyway directory to debug
        logger.info(f"Listing Flyway directory contents:")
        if os.path.exists(FLYWAY_FOLDER):
            logger.info(f"Flyway folder contents: {os.listdir(FLYWAY_FOLDER)}")
            if os.path.exists(f"{FLYWAY_FOLDER}/conf"):
                logger.info(f"Flyway conf folder contents: {os.listdir(f'{FLYWAY_FOLDER}/conf')}")
        
        # Test the Flyway binary
        if os.path.exists(FLYWAY_BINARY):
            logger.info("Testing Flyway binary...")
            try:
                test_result = subprocess.run([FLYWAY_BINARY, "-v"], capture_output=True, text=True)
                logger.info(f"Flyway version output: {test_result.stdout}")
                if test_result.stderr:
                    logger.warning(f"Flyway version stderr: {test_result.stderr}")
            except Exception as e:
                logger.error(f"Error running Flyway version check: {str(e)}")
                
            # Check to ensure flyway is executable
            logger.info(f"Checking Flyway permissions: {oct(os.stat(FLYWAY_BINARY).st_mode)}")
        else:
            logger.error(f"Flyway binary not found at {FLYWAY_BINARY}")
            # Try to find the flyway binary in the extracted folder
            for root, dirs, files in os.walk("/tmp"):
                for file in files:
                    if file == "flyway":
                        logger.info(f"Found flyway binary at {os.path.join(root, file)}")
        
    except Exception as e:
        logger.error(f"Error setting up Flyway: {str(e)}")
        logger.error(traceback.format_exc())
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
        
        # Log the contents of the zip file
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            logger.info(f"Zip file contents: {zip_ref.namelist()}")
            
            # Process files while ensuring no duplicates
            processed_files = set()
            migrations = []
            
            for file_info in zip_ref.infolist():
                if file_info.is_dir():
                    continue
                    
                # Extract just the filename from the path
                filename = os.path.basename(file_info.filename)
                
                # Only process SQL files
                if not filename.endswith('.sql'):
                    continue
                    
                # Skip if already processed this filename
                if filename in processed_files:
                    logger.warning(f"Skipping duplicate file: {filename}")
                    continue
                    
                logger.info(f"Extracting file: {filename} from {file_info.filename}")
                
                # Extract and read the file
                with zip_ref.open(file_info) as f:
                    content = f.read().decode('utf-8')
                    
                target_path = os.path.join(migrations_dir, filename)
                
                # Save the file
                with open(target_path, 'w') as f:
                    f.write(content)
                    
                processed_files.add(filename)
                migrations.append({
                    'filename': filename,
                    'path': target_path,
                    'content': content
                })
        
        return migrations_dir, migrations
    
    except Exception as e:
        logger.error(f"Error downloading migration files: {str(e)}")
        logger.error(traceback.format_exc())
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
        f.write(f"flyway.locations=filesystem:{migrations_dir}\n")
    
    # Run Flyway migration
    try:
        logger.info("Starting Flyway migration")
        # Try different command formats for Flyway
        
        # Option 1: Use -locations as a separate argument
        cmd = [FLYWAY_BINARY, "migrate", "-locations", f"filesystem:{migrations_dir}"]
        logger.info(f"Trying command: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        # If failed, try Option 2: Use locations= format
        if result.returncode != 0 and "Invalid argument: -locations" in result.stderr:
            cmd = [FLYWAY_BINARY, "migrate", f"-locations=filesystem:{migrations_dir}"]
            logger.info(f"Trying alternative command: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=True, text=True)
        
        # If still failed, try Option 3: Let Flyway use the conf file only
        if result.returncode != 0 and "Invalid argument" in result.stderr:
            cmd = [FLYWAY_BINARY, "migrate"]
            logger.info(f"Trying simplified command: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=True, text=True)
        
        # Log the output
        logger.info(f"Flyway stdout: {result.stdout}")
        if result.stderr:
            logger.warning(f"Flyway stderr: {result.stderr}")
        
        # Check return code
        if result.returncode != 0:
            raise Exception(f"Flyway migration failed with return code {result.returncode}: {result.stderr}")
        
        logger.info("Flyway migration completed successfully")
        return True
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
            logger.info(f"Processing CodePipeline job: {job_id}")
            
            artifact_data = event['CodePipeline.job']['data']['inputArtifacts'][0]
            s3_location = artifact_data['location']['s3Location']
            bucket_name = s3_location['bucketName']
            object_key = s3_location['objectKey']
            
            # Download migration files from S3
            migrations_dir, migrations = download_migration_files(bucket_name, object_key)
            logger.info(f"Downloaded {len(migrations)} migration files to {migrations_dir}")
            
            # List the migrations that will be applied
            for migration in migrations:
                logger.info(f"Prepared migration: {migration['filename']}")
            
            # Get database credentials
            credentials = get_database_credentials()
            logger.info("Retrieved database credentials")
            
            # Execute migrations using Flyway
            execute_migrations(credentials, migrations_dir)
            
            # Report success to CodePipeline
            logger.info(f"Reporting success for job: {job_id}")
            codepipeline_client.put_job_success_result(jobId=job_id)
            
            return {
                'statusCode': 200,
                'body': json.dumps('Migrations executed successfully using Flyway')
            }
        else:
            logger.error("Event is not a CodePipeline job")
            return {
                'statusCode': 400,
                'body': json.dumps('Event is not a CodePipeline job')
            }
            
    except Exception as e:
        logger.error(f"Error: {str(e)}")
        logger.error(traceback.format_exc())
        
        # Put job failure result if this was triggered by CodePipeline
        if job_id:
            logger.info(f"Reporting failure for job: {job_id}")
            codepipeline_client.put_job_failure_result(
                jobId=job_id,
                failureDetails={
                    'message': str(e),
                    'type': 'JobFailed',
                    'externalExecutionId': context.aws_request_id
                }
            )
        
        # Re-raise to ensure Lambda marks this as a failure
        raise e