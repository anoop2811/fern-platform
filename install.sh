#!/bin/bash
#
# Fern Platform installation script
# 
# This script downloads and installs the latest version of Fern Platform
# Usage: curl -sSfL https://raw.githubusercontent.com/guidewire-oss/fern-platform/main/install.sh | bash
#

set -euo pipefail

# Configuration
GITHUB_REPO="guidewire-oss/fern-platform"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="fern-platform"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Detect OS and architecture
detect_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "$os" in
        darwin) os="Darwin" ;;
        linux) os="Linux" ;;
        mingw*|msys*|cygwin*) os="Windows" ;;
        *) log_error "Unsupported operating system: $os"; exit 1 ;;
    esac
    
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        i386|i686) arch="i386" ;;
        *) log_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
    
    echo "${os}_${arch}"
}

# Get the latest release version
get_latest_version() {
    local version=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | cut -d'"' -f4)
    if [[ -z "$version" ]]; then
        log_error "Failed to get latest version"
        exit 1
    fi
    echo "$version"
}

# Download and verify checksums
download_and_verify() {
    local version=$1
    local platform=$2
    local temp_dir=$(mktemp -d)
    local original_dir=$(pwd)
    
    cd "$temp_dir"
    
    # Determine file extension
    local ext="tar.gz"
    if [[ "$platform" == "Windows"* ]]; then
        ext="zip"
    fi
    
    local archive_name="${BINARY_NAME}_${version#v}_${platform}.${ext}"
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${archive_name}"
    
    log_info "Downloading ${BINARY_NAME} ${version} for ${platform}..."
    if ! curl -sSfL -o "${archive_name}" "${download_url}"; then
        log_error "Failed to download ${archive_name}"
        cd "$original_dir"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Download checksums and signature
    log_info "Downloading checksums..."
    curl -sSfL -o "checksums.txt" "https://github.com/${GITHUB_REPO}/releases/download/${version}/checksums.txt"
    
    # Try to verify checksums signature with cosign if available
    if command -v cosign >/dev/null 2>&1; then
        log_info "Downloading checksum signature for verification..."
        if curl -sSfL -o "checksums.txt.sig" "https://github.com/${GITHUB_REPO}/releases/download/${version}/checksums.txt.sig" 2>/dev/null && \
           curl -sSfL -o "checksums.txt.pem" "https://github.com/${GITHUB_REPO}/releases/download/${version}/checksums.txt.pem" 2>/dev/null; then
            log_info "Verifying checksum signature with cosign..."
            if cosign verify-blob \
                --certificate checksums.txt.pem \
                --signature checksums.txt.sig \
                --certificate-identity-regexp "https://github.com/${GITHUB_REPO}/.github/workflows/.*.yml@refs/tags/${version}" \
                --certificate-oidc-issuer https://token.actions.githubusercontent.com \
                checksums.txt >/dev/null 2>&1; then
                log_info "Checksum signature verified successfully"
            else
                log_error "Checksum signature verification failed!"
                cd "$original_dir"
                rm -rf "$temp_dir"
                exit 1
            fi
        else
            log_warning "Checksum signature files not found, proceeding without signature verification"
        fi
    else
        log_warning "cosign not found, skipping checksum signature verification"
        log_warning "For enhanced security, install cosign: https://docs.sigstore.dev/cosign/installation"
    fi
    
    # Verify checksum
    log_info "Verifying file checksum..."
    if command -v sha256sum >/dev/null 2>&1; then
        grep -F "${archive_name}" checksums.txt | sha256sum -c -
    elif command -v shasum >/dev/null 2>&1; then
        grep -F "${archive_name}" checksums.txt | shasum -a 256 -c -
    else
        log_warning "Cannot verify checksum: sha256sum or shasum not found"
    fi
    
    # Extract archive
    log_info "Extracting archive..."
    if [[ "$ext" == "zip" ]]; then
        unzip -q "${archive_name}"
    else
        tar -xzf "${archive_name}"
    fi
    
    # Return to original directory before returning temp_dir path
    cd "$original_dir"
    echo "$temp_dir"
}

