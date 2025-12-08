#!/usr/bin/env bash
# filepath: zfs-services-manager.sh
# ZFS Services Manager for Void Linux
# Version: 1.0
# Description: Manages ZFS-related runit services
# Compatible with voidZFSInstallRepo.sh installation

set -euo pipefail

# ============================================
# Load Common Library
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-/usr/local/lib/zfs-scripts}"

# Try to source common.sh from standard location
if [[ -f "$LIB_DIR/common.sh" ]]; then
    source "$LIB_DIR/common.sh"
# Fallback: try relative to script location (for development)
elif [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
    source "$SCRIPT_DIR/../lib/common.sh"
# Fallback: try same directory as script
elif [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "ERROR: Cannot find common.sh library"
    echo "Please install common.sh to: $LIB_DIR/"
    exit 1
fi

# ============================================
# Script Configuration
# ============================================
LOG_FILE="/var/log/zfs_services.log"
SCRIPT_NAME="ZFS Services Manager"
SCRIPT_VERSION="1.0"

# Redirect all output to both console and log file
exec &> >(tee -a "$LOG_FILE")

# ============================================
# Path Constants (MUST match installation scripts)
# ============================================
# ZFS Core Files
readonly ZFS_KEY_FILE="/etc/zfs/zroot.key"
readonly ZFS_CACHE_FILE="/etc/zfs/zpool.cache"
readonly HOSTID_FILE="/etc/hostid"

# Service directories (Void Linux runit)
readonly SERVICE_DIR="/etc/sv"
readonly RUNSVDIR="/var/service"

# ZFS Services
readonly ZFS_SERVICES=(
    "zfs-import"
    "zfs-mount"
    "zfs-share"
    "zfs-zed"
)

# Optional services
readonly OPTIONAL_SERVICES=(
    "zfs-scrub"
)

# ============================================
# Service Status Functions
# ============================================
get_service_status() {
    local service="$1"
    local service_path="$RUNSVDIR/$service"
    
    if [[ ! -L "$service_path" ]]; then
        echo "disabled"
        return 1
    fi
    
    if sv status "$service" 2>/dev/null | grep -q "^run:"; then
        echo "running"
        return 0
    elif sv status "$service" 2>/dev/null | grep -q "^down:"; then
        echo "stopped"
        return 2
    else
        echo "unknown"
        return 3
    fi
}

check_service_exists() {
    local service="$1"
    
    if [[ -d "$SERVICE_DIR/$service" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================
# Service Management Functions
# ============================================
enable_service() {
    local service="$1"
    
    if ! check_service_exists "$service"; then
        error "Service directory not found: $SERVICE_DIR/$service"
        return 1
    fi
    
    local service_link="$RUNSVDIR/$service"
    
    if [[ -L "$service_link" ]]; then
        info "Service already enabled: $service"
        return 0
    fi
    
    info "Enabling service: $service"
    
    if ln -s "$SERVICE_DIR/$service" "$service_link"; then
        success "Service enabled: $service"
        return 0
    else
        error "Failed to enable service: $service"
        return 1
    fi
}

disable_service() {
    local service="$1"
    local service_link="$RUNSVDIR/$service"
    
    if [[ ! -L "$service_link" ]]; then
        info "Service already disabled: $service"
        return 0
    fi
    
    info "Disabling service: $service"
    
    # Stop service first
    if sv stop "$service" 2>/dev/null; then
        debug "Service stopped: $service"
    fi
    
    # Remove symlink
    if rm -f "$service_link"; then
        success "Service disabled: $service"
        return 0
    else
        error "Failed to disable service: $service"
        return 1
    fi
}

start_service() {
    local service="$1"
    
    if ! check_service_exists "$service"; then
        error "Service not found: $service"
        return 1
    fi
    
    local status
    status=$(get_service_status "$service")
    
    if [[ "$status" == "disabled" ]]; then
        error "Service is disabled. Enable it first: $service"
        return 1
    fi
    
    if [[ "$status" == "running" ]]; then
        info "Service already running: $service"
        return 0
    fi
    
    info "Starting service: $service"
    
    if sv start "$service" 2>/dev/null; then
        sleep 2
        status=$(get_service_status "$service")
        
        if [[ "$status" == "running" ]]; then
            success "Service started: $service"
            return 0
        else
            error "Service failed to start: $service"
            return 1
        fi
    else
        error "Failed to start service: $service"
        return 1
    fi
}

stop_service() {
    local service="$1"
    
    local status
    status=$(get_service_status "$service")
    
    if [[ "$status" == "disabled" ]]; then
        info "Service is disabled: $service"
        return 0
    fi
    
    if [[ "$status" == "stopped" ]] || [[ "$status" == "unknown" ]]; then
        info "Service already stopped: $service"
        return 0
    fi
    
    info "Stopping service: $service"
    
    if sv stop "$service" 2>/dev/null; then
        sleep 1
        success "Service stopped: $service"
        return 0
    else
        error "Failed to stop service: $service"
        return 1
    fi
}

restart_service() {
    local service="$1"
    
    info "Restarting service: $service"
    
    if sv restart "$service" 2>/dev/null; then
        sleep 2
        
        local status
        status=$(get_service_status "$service")
        
        if [[ "$status" == "running" ]]; then
            success "Service restarted: $service"
            return 0
        else
            error "Service failed to restart: $service"
            return 1
        fi
    else
        error "Failed to restart service: $service"
        return 1
    fi
}

# ============================================
# Status Display Functions
# ============================================
show_service_status() {
    local service="$1"
    local status
    status=$(get_service_status "$service")
    
    case "$status" in
        running)
            print_status "ok" "$service: running"
            ;;
        stopped)
            print_status "warn" "$service: stopped"
            ;;
        disabled)
            print_status "skip" "$service: disabled"
            ;;
        *)
            print_status "error" "$service: unknown"
            ;;
    esac
}

list_all_services() {
    header "ZFS Services Status"
    
    subheader "Core ZFS Services:"
    echo ""
    
    for service in "${ZFS_SERVICES[@]}"; do
        show_service_status "$service"
    done
    
    echo ""
    subheader "Optional ZFS Services:"
    echo ""
    
    for service in "${OPTIONAL_SERVICES[@]}"; do
        if check_service_exists "$service"; then
            show_service_status "$service"
        else
            print_status "skip" "$service: not installed"
        fi
    done
    
    echo ""
}

show_service_details() {
    local service="$1"
    
    header "Service Details: $service"
    
    if ! check_service_exists "$service"; then
        error "Service not found: $service"
        return 1
    fi
    
    # Basic info
    info "Service directory: $SERVICE_DIR/$service"
    
    local service_link="$RUNSVDIR/$service"
    if [[ -L "$service_link" ]]; then
        info "Enabled: yes"
        info "Service link: $service_link"
    else
        warning "Enabled: no"
    fi
    
    echo ""
    
    # Status from sv
    subheader "Service Status:"
    echo ""
    sv status "$service" 2>/dev/null || echo "Service not running"
    
    echo ""
    
    # Log file check
    local log_file="/var/log/socklog/svlogd/$service/current"
    if [[ -f "$log_file" ]]; then
        subheader "Recent Log Entries (last 10):"
        echo ""
        tail -n 10 "$log_file" 2>/dev/null || warning "Could not read log file"
    else
        warning "Log file not found: $log_file"
    fi
    
    echo ""
}

# ============================================
# Batch Operations
# ============================================
enable_all_services() {
    header "Enabling All ZFS Services"
    
    local failed=0
    
    for service in "${ZFS_SERVICES[@]}"; do
        if enable_service "$service"; then
            debug "Enabled: $service"
        else
            warning "Failed to enable: $service"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    
    if [[ $failed -eq 0 ]]; then
        success "All ZFS services enabled successfully"
        return 0
    else
        warning "$failed service(s) failed to enable"
        return 1
    fi
}

disable_all_services() {
    header "Disabling All ZFS Services"
    
    if ! confirm_action "This will disable all ZFS services" "n"; then
        info "Operation cancelled"
        return 1
    fi
    
    local failed=0
    
    for service in "${ZFS_SERVICES[@]}"; do
        if disable_service "$service"; then
            debug "Disabled: $service"
        else
            warning "Failed to disable: $service"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    
    if [[ $failed -eq 0 ]]; then
        success "All ZFS services disabled successfully"
        return 0
    else
        warning "$failed service(s) failed to disable"
        return 1
    fi
}

start_all_services() {
    header "Starting All ZFS Services"
    
    local failed=0
    
    # Start in dependency order
    local ordered_services=(
        "zfs-import"    # Import pools first
        "zfs-mount"     # Mount datasets
        "zfs-share"     # Share datasets (NFS/SMB)
        "zfs-zed"       # ZFS Event Daemon
    )
    
    for service in "${ordered_services[@]}"; do
        if start_service "$service"; then
            debug "Started: $service"
        else
            warning "Failed to start: $service"
            failed=$((failed + 1))
        fi
        
        # Brief delay between services
        sleep 1
    done
    
    echo ""
    
    if [[ $failed -eq 0 ]]; then
        success "All ZFS services started successfully"
        return 0
    else
        warning "$failed service(s) failed to start"
        return 1
    fi
}

stop_all_services() {
    header "Stopping All ZFS Services"
    
    if ! confirm_action "This will stop all ZFS services" "n"; then
        info "Operation cancelled"
        return 1
    fi
    
    local failed=0
    
    # Stop in reverse dependency order
    local ordered_services=(
        "zfs-zed"       # Stop daemon first
        "zfs-share"     # Unshare
        "zfs-mount"     # Unmount (but datasets may remain mounted)
        "zfs-import"    # Stop import service
    )
    
    for service in "${ordered_services[@]}"; do
        if stop_service "$service"; then
            debug "Stopped: $service"
        else
            warning "Failed to stop: $service"
            failed=$((failed + 1))
        fi
        
        # Brief delay between services
        sleep 1
    done
    
    echo ""
    
    if [[ $failed -eq 0 ]]; then
        success "All ZFS services stopped successfully"
        return 0
    else
        warning "$failed service(s) failed to stop"
        return 1
    fi
}

restart_all_services() {
    header "Restarting All ZFS Services"
    
    if ! confirm_action "This will restart all ZFS services" "n"; then
        info "Operation cancelled"
        return 1
    fi
    
    # Stop all first
    stop_all_services
    
    echo ""
    separator "-"
    echo ""
    
    # Then start all
    start_all_services
}

# ============================================
# Verification Functions
# ============================================
verify_zfs_services() {
    header "Verifying ZFS Services Configuration"
    
    local issues_found=0
    
    # Check if ZFS module is loaded
    subheader "ZFS Module:"
    echo ""
    
    if lsmod 2>/dev/null | grep -q "^zfs "; then
        success "ZFS kernel module is loaded"
    else
        error "ZFS kernel module is NOT loaded"
        info "Load with: modprobe zfs"
        issues_found=$((issues_found + 1))
    fi
    
    echo ""
    
    # Check service directories exist
    subheader "Service Directories:"
    echo ""
    
    for service in "${ZFS_SERVICES[@]}"; do
        if [[ -d "$SERVICE_DIR/$service" ]]; then
            print_status "ok" "$service directory exists"
        else
            print_status "error" "$service directory missing"
            issues_found=$((issues_found + 1))
        fi
    done
    
    echo ""
    
    # Check critical files
    subheader "Critical Files:"
    echo ""
    
    if [[ -f "$HOSTID_FILE" ]]; then
        print_status "ok" "Host ID file exists"
    else
        print_status "error" "Host ID file missing: $HOSTID_FILE"
        info "Generate with: zgenhostid"
        issues_found=$((issues_found + 1))
    fi
    
    if [[ -f "$ZFS_CACHE_FILE" ]]; then
        print_status "ok" "Pool cache exists"
    else
        print_status "warn" "Pool cache missing: $ZFS_CACHE_FILE"
        info "Will be created on first pool import"
    fi
    
    echo ""
    
    # Check pools
    subheader "ZFS Pools:"
    echo ""
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        warning "No ZFS pools found"
        info "Import pools with: zpool import -a"
    else
        local pool_count
        pool_count=$(echo "$pools" | wc -l)
        success "Found $pool_count pool(s)"
        
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            
            local health
            health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
            
            case "$health" in
                ONLINE)
                    print_status "ok" "Pool $pool: $health"
                    ;;
                DEGRADED)
                    print_status "warn" "Pool $pool: $health"
                    issues_found=$((issues_found + 1))
                    ;;
                *)
                    print_status "error" "Pool $pool: $health"
                    issues_found=$((issues_found + 1))
                    ;;
            esac
        done <<< "$pools"
    fi
    
    echo ""
    
    # Summary
    separator "="
    echo ""
    
    if [[ $issues_found -eq 0 ]]; then
        success "Verification complete: No issues found"
        return 0
    else
        warning "Verification complete: $issues_found issue(s) found"
        return 1
    fi
}

