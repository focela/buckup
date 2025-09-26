#!/bin/sh

# Copyright 2025 Focela Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu
set -o pipefail

# Outputs timestamped error message to stderr
log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Validates S3_BUCKET exists; terminates process if unset
if [ -z "${S3_BUCKET:-}" ]; then
  log_error "S3_BUCKET environment variable is required but not set"
  exit 1
fi

# Validates BACKUP_FOLDER path exists; terminates if unset
if [ -z "${BACKUP_FOLDER:-}" ]; then
  log_error "BACKUP_FOLDER environment variable is required but not set"
  exit 1
fi

# Validates backup filename prefix; terminates if unset
if [ -z "${BACKUP_FILE_NAME:-}" ]; then
  log_error "BACKUP_FILE_NAME environment variable is required but not set"
  exit 1
fi

# Sets endpoint flag for S3-compatible services; empty for AWS S3
if [ -z "${S3_ENDPOINT:-}" ]; then
  export S3_ENDPOINT_ARG=""
else
  export S3_ENDPOINT_ARG="--endpoint-url"
fi
export S3_ENDPOINT

# Maps S3 credentials to AWS CLI vars; overrides IAM role if set
if [ -n "${S3_ACCESS_KEY_ID:-}" ]; then
  export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
fi

if [ -n "${S3_SECRET_ACCESS_KEY:-}" ]; then
  export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
fi

# Validates region setting; required for AWS CLI operation
if [ -z "${S3_REGION:-}" ]; then
  log_error "S3_REGION environment variable is required but not set"
  exit 1
fi
export AWS_DEFAULT_REGION="${S3_REGION}"

# Sets S3 object prefix; defaults to 'backups' if unspecified
S3_PREFIX="${S3_PREFIX:-backups}"
export S3_PREFIX
