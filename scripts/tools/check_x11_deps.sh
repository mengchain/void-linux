#!/bin/bash
# check_x11_deps.sh - X11 dependency checker for Void Linux packages
# 
# Description: Checks if specified packages have direct or indirect X11 dependencies.
#              Can be used standalone or as part of xbps-wayland workflow.
#
# Usage: check_x11_deps.sh <package1> [package2] ...
# Example: check_x11_deps.sh firefox imv neovim
#
# Exit Codes:
#   0 - No X11 dependencies found in any package
#   1 - X11 dependencies found in one or more packages  
#   2 - Error in script execution
#
# Author: Generated for Void Linux Wayland-only systems
# License: Public Domain

set -euo pipefail

# Local script variables
local readonly SCRIPT_NAME="check_x11_deps"
local readonly SCRIPT_VERSION="1.0.0"

# Colors for output (local to this script)
local readonly RED='\033[0;31m'
local readonly GREEN='\033[0;32m'
local readonly YELLOW='\033[1;33m'
local readonly BLUE='\033[0;34m'
local readonly NC='\033[0m' # No Color

# X11 libraries to check for (local array)
local readonly X11_LIBS=(
    "libX11"
    "libXext" 
    "libXrender"
    "libXrandr"
    "libXinerama"
    "libXcursor"
    "libXcomposite"
    "libXdamage"
    "libXfixes"
    "libXi"
    "libXtst"
    "libXss"
    "libXmu"
    "libXpm"
    "libXaw"
    "libXt"
    "libSM"
    "libICE"
    "libxcb"
)

# Function to print usage information
usage() {
    cat << EOF
${BLUE}${SCRIPT_NAME}${NC} - X11 dependency checker for Void Linux

${YELLOW}USAGE:${NC}
    ${SCRIPT_NAME}.sh <package1> [package2] ...

${YELLOW}DESCRIPTION:${NC}
    Checks if specified packages have direct or indirect X11 dependencies.
    Useful for maintaining X11-free Wayland-only systems.

${YELLOW}EXAMPLES:${NC}
    ${SCRIPT_NAME}.sh firefox
    ${SCRIPT_NAME}.sh firefox imv mpv
    ${SCRIPT_NAME}.sh neovim

${YELLOW}OPTIONS:${NC}
    --help, -h    Show this help message
    --version     Show version information

${YELLOW}EXIT CODES:${NC}
    0    No X11 dependencies found
    1    X11 dependencies found
    2    Error in execution

EOF
}

# Function to print version information
version() {
    echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
    echo "X11 dependency checker for Void Linux Wayland-only systems"
}

# Function to log messages with timestamps (local function)
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

# Function to check if package has X11 dependencies
check_package_x11_deps() {
    local package="$1"
    local has_x11_deps=false
    local -a x11_deps=()
    
    log INFO "Checking dependencies for: $package"
    
    # Get all dependencies recursively using xbps-query
    local all_deps
    if ! all_deps=$(xbps-query -R -x "$package" 2>/dev/null); then
        log WARN "Could not query dependencies for package: $package (package might not exist)"
        return 0
    fi
    
    # Check each dependency against our X11 library list
    while IFS= read -r dep; do
        # Skip empty lines
        [[ -z "$dep" ]] && continue
        
        # Check if dependency matches any X11 library
        local x11_lib
        for x11_lib in "${X11_LIBS[@]}"; do
            if [[ "$dep" == *"$x11_lib"* ]]; then
                has_x11_deps=true
                x11_deps+=("$dep")
                break
            fi
        done
    done <<< "$all_deps"
    
    # Report findings
    if [[ "$has_x11_deps" == true ]]; then
        log ERROR "Package '$package' has X11 dependencies:"
        local x11_dep
        for x11_dep in "${x11_deps[@]}"; do
            printf "  %s\n" "$x11_dep"
        done
        return 1
    else
        log SUCCESS "Package '$package' is X11-free ✓"
        return 0
    fi
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
            log ERROR "No packages provided"
            usage
            exit 2
            ;;
    esac
    
    # Check if xbps-query is available
    if ! command -v xbps-query >/dev/null 2>&1; then
        log ERROR "xbps-query not found. Are you running on Void Linux?"
        exit 2
    fi
    
    # Local variables for main function
    local -a packages=("$@")
    local -a failed_packages=()
    local total_packages=${#packages[@]}
    local current=1
    local package
    
    log INFO "Starting X11 dependency check for ${total_packages} package(s)"
    echo
    
    # Check each package for X11 dependencies
    for package in "${packages[@]}"; do
        log INFO "[$current/$total_packages] Checking package: $package"
        
        if ! check_package_x11_deps "$package"; then
            failed_packages+=("$package")
        fi
        
        ((current++))
        echo
    done
    
    # Report final results
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log ERROR "X11 dependencies found in the following packages:"
        echo
        local failed_pkg
        for failed_pkg in "${failed_packages[@]}"; do
            printf "${RED}  ✗ %s${NC}\n" "$failed_pkg"
        done
        echo
        log ERROR "These packages have X11 dependencies and are not suitable for Wayland-only systems"
        exit 1
    else
        log SUCCESS "All packages are X11-free! ✓"
        echo
        log SUCCESS "All ${total_packages} package(s) are suitable for Wayland-only systems"
        exit 0
    fi
}

# Run main function with all arguments
main "$@"
