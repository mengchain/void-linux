#!/bin/bash
# common.sh - Shared logging and color library for ZFS scripts
# Version: 1.1
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
# Detect if terminal supports UTF-8
if [[ "${LANG:-}" =~ UTF-8 ]] && [[ -t 1 ]]; then
    USE_UTF8_SYMBOLS=true
else
    USE_UTF8_SYMBOLS=false
fi

# Use UTF-8 symbols if supported, ASCII fallback otherwise
if [[ "$USE_UTF8_SYMBOLS" == "true" ]]; then
    SYMBOL_SUCCESS="✓"
    SYMBOL_ERROR="✗"
    SYMBOL_WARNING="⚠"
    SYMBOL_INFO="ℹ"
    SYMBOL_DEBUG="🔍"
    SYMBOL_ARROW="→"
    SYMBOL_BULLET="•"
else
    SYMBOL_SUCCESS="[OK]"
    SYMBOL_ERROR="[!!]"
    SYMBOL_WARNING="[**]"
    SYMBOL_INFO="[ii]"
    SYMBOL_DEBUG="[>>]"
    SYMBOL_ARROW="->"
    SYMBOL_BULLET="*"
fi

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

# Track if log file is writable
LOG_FILE_WRITABLE=false

# ============================================
# Log File Initialization
# ============================================
_init_log_file() {
    if [[ "$USE_LOG_FILE" != "true" ]] || [[ -z "$LOG_FILE" ]]; then
        return 0
    fi
    
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    
    # Create log directory if it doesn't exist
    if [[ ! -d "$log_dir" ]]; then
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            USE_LOG_FILE=false
            echo "WARNING: Could not create log directory: $log_dir" >&2
            echo "WARNING: Logging to file disabled" >&2
            return 1
        fi
    fi
    
    # Check if we can write to the log file
    if touch "$LOG_FILE" 2>/dev/null && [[ -w "$LOG_FILE" ]]; then
        LOG_FILE_WRITABLE=true
        # Add header to log file
        {
            echo ""
            echo "=============================================="
            echo "Log started: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Script: ${0##*/}"
            echo "User: $(whoami)"
            echo "PID: $$"
            echo "=============================================="
            echo ""
        } >> "$LOG_FILE" 2>/dev/null
    else
        USE_LOG_FILE=false
        LOG_FILE_WRITABLE=false
        echo "WARNING: Cannot write to log file: $LOG_FILE" >&2
        echo "WARNING: Logging to file disabled" >&2
        return 1
    fi
    
    return 0
}

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
    if [[ "$LOG_FILE_WRITABLE" == "true" ]]; then
        # Strip ANSI color codes for log file
        local clean_message="${symbol} ${level}: ${message}"
        echo "${timestamp} ${clean_message}" >> "$LOG_FILE" 2>/dev/null || {
            LOG_FILE_WRITABLE=false
            echo "WARNING: Lost write access to log file" >&2
        }
    fi
}

# ============================================
# Public Logging Functions
# ============================================
success() {
    _log "SUCCESS" "$COLOR_SUCCESS" "$SYMBOL_SUCCESS" "$*" "$LOG_LEVEL_INFO"
}

error() {
    _log "ERROR" "$COLOR_ERROR" "$SYMBOL_ERROR" "$*" "$LOG_LEVEL_ERROR" >&2
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
    if [[ "$LOG_FILE_WRITABLE" == "true" ]]; then
        {
            echo ""
            echo "$line"
            echo "$message"
            echo "$line"
            echo ""
        } >> "$LOG_FILE" 2>/dev/null
    fi
}

subheader() {
    local message="$*"
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "${CYAN}${BOLD}${message}${NC}"
    else
        echo "$message"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "$message" >> "$LOG_FILE" 2>/dev/null
}

# Print with bullet point
bullet() {
    local message="$*"
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "  ${CYAN}${SYMBOL_BULLET}${NC} ${message}"
    else
        echo "  ${SYMBOL_BULLET} ${message}"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "  ${SYMBOL_BULLET} ${message}" >> "$LOG_FILE" 2>/dev/null
}

# Print indented text
indent() {
    local level="${1:-1}"
    shift
    local message="$*"
    local spaces
    spaces=$(printf ' %.0s' $(seq 1 $((level * 2))))
    echo -e "${spaces}${message}"
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "${spaces}${message}" >> "$LOG_FILE" 2>/dev/null
}

# ============================================
# Status/Progress Functions
# ============================================
print_status() {
    local status="$1"
    local message="$2"
    
    local status_symbol
    local status_color="$NC"
    
    case "$status" in
        "ok"|"success"|"pass")
            status_symbol="$SYMBOL_SUCCESS"
            status_color="$GREEN"
            ;;
        "fail"|"error")
            status_symbol="$SYMBOL_ERROR"
            status_color="$RED"
            ;;
        "warn"|"warning")
            status_symbol="$SYMBOL_WARNING"
            status_color="$YELLOW"
            ;;
        "info")
            status_symbol="$SYMBOL_INFO"
            status_color="$BLUE"
            ;;
        "skip")
            status_symbol="-"
            status_color="$DIM"
            ;;
        *)
            status_symbol=" "
            status_color="$NC"
            ;;
    esac
    
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "[${status_color}${status_symbol}${NC}] ${message}"
    else
        echo "[$status_symbol] $message"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "[$status] $message" >> "$LOG_FILE" 2>/dev/null
}

