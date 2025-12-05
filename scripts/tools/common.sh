#!/bin/bash
# common.sh - Shared logging and color library for ZFS scripts
# Version: 1.0
# Description: Provides consistent logging, colors, and utility functions

# ============================================
# Prevent multiple sourcing
# ============================================
if [[ -n "${ZFS_COMMON_LOADED:-}" ]]; then
    return 0
fi
ZFS_COMMON_LOADED=1

# ============================================
# Color Definitions
# ============================================
# Standard colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;94m'      # Light blue for better visibility
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'           # No Color / Reset

# Semantic colors (for consistency)
COLOR_SUCCESS="$GREEN"
COLOR_ERROR="$RED"
COLOR_WARNING="$YELLOW"
COLOR_INFO="$BLUE"
COLOR_DEBUG="$CYAN"
COLOR_HEADER="$MAGENTA"

# ============================================
# Symbols for better visual output
# ============================================
SYMBOL_SUCCESS="✓"
SYMBOL_ERROR="✗"
SYMBOL_WARNING="⚠"
SYMBOL_INFO="ℹ"
SYMBOL_DEBUG="🔍"
SYMBOL_ARROW="→"
SYMBOL_BULLET="•"

# ============================================
# Configuration
# ============================================
# Default log file (can be overridden by sourcing script)
LOG_FILE="${LOG_FILE:-/var/log/zfs-scripts.log}"

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARNING=2
LOG_LEVEL_ERROR=3
LOG_LEVEL_NONE=4

# Current log level (default: INFO)
CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Enable/disable colored output (auto-detect TTY)
if [[ -t 1 ]]; then
    USE_COLORS="${USE_COLORS:-true}"
else
    USE_COLORS="${USE_COLORS:-false}"
fi

# Enable/disable log file output
USE_LOG_FILE="${USE_LOG_FILE:-true}"

