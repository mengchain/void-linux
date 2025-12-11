#!/usr/bin/env bash
# filepath: common.sh
# Common Library for Bash Scripts
# Version: 2.1
# Description: Generic shared functions for logging, colors, and utilities
#
# This library provides:
# - Color definitions and terminal formatting
# - Logging and output formatting (categorized by level)
# - Error handling and validation
# - File and directory operations
# - Interactive user input
# - System information utilities
# - Cleanup handlers
#
# This library is FILESYSTEM-AGNOSTIC
# No ZFS-specific, Btrfs-specific, or other filesystem code
#
# Usage:
#   source /usr/local/lib/zfs-scripts/common.sh

# ============================================
# LIBRARY INITIALIZATION
# ============================================

# Prevent multiple sourcing
if [[ -n "${COMMON_LIBRARY_LOADED:-}" ]]; then
    return 0
fi
readonly COMMON_LIBRARY_LOADED=1

# Library metadata
readonly COMMON_VERSION="2.1"
readonly COMMON_DATE="2025-12-09"

# ============================================
# CONFIGURATION
# ============================================

# Default log file (can be overridden by sourcing script)
LOG_FILE="${LOG_FILE:-/var/log/script.log}"

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARNING=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_NONE=4

# Current log level (default: INFO)
CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Enable/disable log file output
USE_LOG_FILE="${USE_LOG_FILE:-true}"

# Track if log file is writable
LOG_FILE_WRITABLE=false

# Cleanup handlers array
_cleanup_handlers=()

# ============================================
# CONFIGURATION AND ENVIRONMENT FUNCTIONS
# ============================================
# Load configuration file with validation
load_config() {
    local config_file="$1"
    local required_vars=("${@:2}")
    
    if [[ ! -f "$config_file" ]]; then
        error "Configuration file not found: $config_file"
        return 1
    fi
    
    # Source config file in a subshell first to validate
    if ! (source "$config_file" 2>/dev/null); then
        error "Invalid configuration file: $config_file"
        return 1
    fi
    
    source "$config_file"
    
    # Validate required variables
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error "Required configuration variable not set: $var"
            return 1
        fi
    done
    
    success "Configuration loaded: $config_file"
}

# Set default values for variables
set_defaults() {
    local -A defaults=("$@")
    
    for var in "${!defaults[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            declare -g "$var"="${defaults[$var]}"
            debug "Set default: $var=${defaults[$var]}"
        fi
    done
}

# Check for required environment variables
check_env_vars() {
    local missing=()
    
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required environment variables: ${missing[*]}"
        return 1
    fi
    
    return 0
}


# ============================================
# COLOR DEFINITIONS
# ============================================

# Detect if we should use colors
if [[ -t 1 ]] && [[ "${USE_COLORS:-true}" == "true" ]]; then
    # Standard colors
    readonly BLUE='\033[1;94m'      # Light blue for better visibility
    readonly BOLD='\033[1m'
    readonly CYAN='\033[0;36m'
    readonly DIM='\033[2m'
    readonly GREEN='\033[0;32m'
    readonly MAGENTA='\033[0;35m'
    readonly NC='\033[0m'           # No Color / Reset
    readonly RED='\033[0;31m'
    readonly UNDERLINE='\033[4m'
    readonly WHITE='\033[1;37m'
    readonly YELLOW='\033[1;33m'
    
    # Semantic colors (for consistency)
    readonly COLOR_DEBUG="$CYAN"
    readonly COLOR_ERROR="$RED"
    readonly COLOR_HEADER="$MAGENTA"
    readonly COLOR_INFO="$BLUE"
    readonly COLOR_SUCCESS="$GREEN"
    readonly COLOR_WARNING="$YELLOW"
else
    # No colors
    readonly BLUE=''
    readonly BOLD=''
    readonly CYAN=''
    readonly DIM=''
    readonly GREEN=''
    readonly MAGENTA=''
    readonly NC=''
    readonly RED=''
    readonly UNDERLINE=''
    readonly WHITE=''
    readonly YELLOW=''
    readonly COLOR_DEBUG=''
    readonly COLOR_ERROR=''
    readonly COLOR_HEADER=''
    readonly COLOR_INFO=''
    readonly COLOR_SUCCESS=''
    readonly COLOR_WARNING=''
fi

# ============================================
# SYMBOLS FOR VISUAL OUTPUT
# ============================================

# Detect if terminal supports UTF-8
if [[ "${LANG:-}" =~ UTF-8 ]] && [[ -t 1 ]]; then
    USE_UTF8_SYMBOLS=true
else
    USE_UTF8_SYMBOLS=false