# Show a spinner while command runs
spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spin='-\|/'
    local i=0
    
    # Hide cursor
    tput civis 2>/dev/null || true
    
    echo -n "$message "
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r%s [%c]" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    
    # Get exit status
    wait "$pid"
    local exit_status=$?
    
    # Show cursor
    tput cnorm 2>/dev/null || true
    
    if [[ $exit_status -eq 0 ]]; then
        if [[ "$USE_COLORS" == "true" ]]; then
            printf "\r%s [${GREEN}${SYMBOL_SUCCESS}${NC}]\n" "$message"
        else
            printf "\r%s [${SYMBOL_SUCCESS}]\n" "$message"
        fi
    else
        if [[ "$USE_COLORS" == "true" ]]; then
            printf "\r%s [${RED}${SYMBOL_ERROR}${NC}]\n" "$message"
        else
            printf "\r%s [${SYMBOL_ERROR}]\n" "$message"
        fi
    fi
    
    return $exit_status
}

# Progress bar
progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    local message="${4:-}"
    
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r%s [" "$message"
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %d%%" "$percentage"
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
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
    
    while true; do
        read -r -p "$prompt" reply
        reply="${reply:-$default}"
        
        case "$reply" in
            [Yy]*)
                return 0
                ;;
            [Nn]*)
                return 1
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

# Ask for input with validation
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local validator="${3:-}"
    local reply
    
    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " reply
            reply="${reply:-$default}"
        else
            read -r -p "$prompt: " reply
        fi
        
        # If no validator, accept any non-empty input
        if [[ -z "$validator" ]]; then
            if [[ -n "$reply" ]]; then
                echo "$reply"
                return 0
            fi
        else
            # Run validator function
            if $validator "$reply"; then
                echo "$reply"
                return 0
            fi
        fi
        
        error "Invalid input, please try again"
    done
}

# Confirm action
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    warning "$message"
    echo ""
    ask_yes_no "Are you sure you want to continue?" "$default"
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

# Check if running in chroot
in_chroot() {
    if [[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]]; then
        return 0
    else
        return 1
    fi
}

# Die with error message
die() {
    error "$*"
    
    # Log to file with stack trace if in debug mode
    if [[ "$LOG_FILE_WRITABLE" == "true" ]] && [[ "${CURRENT_LOG_LEVEL}" -eq "$LOG_LEVEL_DEBUG" ]]; then
        {
            echo "FATAL ERROR: $*"
            echo "Stack trace:"
            local frame=0
            while caller $frame; do
                ((frame++))
            done
        } >> "$LOG_FILE" 2>/dev/null
    fi
    
    exit 1
}

# Print separator line
separator() {
    local char="${1:--}"
    local length="${2:-60}"
    local line
    line=$(printf "${char}%.0s" $(seq 1 "$length"))
    echo "$line"
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null
}

# Safe command execution with logging
safe_run() {
    local cmd="$*"
    
    debug "Executing: $cmd"
    
    if eval "$cmd"; then
        debug "Command succeeded: $cmd"
        return 0
    else
        local exit_code=$?
        error "Command failed (exit code: $exit_code): $cmd"
        return $exit_code
    fi
}

# Retry command with exponential backoff
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-1}"
    shift 2
    local cmd="$*"
    
    local attempt=1
    local exit_code=0
    
    while [[ $attempt -le $max_attempts ]]; do
        debug "Attempt $attempt/$max_attempts: $cmd"
        
        if eval "$cmd"; then
            return 0
        fi
        exit_code=$?
        
        if [[ $attempt -lt $max_attempts ]]; then
            warning "Command failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        
        ((attempt++))
    done
    
    error "Command failed after $max_attempts attempts: $cmd"
    return $exit_code
}

# Check if value is in array
in_array() {
    local needle="$1"
    shift
    local haystack=("$@")
    
    for item in "${haystack[@]}"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Trim whitespace
trim() {
    local var="$*"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# ============================================
# Cleanup Handlers
# ============================================
_cleanup_handlers=()

# Register cleanup handler
register_cleanup() {
    local handler="$1"
    _cleanup_handlers+=("$handler")
}

# Execute all cleanup handlers
run_cleanup() {
    if [[ ${#_cleanup_handlers[@]} -gt 0 ]]; then
        info "Running cleanup handlers..."
        
        for handler in "${_cleanup_handlers[@]}"; do
            debug "Executing cleanup: $handler"
            eval "$handler" || warning "Cleanup handler failed: $handler"
        done
        
        _cleanup_handlers=()
    fi
}

# Trap EXIT to run cleanup
trap run_cleanup EXIT

# ============================================
# Initialization
# ============================================
# Initialize log file
_init_log_file

# ============================================
# Export functions (for use in subshells)
# ============================================
export -f success error warning info debug
export -f header subheader bullet indent
export -f print_status separator progress_bar
export -f ask_yes_no ask_input confirm_action
export -f require_root command_exists in_chroot die
export -f safe_run retry_command in_array trim
export -f register_cleanup run_cleanup

# Log that library was loaded
debug "common.sh library loaded (version 1.1)"

# Return success
return 0
```
