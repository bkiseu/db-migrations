#!/bin/bash
# Script to build the Lambda deployment package

# Setup directories
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/build"
LAMBDA_SRC_DIR="${ROOT_DIR}/lambda"
PACKAGE_DIR="${BUILD_DIR}/lambda_package"

# Create build directories
mkdir -p ${BUILD_DIR}
mkdir -p ${PACKAGE_DIR}

# Copy Lambda source code
cp ${LAMBDA_SRC_DIR}/index.py ${PACKAGE_DIR}/
cp ${LAMBDA_SRC_DIR}/requirements.txt ${PACKAGE_DIR}/

# Install dependencies
pip install -r ${LAMBDA_SRC_DIR}/requirements.txt -t ${PACKAGE_DIR}

# Create zip file
cd ${PACKAGE_DIR}
zip -r ${BUILD_DIR}/lambda_function.zip ./*

echo "Lambda package created at ${BUILD_DIR}/lambda_function.zip"