# ============================================
# Usage/Help
# ============================================
usage() {
    cat << EOF
Usage: $0 <command> [service]

$SCRIPT_NAME v$SCRIPT_VERSION

Manages ZFS-related runit services on Void Linux.

COMMANDS:

Service Management:
    status [service]        Show status of service(s)
    start <service>         Start a service
    stop <service>          Stop a service
    restart <service>       Restart a service
    enable <service>        Enable a service
    disable <service>       Disable a service
    details <service>       Show detailed service information

Batch Operations:
    list                    List all ZFS services and their status
    enable-all              Enable all ZFS services
    disable-all             Disable all ZFS services
    start-all               Start all ZFS services
    stop-all                Stop all ZFS services
    restart-all             Restart all ZFS services

Verification:
    verify                  Verify ZFS services configuration

Help:
    help                    Show this help message

SERVICES:

Core ZFS Services:
    zfs-import              Import ZFS pools at boot
    zfs-mount               Mount ZFS datasets
    zfs-share               Share ZFS datasets (NFS/SMB)
    zfs-zed                 ZFS Event Daemon

Optional Services:
    zfs-scrub               Automated scrub scheduling (if installed)

EXAMPLES:

    $0 status                    # Show status of all services
    $0 status zfs-import         # Show status of specific service
    $0 start zfs-zed             # Start ZFS Event Daemon
    $0 restart-all               # Restart all ZFS services
    $0 enable-all                # Enable all ZFS services
    $0 verify                    # Verify ZFS configuration

EXIT CODES:
    0    Success
    1    Error or issues found

LOG FILE:
    $LOG_FILE

EOF
    exit 0
}

