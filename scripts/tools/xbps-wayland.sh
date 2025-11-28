#!/bin/bash
# xbps-wayland.sh - X11-free package installer for Void Linux
# 
# Description: A wrapper around xbps-install that uses check_x11_deps.sh to verify
#              packages are X11-free before installation. Prevents installation of 
#              packages with X11 dependencies on pure Wayland systems.
#
# Usage: xbps-wayland.sh [xbps-install options] <package1> [package2] ...
# Example: xbps-wayland.sh -S firefox imv neovim
#
# Dependencies: check_x11_deps.sh (must be in PATH or same directory)
#
# Author: Generated for Void Linux Wayland-only systems  
# License: Public Domain

set -euo pipefail

# Local script variables
SCRIPT_NAME="xbps-wayland"
SCRIPT_VERSION="1.0.0"
DEPENDENCY_CHECKER="check_x11_deps.sh"

# Colors for output (local to this script)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage information
usage() {
    cat << EOF
${BLUE}${SCRIPT_NAME}${NC} - X11-free package installer for Void Linux

${YELLOW}USAGE:${NC}
    ${SCRIPT_NAME}.sh [xbps-install options] <package1> [package2] ...

${YELLOW}DESCRIPTION:${NC}
    A wrapper around xbps-install that checks for X11 dependencies before
    installation. Uses ${DEPENDENCY_CHECKER} to verify packages are X11-free.

${YELLOW}EXAMPLES:${NC}
    ${SCRIPT_NAME}.sh firefox imv
    ${SCRIPT_NAME}.sh -S neovim mpv  
    ${SCRIPT_NAME}.sh -Su

${YELLOW}OPTIONS:${NC}
    All xbps-install options are supported and passed through.
    
    --help, -h    Show this help message
    --version     Show version information

${YELLOW}EXIT CODES:${NC}
    0    Success (no X11 dependencies found, installation completed)
    1    X11 dependencies found (installation blocked)
    2    Error in script execution
    3    xbps-install failed

${YELLOW}DEPENDENCIES:${NC}
    - ${DEPENDENCY_CHECKER} (must be in PATH)
    - xbps-install and xbps-query

EOF
}

# Function to print version information
version() {
    echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
    echo "Wrapper for xbps-install on Void Linux Wayland-only systems"
}

# Function to log messages (local function)
log() {
    local level="$1"
    shift
    local message="$*"
    
    case "$level" in
        INFO)    echo -e "${BLUE}[INFO]${NC} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    esac
}

# Function to extract package names from command line arguments
extract_packages() {
    local -a packages=()
    local skip_next=false
    local arg
    
    for arg in "$@"; do
        # Skip if previous argument was an option requiring a value
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            continue
        fi
        
        # Skip options that start with dash
        if [[ "$arg" == -* ]]; then
            # Check if this option requires a value
            case "$arg" in
                -r|--repository|-c|--config|--rootdir|--cachedir)
                    skip_next=true
                    ;;
            esac
            continue
        fi
        
        # This should be a package name
        packages+=("$arg")
    done
    
    local package
    for package in "${packages[@]}"; do
        printf "%s\n" "$package"
    done
}

# Function to check if running as root (when needed)
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        # Check if we need root privileges by looking for update/install flags
        local arg
        for arg in "$@"; do
            case "$arg" in
                -S|-u|-f|--sync|--update|--force)
                    log ERROR "Root privileges required for package installation"
                    log INFO "Try: sudo ${SCRIPT_NAME}.sh $*"
                    exit 2
                    ;;
            esac
        done
    fi
}

# Function to find dependency checker script
find_dependency_checker() {
    local checker_path
    
    # Try to find check_x11_deps.sh in PATH
    if command -v "$DEPENDENCY_CHECKER" >/dev/null 2>&1; then
        checker_path=$(command -v "$DEPENDENCY_CHECKER")
        echo "$checker_path"
        return 0
    fi
    
    # Try same directory as this script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$script_dir/$DEPENDENCY_CHECKER" ]]; then
        echo "$script_dir/$DEPENDENCY_CHECKER"
        return 0
    fi
    
    # Try common locations
    local common_paths=(
        "/usr/local/bin/$DEPENDENCY_CHECKER"
        "/usr/bin/$DEPENDENCY_CHECKER"
        "./bin/$DEPENDENCY_CHECKER"
    )
    
    local path
    for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Main function
main() {
    # Handle special arguments
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        --version)
            version
            exit 0
            ;;
        "")
            log ERROR "No arguments provided"
            usage
            exit 2
            ;;
    esac
    
    # Check if required tools are available
    if ! command -v xbps-install >/dev/null 2>&1; then
        log ERROR "xbps-install not found. Are you running on Void Linux?"
        exit 2
    fi
    
    # Find dependency checker script
    local checker_path
    if ! checker_path=$(find_dependency_checker); then
        log ERROR "${DEPENDENCY_CHECKER} not found in PATH or common locations"
        log ERROR "Please install ${DEPENDENCY_CHECKER} or place it in the same directory"
        exit 2
    fi
    
    # Check root privileges if needed
    check_root "$@"
    
    log INFO "Starting X11-free package installation process"
    log INFO "Using dependency checker: $checker_path"
    
    # Extract package names from arguments
    local -a packages
    readarray -t packages < <(extract_packages "$@")
    
    # If no packages found, might be update operation
    if [[ ${#packages[@]} -eq 0 ]]; then
        log INFO "No packages specified, assuming system operation (update/sync/etc)"
        log INFO "Proceeding with xbps-install (no X11 check needed)..."
        exec xbps-install "$@"
    fi
    
    log INFO "Packages to install: ${packages[*]}"
    echo
    
    # Run X11 dependency check
    log INFO "Running X11 dependency check..."
    if "$checker_path" "${packages[@]}"; then
        echo
        log SUCCESS "X11 dependency check passed! Proceeding with installation..."
        echo
        
        # Execute the actual xbps-install command
        log INFO "Running: xbps-install $*"
        if xbps-install "$@"; then
            echo
            log SUCCESS "Installation completed successfully!"
            exit 0
        else
            echo
            log ERROR "xbps-install failed"
            exit 3
        fi
    else
        echo
        log ERROR "X11 dependency check failed!"
        log ERROR "Installation blocked to maintain Wayland-only system"
        log INFO "Consider finding Wayland-native alternatives or compile from source"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