fi

# Use UTF-8 symbols if supported, ASCII fallback otherwise
if [[ "$USE_UTF8_SYMBOLS" == "true" ]]; then
    readonly SYMBOL_ARROW="→"
    readonly SYMBOL_BULLET="•"
    readonly SYMBOL_DEBUG="🔍"
    readonly SYMBOL_ERROR="✗"
    readonly SYMBOL_INFO="ℹ"
    readonly SYMBOL_SUCCESS="✓"
    readonly SYMBOL_WARNING="⚠"
else
    readonly SYMBOL_ARROW="->"
    readonly SYMBOL_BULLET="*"
    readonly SYMBOL_DEBUG="[>>]"
    readonly SYMBOL_ERROR="[!!]"
    readonly SYMBOL_INFO="[ii]"
    readonly SYMBOL_SUCCESS="[OK]"
    readonly SYMBOL_WARNING="[**]"
fi

# ============================================
# INTERNAL FUNCTIONS
# ============================================

# Initialize log file
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

# Core logging function
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
    if [[ -n "$color" ]]; then
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
# CLEANUP HANDLERS
# ============================================

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

# ============================================
# FILE OPERATIONS
# ============================================

# Create backup of file
backup_file() {
    local file="$1"
    local backup_suffix="${2:-.backup.$(timestamp)}"
    
    if [[ ! -f "$file" ]]; then
        warning "Cannot backup non-existent file: $file"
        return 1
    fi
    
    local backup_file="${file}${backup_suffix}"
    
    if cp -a "$file" "$backup_file"; then
        success "Backup created: $backup_file"
        return 0
    else
        error "Failed to create backup: $backup_file"
        return 1
    fi
}

# Create directory with parents
ensure_directory() {
    local dir="$1"
    local perms="${2:-755}"
    
    if [[ -d "$dir" ]]; then
        debug "Directory already exists: $dir"
        return 0
    fi
    
    if mkdir -p "$dir"; then
        chmod "$perms" "$dir"
        debug "Created directory: $dir"
        return 0
    else
        error "Failed to create directory: $dir"
        return 1
    fi
}

# ============================================
# FORMATTING FUNCTIONS
# ============================================

# Print with bullet point
bullet() {
    local message="$*"
    if [[ -n "$CYAN" ]]; then
        echo -e "  ${CYAN}${SYMBOL_BULLET}${NC} ${message}"
    else
        echo "  ${SYMBOL_BULLET} ${message}"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "  ${SYMBOL_BULLET} ${message}" >> "$LOG_FILE" 2>/dev/null
}

# Format bytes to human-readable size
format_bytes() {
    local bytes="$1"
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit=0
    local size="$bytes"
    
    while (( $(echo "$size >= 1024" | bc -l 2>/dev/null || echo 0) )); do
        size=$(echo "scale=2; $size / 1024" | bc)
        ((unit++))
    done
    
    printf "%.2f %s" "$size" "${units[$unit]}"
}

# Print header
header() {
    local message="$*"
    local line_length=70
    local line
    line=$(printf '=%.0s' $(seq 1 $line_length))
    
    if [[ -n "$COLOR_HEADER" ]]; then
        echo ""
        echo -e "${COLOR_HEADER}${line}${NC}"
        echo -e "${COLOR_HEADER}${BOLD}  ${message}${NC}"
        echo -e "${COLOR_HEADER}${line}${NC}"
        echo ""
    else
        echo ""
        echo "$line"
        echo "  $message"
        echo "$line"
        echo ""
    fi
    
    # Log to file
    if [[ "$LOG_FILE_WRITABLE" == "true" ]]; then
        {
            echo ""
            echo "$line"
            echo "  $message"
            echo "$line"
            echo ""
        } >> "$LOG_FILE" 2>/dev/null
    fi
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

# Print separator line
separator() {
    local char="${1:--}"
    local length="${2:-70}"
    local line
    line=$(printf "${char}%.0s" $(seq 1 "$length"))
    echo "$line"
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null
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
        if [[ -n "$GREEN" ]]; then
            printf "\r%s [${GREEN}${SYMBOL_SUCCESS}${NC}]\n" "$message"
        else
            printf "\r%s [${SYMBOL_SUCCESS}]\n" "$message"
        fi
    else
        if [[ -n "$RED" ]]; then
            printf "\r%s [${RED}${SYMBOL_ERROR}${NC}]\n" "$message"
        else
            printf "\r%s [${SYMBOL_ERROR}]\n" "$message"
        fi
    fi
    
    return $exit_status
}

# Print status
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
    
    if [[ -n "$status_color" ]]; then
        echo -e "[${status_color}${status_symbol}${NC}] ${message}"
    else
        echo "[$status_symbol] $message"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "[$status] $message" >> "$LOG_FILE" 2>/dev/null
}