# ============================================
# Main Execution
# ============================================
main() {
    local command="${1:-}"
    local service="${2:-}"
    
    # Require root for most operations
    if [[ "$command" != "help" ]] && [[ "$command" != "status" ]] && [[ "$command" != "list" ]] && [[ "$command" != "details" ]]; then
        require_root
    fi
    
    case "$command" in
        status)
            if [[ -n "$service" ]]; then
                header "Service Status"
                show_service_status "$service"
            else
                list_all_services
            fi
            ;;
        
        start)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            start_service "$service"
            ;;
        
        stop)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            stop_service "$service"
            ;;
        
        restart)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            restart_service "$service"
            ;;
        
        enable)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            enable_service "$service"
            ;;
        
        disable)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            disable_service "$service"
            ;;
        
        details)
            if [[ -z "$service" ]]; then
                error "Service name required"
                usage
            fi
            show_service_details "$service"
            ;;
        
        list)
            list_all_services
            ;;
        
        enable-all)
            enable_all_services
            ;;
        
        disable-all)
            disable_all_services
            ;;
        
        start-all)
            start_all_services
            ;;
        
        stop-all)
            stop_all_services
            ;;
        
        restart-all)
            restart_all_services
            ;;
        
        verify)
            verify_zfs_services
            ;;
        
        help|--help|-h|"")
            usage
            ;;
        
        *)
            error "Unknown command: $command"
            echo ""
            usage
            ;;
    esac
}

# Run main function
main "$@"
```
