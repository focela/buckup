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

# Get the directory containing this script to source env.sh reliably
script_dir=$(dirname "$0")
. "${script_dir}/env.sh"

# Outputs timestamped info message to stdout
log_info() {
  printf '[INFO] %s\n' "$*"
}

# Outputs timestamped warning message to stderr
log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

# Outputs timestamped error message to stderr
log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Removes temp file on script exit; assumes local_file var set by upload logic
cleanup_temp_files() {
  if [ -n "${local_file:-}" ] && [ -f "${local_file}" ]; then
    log_info "Cleaning up temporary file: ${local_file}"
    rm -f "${local_file}" || log_warn "Failed to remove temporary file"
  fi
}

trap cleanup_temp_files EXIT

# Creates gzipped tar archive; assumes BACKUP_FOLDER exists and is readable
log_info "Creating backup of ${BACKUP_FILE_NAME}"
backup_source="${BACKUP_FOLDER}"
if ! tar -czf "${BACKUP_FILE_NAME}.tar.gz" -C "${backup_source}" .; then
  log_error "Failed to create backup archive from ${backup_source}"
  exit 1
fi

# ISO timestamp enables chronological sorting in S3 bucket listings
backup_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE_NAME}_${backup_timestamp}"

# Encrypts archive if PASSPHRASE set; deletes plaintext to prevent exposure
if [ -n "${PASSPHRASE:-}" ]; then
  log_info "Encrypting backup with GPG"
  if ! printf '%s\n' "${PASSPHRASE}" | gpg --symmetric --batch --yes --cipher-algo AES256 \
    --passphrase-fd 0 "${BACKUP_FILE_NAME}.tar.gz"; then
    log_error "Failed to encrypt backup with GPG"
    exit 1
  fi
  # Deletes unencrypted file after successful encryption
  rm -f "${BACKUP_FILE_NAME}.tar.gz"
  local_file="${BACKUP_FILE_NAME}.tar.gz.gpg"
  s3_uri="${s3_uri_base}.tar.gz.gpg"
else
  local_file="${BACKUP_FILE_NAME}.tar.gz"
  s3_uri="${s3_uri_base}.tar.gz"
fi

# Retries S3 upload with exponential backoff; fails after 3 attempts
log_info "Uploading backup to S3 bucket: ${S3_BUCKET}"
upload_retry_count=0
upload_max_retries=3
while [ "${upload_retry_count}" -lt "${upload_max_retries}" ]; do
  upload_success=false
  if [ -n "${S3_ENDPOINT_ARG}" ]; then
    if aws "${S3_ENDPOINT_ARG}" "${S3_ENDPOINT}" s3 cp "${local_file}" "${s3_uri}"; then
      upload_success=true
    fi
  else
    if aws s3 cp "${local_file}" "${s3_uri}"; then
      upload_success=true
    fi
  fi
  if [ "${upload_success}" = "true" ]; then
    break
  fi
  upload_retry_count=$((upload_retry_count + 1))
  if [ "${upload_retry_count}" -lt "${upload_max_retries}" ]; then
    log_warn "Upload attempt ${upload_retry_count} failed, retrying"
    sleep $((upload_retry_count * 2))
  else
    log_error "Failed to upload backup to S3 after ${upload_max_retries} attempts"
    exit 1
  fi
done

log_info "Backup uploaded to: ${s3_uri}"

# Deletes S3 objects older than BACKUP_KEEP_DAYS; skips if var unset
if [ -n "${BACKUP_KEEP_DAYS:-}" ]; then
  log_info "Cleaning up backups older than ${BACKUP_KEEP_DAYS} days"
  
  # Calculates cutoff date using epoch time; tries GNU then BSD date syntax
  retention_seconds=$((86400 * BACKUP_KEEP_DAYS))
  current_epoch=$(date +%s)
  cutoff_epoch=$((current_epoch - retention_seconds))
  cutoff_date=$(date -d "@${cutoff_epoch}" +%Y-%m-%d 2>/dev/null || \
    date -r "${cutoff_epoch}" +%Y-%m-%d 2>/dev/null || \
    { log_error "Failed to calculate cutoff date with both GNU and BSD date commands"; exit 1; })
  
  # Converts to ISO format for AWS CLI timestamp comparison
  cutoff_iso="${cutoff_date}T00:00:00.000Z"
  backups_query="Contents[?LastModified<='${cutoff_iso}'].{Key: Key}"

  # Queries S3 for objects matching prefix and older than cutoff date
  log_info "Finding old backups in S3 bucket: ${S3_BUCKET}"
  if [ -n "${S3_ENDPOINT_ARG}" ]; then
    old_backups_list=$(aws "${S3_ENDPOINT_ARG}" "${S3_ENDPOINT}" s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --query "${backups_query}" \
      --output text)
  else
    old_backups_list=$(aws s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --query "${backups_query}" \
      --output text)
  fi

  # Iterates through object keys and deletes each; continues on delete errors
  if [ -n "${old_backups_list}" ] && [ "${old_backups_list}" != "None" ]; then
    log_info "Deleting old backups"
    printf '%s\n' "${old_backups_list}" | while IFS= read -r backup_key; do
      if [ -n "${backup_key}" ] && [ "${backup_key}" != "None" ]; then
        log_info "Removing old backup: ${backup_key}"
        if [ -n "${S3_ENDPOINT_ARG}" ]; then
          if ! aws "${S3_ENDPOINT_ARG}" "${S3_ENDPOINT}" s3 rm "s3://${S3_BUCKET}/${backup_key}"; then
            log_warn "Failed to remove backup: ${backup_key}"
          fi
        else
          if ! aws s3 rm "s3://${S3_BUCKET}/${backup_key}"; then
            log_warn "Failed to remove backup: ${backup_key}"
          fi
        fi
      fi
    done
    log_info "Cleanup completed"
  else
    log_info "No old backups to remove"
  fi
fi

log_info "Backup completed"