# ============================================
# Core Logging Function
# ============================================
_log() {
    local level="$1"
    local color="$2"
    local symbol="$3"
    local message="$4"
    local level_value="$5"
    
    # Check log level
    if [[ $level_value -lt $CURRENT_LOG_LEVEL ]]; then
        return 0
    fi
    
    local timestamp
    timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    
    local formatted_message
    if [[ "$USE_COLORS" == "true" ]]; then
        formatted_message="${color}${symbol} ${level}: ${message}${NC}"
    else
        formatted_message="${symbol} ${level}: ${message}"
    fi
    
    # Output to terminal
    echo -e "${timestamp} ${formatted_message}"
    
    # Output to log file (without colors)
    if [[ "$USE_LOG_FILE" == "true" ]] && [[ -n "$LOG_FILE" ]]; then
        # Ensure log directory exists
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || true
        fi
        
        # Write to log file (strip ANSI color codes)
        echo "${timestamp} ${symbol} ${level}: ${message}" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ============================================
# Public Logging Functions
# ============================================
success() {
    _log "SUCCESS" "$COLOR_SUCCESS" "$SYMBOL_SUCCESS" "$*" "$LOG_LEVEL_INFO"
}

error() {
    _log "ERROR" "$COLOR_ERROR" "$SYMBOL_ERROR" "$*" "$LOG_LEVEL_ERROR"
}

warning() {
    _log "WARNING" "$COLOR_WARNING" "$SYMBOL_WARNING" "$*" "$LOG_LEVEL_WARNING"
}

info() {
    _log "INFO" "$COLOR_INFO" "$SYMBOL_INFO" "$*" "$LOG_LEVEL_INFO"
}

debug() {
    _log "DEBUG" "$COLOR_DEBUG" "$SYMBOL_DEBUG" "$*" "$LOG_LEVEL_DEBUG"
}

# ============================================
# Special Formatting Functions
# ============================================
header() {
    local message="$*"
    local line_length=60
    local line
    line=$(printf '=%.0s' $(seq 1 $line_length))
    
    if [[ "$USE_COLORS" == "true" ]]; then
        echo ""
        echo -e "${COLOR_HEADER}${line}${NC}"
        echo -e "${COLOR_HEADER}${BOLD}${message}${NC}"
        echo -e "${COLOR_HEADER}${line}${NC}"
        echo ""
    else
        echo ""
        echo "$line"
        echo "$message"
        echo "$line"
        echo ""
    fi
    
    # Log to file
    if [[ "$USE_LOG_FILE" == "true" ]] && [[ -n "$LOG_FILE" ]]; then
        {
            echo ""
            echo "$line"
            echo "$message"
            echo "$line"
            echo ""
        } >> "$LOG_FILE" 2>/dev/null || true
    fi
}

subheader() {
    local message="$*"
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "${CYAN}${BOLD}${message}${NC}"
    else
        echo "$message"
    fi
    
    [[ "$USE_LOG_FILE" == "true" ]] && echo "$message" >> "$LOG_FILE" 2>/dev/null || true
}

# Print with bullet point
bullet() {
    local message="$*"
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "  ${CYAN}${SYMBOL_BULLET}${NC} ${message}"
    else
        echo "  ${SYMBOL_BULLET} ${message}"
    fi
    
    [[ "$USE_LOG_FILE" == "true" ]] && echo "  ${SYMBOL_BULLET} ${message}" >> "$LOG_FILE" 2>/dev/null || true
}

# Print indented text
indent() {
    local level="${1:-1}"
    local message="${2:-}"
    local spaces
    spaces=$(printf ' %.0s' $(seq 1 $((level * 2))))
    echo -e "${spaces}${message}"
    
    [[ "$USE_LOG_FILE" == "true" ]] && echo "${spaces}${message}" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================
# Status/Progress Functions
# ============================================
print_status() {
    local status="$1"
    local message="$2"
    
    case "$status" in
        "ok"|"success"|"pass")
            echo -e "[${GREEN}${SYMBOL_SUCCESS}${NC}] ${message}"
            ;;
        "fail"|"error")
            echo -e "[${RED}${SYMBOL_ERROR}${NC}] ${message}"
            ;;
        "warn"|"warning")
            echo -e "[${YELLOW}${SYMBOL_WARNING}${NC}] ${message}"
            ;;
        "info")
            echo -e "[${BLUE}${SYMBOL_INFO}${NC}] ${message}"
            ;;
        "skip")
            echo -e "[${DIM}-${NC}] ${message}"
            ;;
        *)
            echo -e "[ ] ${message}"
            ;;
    esac
    
    [[ "$USE_LOG_FILE" == "true" ]] && echo "[$status] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Show a spinner while command runs
spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spin='-\|/'
    local i=0
    
    echo -n "$message "
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r%s [%c]" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r%s [${GREEN}${SYMBOL_SUCCESS}${NC}]\n" "$message"
}

# ============================================
# Interactive Functions
# ============================================
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local reply
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -r -p "$prompt" reply
    reply="${reply:-$default}"
    
    case "$reply" in
        [Yy]*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================
# Utility Functions
# ============================================
# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        error "Please run: sudo $0"
        exit 1
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Die with error message
die() {
    error "$*"
    exit 1
}

# Print separator line
separator() {
    local char="${1:--}"
    local length="${2:-60}"
    local line
    line=$(printf "${char}%.0s" $(seq 1 "$length"))
    echo "$line"
    
    [[ "$USE_LOG_FILE" == "true" ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================
# Initialization
# ============================================
# Ensure log directory exists
if [[ "$USE_LOG_FILE" == "true" ]] && [[ -n "$LOG_FILE" ]]; then
    log_dir="$(dirname "$LOG_FILE")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            USE_LOG_FILE=false
            warning "Could not create log directory: $log_dir"
            warning "Logging to file disabled"
        }
    fi
fi

# ============================================
# Export functions (for use in subshells)
# ============================================
export -f success error warning info debug
export -f header subheader bullet indent
export -f print_status separator
export -f ask_yes_no require_root command_exists die

# Log that library was loaded
debug "common.sh library loaded (version 1.0)"