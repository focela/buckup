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

# Outputs timestamped info message to stdout
log_info() {
  printf '[INFO] %s\n' "$*"
}

# Outputs timestamped error message to stderr
log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Removes download artifacts on exit; prevents temp file accumulation
cleanup_temp_files() {
  if [ -n "${cronx_archive_file:-}" ] && [ -f "${cronx_archive_file}" ]; then
    log_info "Cleaning up temporary file: ${cronx_archive_file}"
    rm -f "${cronx_archive_file}" || log_info "Failed to remove ${cronx_archive_file}"
  fi
  if [ -n "${cronx_binary:-}" ] && [ -f "${cronx_binary}" ]; then
    log_info "Cleaning up extracted binary: ${cronx_binary}"
    rm -f "${cronx_binary}" || log_info "Failed to remove ${cronx_binary}"
  fi
}

trap cleanup_temp_files EXIT

# Updates package index; required before installing packages
log_info "Updating Alpine package index"
if ! apk update; then
  log_error "Failed to update Alpine package index"
  exit 1
fi

# Installs runtime dependencies; GPG for encryption, Python for AWS CLI
log_info "Installing core dependencies (GPG, Python3, pip)"
if ! apk add --no-cache gnupg python3 py3-pip; then
  log_error "Failed to install core dependencies"
  exit 1
fi

# Installs AWS CLI; bypasses Alpine's externally-managed environment
log_info "Installing AWS CLI via pip"
if ! pip3 install --no-cache-dir awscli --break-system-packages; then
  log_error "Failed to install AWS CLI"
  exit 1
fi

# Verifies AWS CLI accessible in PATH after installation
if ! command -v aws >/dev/null 2>&1; then
  log_error "AWS CLI installation verification failed"
  exit 1
fi
log_info "AWS CLI installed"

# Installs curl temporarily; needed for GitHub API download
log_info "Installing curl for cronx download"
if ! apk add --no-cache curl; then
  log_error "Failed to install curl"
  exit 1
fi

# Downloads binary matching container architecture; defaults to amd64
log_info "Downloading cronx scheduler"
cronx_version="1.0.0"
target_arch="${TARGETARCH:-amd64}"
cronx_archive_file="cronx_${cronx_version}_linux_${target_arch}.tar.gz"
cronx_download_url="https://github.com/focela/cronx/releases/download/v${cronx_version}/${cronx_archive_file}"

# Downloads archive with fail-fast on HTTP errors
if ! curl -fsSL "${cronx_download_url}" -o "${cronx_archive_file}"; then
  log_error "Failed to download cronx from: ${cronx_download_url}"
  exit 1
fi

# Extracts binary from gzipped tar; assumes archive contains 'cronx' file
log_info "Extracting cronx binary"
if ! tar -xzf "${cronx_archive_file}"; then
  log_error "Failed to extract cronx archive: ${cronx_archive_file}"
  exit 1
fi

# Installs binary to system PATH; enables global access
cronx_binary="cronx"
cronx_install_path="/usr/local/bin/cronx"
log_info "Installing cronx to: ${cronx_install_path}"
if ! mv "${cronx_binary}" "${cronx_install_path}"; then
  log_error "Failed to move cronx to: ${cronx_install_path}"
  exit 1
fi

# Sets execute permissions; required for binary execution
if ! chmod 755 "${cronx_install_path}"; then
  log_error "Failed to set execute permissions on: ${cronx_install_path}"
  exit 1
fi

# Verifies cronx accessible in PATH after installation
if ! command -v cronx >/dev/null 2>&1; then
  log_error "cronx installation verification failed"
  exit 1
fi

# Removes curl to reduce image size; no longer needed after download
log_info "Removing curl package"
if ! apk del curl; then
  log_error "Failed to remove curl package"
  exit 1
fi

log_info "cronx installed"

# Removes package cache to minimize final image size
log_info "Cleaning up Alpine package cache"
if ! rm -rf /var/cache/apk/*; then
  log_error "Failed to clean Alpine package cache"
  exit 1
fi

# Verifies all required commands available in PATH
log_info "Verifying installation"
for required_cmd in aws gpg cronx; do
  if ! command -v "${required_cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${required_cmd}"
    exit 1
  fi
done

log_info "All dependencies verified"
log_info "Installation completed"
