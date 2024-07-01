#!/bin/bash

set -e  # Exit on any error

# Git Operations
git pull origin master
git add .
git commit -m "added files"
git push origin master --force
git pull origin master

# Set variables
REPO_OWNER="developer-bagic-02"
REPO_NAME="demo2"
GITHUB_API="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME"
BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M)  # Backup timestamp in the format YYYYMMDDHHMM

# Get the latest commit SHA from the main branch
LATEST_COMMIT_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" $GITHUB_API/commits/master | jq -r .sha)
echo "Latest commit SHA: $LATEST_COMMIT_SHA"

# Get the parent commit SHA
PARENT_COMMIT_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" $GITHUB_API/commits/$LATEST_COMMIT_SHA | jq -r .parents[0].sha)
echo "Parent commit SHA: $PARENT_COMMIT_SHA"

# Get the list of changed files
CHANGED_FILES=$(curl -s -H "Authorization: token $GITHUB_TOKEN" $GITHUB_API/compare/$PARENT_COMMIT_SHA...$LATEST_COMMIT_SHA | jq -r '.files[].filename')
echo "Changed files:"
echo "$CHANGED_FILES"

# AWS instance details
aws_ip="65.0.127.255"
aws_user="ec2-user"
service_dir="/opt/tomcat/webapps/OtpProject-0.0.1-SNAPSHOT/WEB-INF/classes"
backup_dir="/opt/tomcat/backup/${BACKUP_TIMESTAMP}"
pem_file="/g/workspace/demo-clover.pem"
tomcat_bin_dir="/opt/tomcat/bin"

# Ensure PEM file has the correct permissions
chmod 400 $pem_file

# Check for Maven installation
if ! command -v mvn &> /dev/null; then
  echo "Maven not found. Please install Maven."
  exit 1
fi

# Clean and compile the project
mvn clean compile

# Create a directory for the patch
mkdir -p patch

# Iterate over each modified Java file
for file in $CHANGED_FILES; do
  echo "Processing file: $file"

  # Convert Java source path to class path
  class_file=$(echo $file | sed 's|src/main/java/||' | sed 's/\.java$/.class/')
  class_file_path="/g/workspace/WebDemo/target/classes/$class_file"

  if [ -f "$class_file_path" ]; then
    echo "Found compiled class file: $class_file_path"
    mkdir -p $(dirname "patch/$class_file")
    cp "$class_file_path" "patch/$class_file"
  else
    echo "Compiled class file not found for: $file"
  fi
done

echo "Patch created with modified class files."

# Create a backup directory on the AWS instance
ssh -i $pem_file ${aws_user}@${aws_ip} "mkdir -p $backup_dir"

# Backup existing files on the Tomcat server
for file in $CHANGED_FILES; do
  class_file=$(echo $file | sed 's|src/main/java/||' | sed 's/\.java$/.class/')
  remote_file_path="${service_dir}/${class_file}"
  echo "Backing up file: $remote_file_path"
  ssh -i $pem_file ${aws_user}@${aws_ip} "cp $remote_file_path ${backup_dir}/$(basename $remote_file_path)"
done

echo "Files backed up to $backup_dir."

# Copy files to AWS instance
scp -i $pem_file -r patch/* ${aws_user}@${aws_ip}:${service_dir}

# Restart Tomcat server
ssh -i $pem_file ${aws_user}@${aws_ip} "bash -c 'cd $tomcat_bin_dir && sudo ./shutdown.sh && sleep 5 && sudo ./startup.sh'"
