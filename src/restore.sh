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

# Outputs timestamped error message to stderr
log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Removes temp files on exit; handles both encrypted and plain archives
cleanup_temp_files() {
  if [ -n "${backup_file:-}" ] && [ -f "${backup_file}" ]; then
    log_info "Cleaning up temporary file: ${backup_file}"
    rm -f "${backup_file}" || log_info "Failed to remove ${backup_file}"
  fi
  if [ -n "${encrypted_backup_file:-}" ] && [ -f "${encrypted_backup_file}" ]; then
    log_info "Cleaning up encrypted backup file: ${encrypted_backup_file}"
    rm -f "${encrypted_backup_file}" || log_info "Failed to remove ${encrypted_backup_file}"
  fi
}

trap cleanup_temp_files EXIT

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

# Sets file extension based on encryption; affects download path
if [ -z "${PASSPHRASE:-}" ]; then
  backup_file_extension=".tar.gz"
else
  backup_file_extension=".tar.gz.gpg"
fi

# Uses provided timestamp or discovers latest; assumes ISO format
if [ "$#" -eq 1 ]; then
  restore_timestamp="${1}"
  backup_key_suffix="${BACKUP_FILE_NAME}_${restore_timestamp}${backup_file_extension}"
  log_info "Restoring backup with timestamp: ${restore_timestamp}"
else
  # Sorts ISO timestamps lexicographically for chronological order
  log_info "Finding latest backup in S3"
  if [ -n "${S3_ENDPOINT_ARG}" ]; then
    backup_listing=$(aws "${S3_ENDPOINT_ARG}" "${S3_ENDPOINT}" s3 ls "${s3_uri_base}/${BACKUP_FILE_NAME}" || true)
  else
    backup_listing=$(aws s3 ls "${s3_uri_base}/${BACKUP_FILE_NAME}" || true)
  fi
  
  # Terminates if no backups exist in bucket
  if [ -z "${backup_listing}" ]; then
    log_error "No backups found in S3 bucket: ${S3_BUCKET}"
    exit 1
  fi
  
  # Extracts newest backup key from sorted S3 listing
  backup_key_suffix=$(printf '%s\n' "${backup_listing}" | \
    sort | tail -n 1 | awk '{print $NF}' | sed "s|^${S3_PREFIX}/||")
  
  if [ -z "${backup_key_suffix}" ]; then
    log_error "Failed to determine latest backup from S3 listing"
    exit 1
  fi
  log_info "Found latest backup: ${backup_key_suffix}"
fi

# Downloads backup archive from S3; terminates on network failure
log_info "Downloading backup from S3: ${backup_key_suffix}"
downloaded_backup_file="${BACKUP_FILE_NAME}${backup_file_extension}"
if [ -n "${S3_ENDPOINT_ARG}" ]; then
  if ! aws "${S3_ENDPOINT_ARG}" "${S3_ENDPOINT}" s3 cp "${s3_uri_base}/${backup_key_suffix}" "${downloaded_backup_file}"; then
    log_error "Failed to download backup from S3: ${s3_uri_base}/${backup_key_suffix}"
    exit 1
  fi
else
  if ! aws s3 cp "${s3_uri_base}/${backup_key_suffix}" "${downloaded_backup_file}"; then
    log_error "Failed to download backup from S3: ${s3_uri_base}/${backup_key_suffix}"
    exit 1
  fi
fi

# Decrypts archive if PASSPHRASE set; creates plaintext tar file
if [ -n "${PASSPHRASE:-}" ]; then
  log_info "Decrypting backup with GPG"
  encrypted_backup_file="${downloaded_backup_file}"
  backup_file="${BACKUP_FILE_NAME}.tar.gz"
  
  if ! printf '%s\n' "${PASSPHRASE}" | gpg --decrypt --batch --yes --passphrase-fd 0 \
    "${encrypted_backup_file}" > "${backup_file}"; then
    log_error "Failed to decrypt backup with GPG"
    exit 1
  fi
  
  log_info "Backup decrypted"
else
  backup_file="${downloaded_backup_file}"
fi

# Extracts archive to target directory; overwrites existing files
restore_destination="${BACKUP_FOLDER}"
log_info "Extracting backup to: ${restore_destination}"
if ! tar -xf "${backup_file}" --directory "${restore_destination}"; then
  log_error "Failed to extract backup to: ${restore_destination}"
  exit 1
fi

log_info "Restore completed to: ${restore_destination}"