# Install binary
install_binary() {
    local temp_dir=$1
    local install_path="${INSTALL_DIR}/${BINARY_NAME}"
    
    # Check if we need sudo
    local sudo_cmd=""
    if [[ ! -w "$INSTALL_DIR" ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
            log_info "Administrator privileges required to install to ${INSTALL_DIR}"
        else
            log_error "Cannot write to ${INSTALL_DIR} and sudo is not available"
            exit 1
        fi
    fi
    
    # Install the binary
    log_info "Installing ${BINARY_NAME} to ${install_path}..."
    
    # Use install command if available, otherwise fallback to cp
    if command -v install >/dev/null 2>&1; then
        ${sudo_cmd} install -m 755 "${temp_dir}/${BINARY_NAME}" "$install_path"
    else
        # Fallback for systems without install command
        ${sudo_cmd} cp "${temp_dir}/${BINARY_NAME}" "$install_path"
        ${sudo_cmd} chmod 755 "$install_path"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
}

# Verify installation
verify_installation() {
    local install_path="${INSTALL_DIR}/${BINARY_NAME}"
    
    # Check if binary exists at install path
    if [[ -x "$install_path" ]]; then
        local installed_version=$("$install_path" --version 2>&1 || echo "unknown")
        log_info "Successfully installed ${BINARY_NAME} ${installed_version}"
        
        # Check if install dir is in PATH
        if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
            log_warning "${INSTALL_DIR} is not in your PATH"
            log_warning "Add the following to your shell configuration:"
            echo "    export PATH=\"\$PATH:${INSTALL_DIR}\""
            log_info ""
            log_info "You can run the binary directly with: ${install_path}"
        fi
    else
        log_error "Installation verification failed - binary not found at ${install_path}"
        exit 1
    fi
}

# Main installation flow
main() {
    log_info "Installing Fern Platform..."
    
    # Check for required tools
    local required_tools="curl tar grep cut"
    local missing_tools=""
    
    for tool in $required_tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    # Check for install command (required for binary installation)
    if ! command -v install >/dev/null 2>&1; then
        # On macOS, install is typically available
        # On Linux, it's part of coreutils
        # On Windows/MinGW, we might need to handle differently
        if [[ "$(uname -s)" != "Darwin" ]] && [[ "$(uname -s)" != "Linux" ]]; then
            log_warning "install command not found, will use fallback method"
        else
            missing_tools="$missing_tools install"
        fi
    fi
    
    # Check for checksum tools (at least one is needed)
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        log_warning "Neither sha256sum nor shasum found - checksum verification will be skipped"
    fi
    
    if [[ -n "$missing_tools" ]]; then
        log_error "Required tools not found:$missing_tools"
        log_error "Please install the missing tools and try again"
        exit 1
    fi
    
    # Get platform and version
    local platform=$(detect_platform)
    local version="${VERSION:-$(get_latest_version)}"
    
    log_info "Platform: ${platform}"
    log_info "Version: ${version}"
    
    # Check for unzip on Windows
    if [[ "$platform" == "Windows"* ]]; then
        if ! command -v unzip >/dev/null 2>&1; then
            log_error "Required tool not found: unzip (needed for Windows installations)"
            exit 1
        fi
    fi
    
    # Download and extract
    local temp_dir=$(download_and_verify "$version" "$platform")
    
    # Install
    install_binary "$temp_dir"
    
    # Verify
    verify_installation
    
    log_info "Installation complete!"
    log_info ""
    log_info "To get started:"
    log_info "  1. Run '${BINARY_NAME} --help' to see available commands"
    log_info "  2. Check the documentation at https://github.com/${GITHUB_REPO}"
}

# Run main function
main "$@"