# Print subheader
subheader() {
    local message="$*"
    if [[ -n "$CYAN" ]]; then
        echo -e "${CYAN}${BOLD}${message}${NC}"
    else
        echo "$message"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "$message" >> "$LOG_FILE" 2>/dev/null
}

# ============================================
# INTERACTIVE FUNCTIONS
# ============================================

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

# Ask yes/no question
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

# Confirm action
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    warning "$message"
    echo ""
    ask_yes_no "Are you sure you want to continue?" "$default"
}

# ============================================
# ENHANCED ERROR HANDLING
# ============================================

# Set strict error handling
set_strict_mode() {
    set -euo pipefail
    IFS=$'\n\t'
}

# Error handler with context
error_handler() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    
    error "Error on line $line_number: $command (exit code: $exit_code)"
    
    if [[ "$LOG_FILE_WRITABLE" == "true" ]]; then
        {
            echo "ERROR CONTEXT:"
            echo "  Exit code: $exit_code"
            echo "  Line: $line_number"
            echo "  Command: $command"
            echo "  Working directory: $(pwd)"
            echo "  User: $(whoami)"
            echo "  Date: $(date)"
        } >> "$LOG_FILE" 2>/dev/null
    fi
    
    run_cleanup
    exit "$exit_code"
}

# Set error trap
set_error_trap() {
    trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

# ============================================
# LOGGING FUNCTIONS
# ============================================

# Debug log
debug() {
    _log "DEBUG" "$COLOR_DEBUG" "$SYMBOL_DEBUG" "$*" "$LOG_LEVEL_DEBUG"
}

# Error log
error() {
    _log "ERROR" "$COLOR_ERROR" "$SYMBOL_ERROR" "$*" "$LOG_LEVEL_ERROR" >&2
}

# Info log
info() {
    _log "INFO" "$COLOR_INFO" "$SYMBOL_INFO" "$*" "$LOG_LEVEL_INFO"
}

# Success log
success() {
    _log "SUCCESS" "$COLOR_SUCCESS" "$SYMBOL_SUCCESS" "$*" "$LOG_LEVEL_INFO"
}

# Warning log
warning() {
    _log "WARNING" "$COLOR_WARNING" "$SYMBOL_WARNING" "$*" "$LOG_LEVEL_WARNING"
}

# ============================================
# SYSTEM INFORMATION
# ============================================

# Get system architecture
get_architecture() {
    uname -m
}

# Get available memory in MB
get_available_memory() {
    local mem_kb
    mem_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    echo $((mem_kb / 1024))
}

# Get disk space in MB
get_disk_space() {
    local path="${1:-.}"
    df -m "$path" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0"
}

# Get distribution name
get_distro() {
    if [[ -f /etc/os-release ]]; then
        grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"'
    else
        echo "unknown"
    fi
}

# Get kernel version
get_kernel_version() {
    uname -r
}

# Check if system is UEFI
is_uefi() {
    [[ -d /sys/firmware/efi ]]
}

# ============================================
# UTILITY FUNCTIONS
# ============================================

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
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
            while caller $frame 2>/dev/null; do
                ((frame++))
            done
        } >> "$LOG_FILE" 2>/dev/null
    fi
    
    exit 1
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

# Check if running in chroot
in_chroot() {
    if [[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]]; then
        return 0
    else
        return 1
    fi
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        error "Please run: sudo $0"
        exit 1
    fi
}

# Retry command with exponential backoff
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-1}"
    shift 2
    local cmd=("$@")
    
    local attempt=1
    local exit_code=0
    
    while [[ $attempt -le $max_attempts ]]; do
        debug "Attempt $attempt/$max_attempts: ${cmd[*]}"
        
        if "${cmd[@]}"; then
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
    
    error "Command failed after $max_attempts attempts: ${cmd[*]}"
    return $exit_code
}

# Safe command execution with logging
safe_run() {
    local cmd=("$@")
    
    debug "Executing: ${cmd[*]}"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        info "DRY RUN: Would execute: ${cmd[*]}"
        return 0
    fi
    
    if "${cmd[@]}" 2>&1 | head -1000; then
        debug "Command succeeded: ${cmd[*]}"
        return 0
    else
        local exit_code=$?
        error "Command failed (exit code: $exit_code): ${cmd[*]}"
        return $exit_code
    fi
}

