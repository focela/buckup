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

# Get the directory containing this script to find backup.sh reliably
script_dir=$(dirname "$0")

# Outputs timestamped info message to stdout
log_info() {
  printf '[INFO] %s\n' "$*"
}

# Outputs timestamped error message to stderr
log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Configures S3v4 signatures for compatible services; required by some
if [ "${S3_S3V4:-}" = "yes" ]; then
  log_info "Configuring AWS CLI for S3v4 signature"
  if ! aws configure set default.s3.signature_version s3v4; then
    log_error "Failed to configure AWS CLI for S3v4 signature"
    exit 1
  fi
  log_info "AWS CLI configured for S3v4 signature"
fi

# Runs once if SCHEDULE unset; starts daemon if set
if [ -z "${SCHEDULE:-}" ]; then
  log_info "Executing one-time backup"
  if ! sh "${script_dir}/backup.sh"; then
    log_error "One-time backup execution failed"
    exit 1
  fi
  log_info "Backup completed"
else
  # Verifies cronx available before starting scheduler
  if ! command -v cronx >/dev/null 2>&1; then
    log_error "cronx scheduler not found - install required"
    exit 1
  fi
  
  # Replaces shell process with cronx; container runs until stopped
  log_info "Starting scheduled backup with cron expression: ${SCHEDULE}"
  log_info "Backup will run according to schedule using cronx"
  exec cronx "${SCHEDULE}" /bin/sh "${script_dir}/backup.sh"
fi
