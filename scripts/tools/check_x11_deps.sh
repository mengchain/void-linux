#!/bin/bash
# filepath: check_x11_deps.sh

# X11 Library Dependency Checker for Void Linux
# Checks for direct and indirect X11 dependencies

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Common X11 libraries to check for
X11_LIBS=(
    "libX11"
    "libXext"
    "libXrender"
    "libXrandr"
    "libXinerama"
    "libXcursor"
    "libXdamage"
    "libXfixes"
    "libXcomposite"
    "libXi"
    "libXtst"
    "libXmu"
    "libXt"
    "libXaw"
    "libXpm"
    "libXss"
    "libXv"
    "libXvMC"
    "libXxf86vm"
    "libXxf86dga"
    "libXres"
    "libXScrnSaver"
    "libxcb"
    "libxkbcommon-x11"
)

# Function to check if package is installed
is_installed() {
    xbps-query -l | grep -q "^ii $1-[0-9]" 2>/dev/null
}

# Function to get package dependencies
get_dependencies() {
    local pkg="$1"
    xbps-query -x "$pkg" 2>/dev/null | awk '{print $2}' | sed 's/>=.*$//' | sort -u
}

# Function to get reverse dependencies
get_reverse_dependencies() {
    local lib="$1"
    xbps-query -X "$lib" 2>/dev/null | awk '{print $1}' | sort -u
}

# Function to check installed packages for X11 deps
check_installed_packages() {
    echo -e "${BLUE}=== Checking Installed Packages for X11 Dependencies ===${NC}"
    
    local found_x11=false
    local x11_packages=()
    
    for lib in "${X11_LIBS[@]}"; do
        if is_installed "$lib"; then
            x11_packages+=("$lib")
            found_x11=true
        fi
    done
    
    if [ "$found_x11" = true ]; then
        echo -e "${RED}Found X11 libraries installed:${NC}"
        printf '%s\n' "${x11_packages[@]}" | sed 's/^/  /'
    else
        echo -e "${GREEN}No direct X11 libraries found installed.${NC}"
    fi
    
    return $([[ "$found_x11" == true ]] && echo 1 || echo 0)
}

# Function to check specific package for X11 dependencies
check_package_deps() {
    local package="$1"
    echo -e "\n${BLUE}=== Checking '$package' Dependencies ===${NC}"
    
    if ! is_installed "$package"; then
        echo -e "${YELLOW}Package '$package' is not installed.${NC}"
        return 0
    fi
    
    local deps
    deps=$(get_dependencies "$package")
    local found_x11=false
    
    echo "Direct dependencies:"
    for dep in $deps; do
        echo "  $dep"
        for x11_lib in "${X11_LIBS[@]}"; do
            if [[ "$dep" == "$x11_lib"* ]]; then
                echo -e "    ${RED}↳ X11 dependency: $dep${NC}"
                found_x11=true
            fi
        done
    done
    
    return $([[ "$found_x11" == true ]] && echo 1 || echo 0)
}

# Function to recursively check dependencies
check_recursive_deps() {
    local package="$1"
    local depth="${2:-0}"
    local max_depth="${3:-3}"
    local checked_packages="${4:-}"
    
    # Avoid infinite loops
    if [[ "$checked_packages" == *"$package"* ]] || [ "$depth" -gt "$max_depth" ]; then
        return 0
    fi
    
    checked_packages="$checked_packages $package"
    local indent=""
    for ((i=0; i<depth; i++)); do
        indent="  $indent"
    done
    
    if ! is_installed "$package"; then
        return 0
    fi
    
    local deps
    deps=$(get_dependencies "$package")
    local found_x11=false
    
    for dep in $deps; do
        for x11_lib in "${X11_LIBS[@]}"; do
            if [[ "$dep" == "$x11_lib"* ]]; then
                echo -e "$indent${RED}$dep (X11)${NC}"
                found_x11=true
            else
                echo "$indent$dep"
                if [ "$depth" -lt "$max_depth" ]; then
                    check_recursive_deps "$dep" $((depth + 1)) "$max_depth" "$checked_packages"
                fi
            fi
        done
    done
    
    return $([[ "$found_x11" == true ]] && echo 1 || echo 0)
}

# Function to find what depends on X11 libraries
find_x11_dependents() {
    echo -e "\n${BLUE}=== Packages That Depend on X11 Libraries ===${NC}"
    
    for lib in "${X11_LIBS[@]}"; do
        if is_installed "$lib"; then
            echo -e "\n${YELLOW}Packages depending on $lib:${NC}"
            local dependents
            dependents=$(get_reverse_dependencies "$lib")
            if [ -n "$dependents" ]; then
                echo "$dependents" | sed 's/^/  /'
            else
                echo "  (none found)"
            fi
        fi
    done
}

# Function to generate removal suggestions
suggest_removals() {
    echo -e "\n${BLUE}=== X11 Removal Suggestions ===${NC}"
    
    local removable_libs=()
    for lib in "${X11_LIBS[@]}"; do
        if is_installed "$lib"; then
            local dependents
            dependents=$(get_reverse_dependencies "$lib")
            if [ -z "$dependents" ]; then
                removable_libs+=("$lib")
            fi
        fi
    done
    
    if [ ${#removable_libs[@]} -gt 0 ]; then
        echo -e "${GREEN}Potentially removable X11 libraries (no dependents):${NC}"
        printf '%s\n' "${removable_libs[@]}" | sed 's/^/  /'
        echo ""
        echo "To remove:"
        echo "  sudo xbps-remove -R ${removable_libs[*]}"
    else
        echo -e "${YELLOW}No X11 libraries can be safely removed (all have dependents).${NC}"
    fi
}

# Main function
main() {
    echo -e "${GREEN}X11 Dependency Checker for Void Linux${NC}"
    echo "======================================"
    
    # Check for X11 libraries
    if check_installed_packages; then
        find_x11_dependents
        suggest_removals
    fi
    
    # If package specified, check its dependencies
    if [ $# -gt 0 ]; then
        for package in "$@"; do
            check_package_deps "$package"
            echo -e "\n${BLUE}Recursive dependency tree for '$package':${NC}"
            check_recursive_deps "$package"
        done
    fi
    
    echo -e "\n${GREEN}Analysis complete.${NC}"
}

# Show usage if --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [package1] [package2] ..."
    echo ""
    echo "Checks for X11 library dependencies on Void Linux"
    echo "If no packages specified, checks all installed packages"
    echo "If packages specified, analyzes their dependency trees"
    echo ""
    echo "Examples:"
    echo "  $0                    # Check all installed packages"
    echo "  $0 firefox           # Check firefox dependencies"
    echo "  $0 kde5 plasma-desktop # Check multiple packages"
    exit 0
fi

# Run main function
main "$@"