# Sleep with countdown
sleep_countdown() {
    local seconds="$1"
    local message="${2:-Waiting}"
    
    for ((i=seconds; i>0; i--)); do
        echo -ne "\r$message: ${i}s  "
        sleep 1
    done
    echo -e "\r$message: Done!  "
}

# Get timestamp
timestamp() {
    date '+%Y%m%d-%H%M%S'
}

# Get ISO timestamp
timestamp_iso() {
    date '+%Y-%m-%d %H:%M:%S'
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
# PERFORMANCE AND MONITORING
# ============================================

# Time command execution
time_command() {
    local start_time
    local end_time
    local duration
    
    start_time=$(date +%s.%N)
    "$@"
    local exit_code=$?
    end_time=$(date +%s.%N)
    
    duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    info "Command completed in ${duration}s: $*"
    
    return $exit_code
}

# Get system load average
get_load_average() {
    local period="${1:-1}"  # 1, 5, or 15 minutes
    
    case "$period" in
        1) awk '{print $1}' /proc/loadavg ;;
        5) awk '{print $2}' /proc/loadavg ;;
        15) awk '{print $3}' /proc/loadavg ;;
        *) error "Invalid period: $period (use 1, 5, or 15)"; return 1 ;;
    esac
}

# Monitor directory for changes
watch_directory() {
    local directory="$1"
    local callback="$2"
    local timeout="${3:-0}"
    
    if ! command_exists inotifywait; then
        error "inotifywait not available for directory monitoring"
        return 1
    fi
    
    info "Monitoring directory: $directory"
    
    local cmd=(inotifywait -m -e modify,create,delete,move "$directory")
    if [[ $timeout -gt 0 ]]; then
        cmd+=(--timeout "$timeout")
    fi
    
    "${cmd[@]}" | while read -r path action file; do
        debug "Directory change detected: $action $file"
        $callback "$path" "$action" "$file"
    done
}

# ============================================
# VALIDATION FUNCTIONS
# ============================================

# Validate device exists
validate_device() {
    local device="$1"
    local description="${2:-Device}"
    
    if [[ ! -b "$device" ]]; then
        error "$description not found or not a block device: $device"
        return 1
    fi
    
    return 0
}

# Validate directory exists
validate_directory() {
    local dir="$1"
    local description="${2:-Directory}"
    
    if [[ ! -d "$dir" ]]; then
        error "$description not found: $dir"
        return 1
    fi
    
    return 0
}

# Validate file exists
validate_file() {
    local file="$1"
    local description="${2:-File}"
    
    if [[ ! -f "$file" ]]; then
        error "$description not found: $file"
        return 1
    fi
    
    return 0
}

# Validate file is readable
validate_readable() {
    local file="$1"
    local description="${2:-File}"
    
    if [[ ! -r "$file" ]]; then
        error "$description is not readable: $file"
        return 1
    fi
    
    return 0
}

# Validate file is writable
validate_writable() {
    local file="$1"
    local description="${2:-File}"
    
    # Check if file exists and is writable, or directory is writable
    if [[ -f "$file" ]]; then
        if [[ ! -w "$file" ]]; then
            error "$description is not writable: $file"
            return 1
        fi
    else
        local dir
        dir=$(dirname "$file")
        if [[ ! -w "$dir" ]]; then
            error "Cannot write to directory: $dir"
            return 1
        fi
    fi
    
    return 0
}

# ============================================
# SIGNAL TRAPS
# ============================================

# Trap EXIT to run cleanup
trap run_cleanup EXIT

# Trap INT signal (Ctrl+C)
trap 'echo ""; warning "Interrupted by user"; exit 130' INT

# Trap TERM signal
trap 'echo ""; warning "Terminated"; exit 143' TERM

# ============================================
# FUNCTION EXPORTS
# ============================================

# Export functions (for use in subshells)
export -f ask_input ask_yes_no
export -f backup_file bullet
export -f command_exists confirm_action
export -f debug die
export -f ensure_directory error
export -f format_bytes
export -f get_architecture get_available_memory get_disk_space get_distro get_kernel_version
export -f header
export -f in_array in_chroot indent info is_uefi
export -f progress_bar print_status
export -f register_cleanup require_root retry_command run_cleanup
export -f safe_run separator sleep_countdown spinner subheader success
export -f timestamp timestamp_iso trim
export -f validate_device validate_directory validate_file validate_readable validate_writable
export -f warning

# ============================================
# LIBRARY INITIALIZATION COMPLETE
# ============================================

# Initialize log file
_init_log_file

# Log that library was loaded
debug "common.sh library v${COMMON_VERSION} loaded successfully"

# Return success
return 0
