#!/bin/bash
# zfs-services-manager.sh
# Combined audit and setup script for ZFS services on Void Linux
# Version: 2.0 - Refactored to use common.sh library

set -euo pipefail

# ============================================
# Load Common Library
# ============================================
# Determine script and library directories
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
    echo "Searched locations:"
    echo "  - $LIB_DIR/common.sh"
    echo "  - $SCRIPT_DIR/../lib/common.sh"
    echo "  - $SCRIPT_DIR/common.sh"
    echo ""
    echo "Please install common.sh to: $LIB_DIR/"
    exit 1
fi

# ============================================
# Script Configuration
# ============================================
# Set custom log file for this script
LOG_FILE="/var/log/zfs-services-manager.log"

# Script metadata
SCRIPT_NAME="ZFS Services Manager"
SCRIPT_VERSION="2.0"

# ============================================
# Audit Functions
# ============================================
audit_service_existence() {
    header "1. ZFS Services Availability"
    
    local services=("zed" "zfs-import" "zfs-mount" "zfs-share")
    local found_services=()
    
    for service in "${services[@]}"; do
        if [[ -d "/etc/sv/$service" ]]; then
            local enabled_status="disabled"
            local running_status="stopped"
            
            if [[ -L "/etc/runit/runsvdir/default/$service" ]]; then
                enabled_status="ENABLED"
            fi
            
            if sv status "$service" 2>/dev/null | grep -q "^run:"; then
                running_status="RUNNING"
            fi
            
            bullet "$service: EXISTS | $enabled_status | $running_status"
            found_services+=("$service")
        else
            indent 1 "❌ $service: DOES NOT EXIST"
        fi
    done
    
    echo ""
    
    if [[ ${#found_services[@]} -eq 0 ]]; then
        error "No ZFS services found!"
        error "Is ZFS installed? Try: xbps-install -S zfs"
        return 1
    fi
    
    success "Found ${#found_services[@]} ZFS service(s)"
    return 0
}

audit_pools() {
    header "2. ZFS Pool Status"
    
    if ! command_exists zpool; then
        error "zpool command not found"
        return 1
    fi
    
    local pool_count
    pool_count=$(zpool list -H 2>/dev/null | wc -l)
    
    if [[ $pool_count -eq 0 ]]; then
        warning "No ZFS pools found"
        return 1
    fi
    
    info "Found $pool_count pool(s)"
    echo ""
    
    zpool list -H -o name,health,size,allocated,free 2>/dev/null | while IFS=$'\t' read -r pool health size alloc free; do
        subheader "Pool: $pool"
        
        if [[ "$health" == "ONLINE" ]]; then
            print_status "ok" "Health: $health"
        else
            print_status "fail" "Health: $health"
        fi
        
        indent 1 "Size: $size (Allocated: $alloc, Free: $free)"
        
        # Check if this is the boot pool
        local bootfs
        bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
        if [[ "$bootfs" != "-" ]]; then
            indent 1 "Type: ROOT POOL (bootfs: $bootfs)"
        else
            indent 1 "Type: Data pool"
        fi
        
        # Check cache file
        local cachefile
        cachefile=$(zpool get -H -o value cachefile "$pool" 2>/dev/null || echo "-")
        if [[ "$cachefile" != "-" ]] && [[ "$cachefile" != "none" ]]; then
            print_status "ok" "Cache file: $cachefile (auto-import enabled)"
        else
            print_status "warn" "Cache file: None (requires zfs-import service)"
        fi
        
        echo ""
    done
    
    return 0
}

audit_datasets() {
    header "3. ZFS Dataset Mount Configuration"
    
    if ! command_exists zfs; then
        error "zfs command not found"
        return 1
    fi
    
    local dataset_count
    dataset_count=$(zfs list -H 2>/dev/null | wc -l)
    
    if [[ $dataset_count -eq 0 ]]; then
        warning "No ZFS datasets found"
        return 1
    fi
    
    info "Found $dataset_count dataset(s)"
    echo ""
    
    zfs list -H -o name,mountpoint,canmount,mounted -r 2>/dev/null | while IFS=$'\t' read -r dataset mountpoint canmount mounted; do
        local mount_method=""
        local needs_service=""
        
        case "$mountpoint" in
            none|-)
                mount_method="Not mounted"
                ;;
            legacy)
                mount_method="Via /etc/fstab (legacy)"
                ;;
            /*)
                case "$canmount" in
                    on)
                        mount_method="Via zfs-mount (automatic)"
                        needs_service="zfs-mount"
                        ;;
                    noauto)
                        mount_method="Manual mount required"
                        ;;
                    off)
                        mount_method="Cannot mount (canmount=off)"
                        ;;
                esac
                ;;
        esac
        
        subheader "$dataset"
        indent 1 "Mountpoint: $mountpoint"
        indent 1 "Canmount: $canmount"
        indent 1 "Currently mounted: $mounted"
        indent 1 "Method: $mount_method"
        [[ -n "$needs_service" ]] && indent 1 "Requires: $needs_service"
        echo ""
    done
    
    return 0
}

analyze_requirements() {
    header "4. Service Requirements Analysis"
    
    local needs_import=false
    local needs_mount=false
    local needs_share=false
    
    # Determine root pool
    local root_pool
    root_pool=$(zpool list -H -o name,bootfs 2>/dev/null | awk '$2 != "-" {print $1}' | head -n1)
    
    if [[ -z "$root_pool" ]]; then
        warning "Could not determine root pool"
        root_pool="zroot"  # Assume default
    fi
    
    info "Root pool detected: $root_pool"
    echo ""
    
    # Check for data pools (non-root pools)
    local all_pools
    all_pools=$(zpool list -H -o name 2>/dev/null || echo "")
    local pool_count
    pool_count=$(echo "$all_pools" | grep -c . || echo "0")
    
    subheader "Analysis Results:"
    echo ""
    
    # ZED - Always needed
    bullet "zed (ZFS Event Daemon):"
    indent 2 "Status: ✅ ALWAYS REQUIRED"
    indent 2 "Reason: Monitors ZFS events, handles errors, sends notifications"
    echo ""
    
    # zfs-import - Check if needed
    bullet "zfs-import (Pool Import):"
    if [[ $pool_count -gt 1 ]]; then
        needs_import=true
        indent 2 "Status: ✅ REQUIRED"
        indent 2 "Reason: You have $pool_count pools, including data pools:"
        echo "$all_pools" | while read -r pool; do
            if [[ "$pool" != "$root_pool" ]]; then
                indent 3 "- $pool (data pool, needs auto-import)"
            else
                indent 3 "- $pool (root pool, imported by initramfs)"
            fi
        done
    else
        indent 2 "Status: ⚠️  NOT REQUIRED"
        indent 2 "Reason: Only root pool ($root_pool) present"
        indent 2 "        Root pool is imported by initramfs during boot"
    fi
    echo ""
    
    # zfs-mount - Check if needed
    bullet "zfs-mount (Filesystem Mount):"
    local native_mounts
    native_mounts=$(zfs list -H -o name,mountpoint,canmount 2>/dev/null | awk '$2 ~ /^\// && $2 != "/" && $3 == "on"' | wc -l)
    
    if [[ $native_mounts -gt 0 ]]; then
        needs_mount=true
        indent 2 "Status: ✅ REQUIRED"
        indent 2 "Reason: $native_mounts dataset(s) with native mountpoints need automatic mounting:"
        zfs list -H -o name,mountpoint,canmount 2>/dev/null | awk '$2 ~ /^\// && $2 != "/" && $3 == "on" {print "        - " $1 " → " $2}'
    else
        indent 2 "Status: ⚠️  NOT REQUIRED"
        indent 2 "Reason: No datasets with native mountpoints requiring auto-mount"
        indent 2 "        (All use legacy mounts or are manually managed)"
    fi
    echo ""
    
    # zfs-share - Check if needed
    bullet "zfs-share (NFS/SMB Sharing):"
    local shared_datasets
    shared_datasets=$(zfs list -H -o name,sharenfs,sharesmb 2>/dev/null | awk '$2 != "off" || $3 != "off"' | wc -l)
    
    if [[ $shared_datasets -gt 0 ]]; then
        needs_share=true
        indent 2 "Status: ✅ REQUIRED"
        indent 2 "Reason: $shared_datasets dataset(s) configured for sharing"
    else
        indent 2 "Status: ⚠️  NOT REQUIRED"
        indent 2 "Reason: No datasets configured for NFS or SMB sharing"
    fi
    echo ""
    
    # Store requirements in temp files
    echo "$needs_import" > /tmp/zfs_needs_import
    echo "$needs_mount" > /tmp/zfs_needs_mount
    echo "$needs_share" > /tmp/zfs_needs_share
}

# ============================================
# Setup Functions
# ============================================
enable_service() {
    local service="$1"
    local reason="$2"
    
    if [[ ! -d "/etc/sv/$service" ]]; then
        error "Service $service does not exist at /etc/sv/$service"
        return 1
    fi
    
    info "Enabling service: $service"
    debug "Reason: $reason"
    
    # Create symlink if doesn't exist
    if [[ ! -L "/etc/runit/runsvdir/default/$service" ]]; then
        if ln -sf "/etc/sv/$service" "/etc/runit/runsvdir/default/" 2>/dev/null; then
            success "Service $service enabled"
        else
            error "Failed to enable $service"
            return 1
        fi
    else
        info "Service $service already enabled"
    fi
    
    # Start service
    if sv status "$service" 2>/dev/null | grep -q "^run:"; then
        info "Service $service already running"
    else
        info "Starting service $service..."
        if sv up "$service" 2>/dev/null; then
            sleep 1
            if sv status "$service" 2>/dev/null | grep -q "^run:"; then
                success "Service $service started"
            else
                warning "Service $service enabled but not running (will start on next boot)"
            fi
        else
            warning "Failed to start $service (may start on next boot)"
        fi
    fi
    echo ""
}

disable_service() {
    local service="$1"
    local reason="$2"
    
    info "Service $service not needed"
    debug "Reason: $reason"
    
    if [[ -L "/etc/runit/runsvdir/default/$service" ]]; then
        warning "Service is currently enabled but not required"
        if ask_yes_no "Disable it?" "n"; then
            if rm "/etc/runit/runsvdir/default/$service" 2>/dev/null; then
                sv down "$service" 2>/dev/null || true
                success "Service $service disabled"
            else
                error "Failed to disable $service"
                return 1
            fi
        else
            info "Keeping service enabled as per user choice"
        fi
    else
        info "Service already disabled"
    fi
    echo ""
}

setup_services() {
    header "5. Service Setup"
    
    # Read requirements from analysis
    local needs_import
    local needs_mount
    local needs_share
    
    needs_import=$(cat /tmp/zfs_needs_import 2>/dev/null || echo "false")
    needs_mount=$(cat /tmp/zfs_needs_mount 2>/dev/null || echo "false")
    needs_share=$(cat /tmp/zfs_needs_share 2>/dev/null || echo "false")
    
    # Clean up temp files
    rm -f /tmp/zfs_needs_import /tmp/zfs_needs_mount /tmp/zfs_needs_share
    
    info "Configuring ZFS services based on analysis..."
    echo ""
    
    # ZED - Always enable
    enable_service "zed" "Event monitoring and error handling (always required)"
    
    # zfs-import - Conditional
    if [[ "$needs_import" == "true" ]]; then
        enable_service "zfs-import" "Data pools need automatic import at boot"
    else
        disable_service "zfs-import" "Only root pool present (imported by initramfs)"
    fi
    
    # zfs-mount - Conditional
    if [[ "$needs_mount" == "true" ]]; then
        enable_service "zfs-mount" "Datasets with native mountpoints need automatic mounting"
    else
        disable_service "zfs-mount" "No datasets require automatic mounting"
    fi
    
    # zfs-share - Conditional
    if [[ -d "/etc/sv/zfs-share" ]]; then
        if [[ "$needs_share" == "true" ]]; then
            enable_service "zfs-share" "Datasets configured for NFS/SMB sharing"
        else
            disable_service "zfs-share" "No datasets configured for sharing"
        fi
    fi
}

verify_setup() {
    header "6. Verification"
    
    info "Checking service status..."
    echo ""
    
    local services=("zed" "zfs-import" "zfs-mount" "zfs-share")
    local all_ok=true
    
    for service in "${services[@]}"; do
        if [[ ! -d "/etc/sv/$service" ]]; then
            continue
        fi
        
        local enabled=false
        local running=false
        
        [[ -L "/etc/runit/runsvdir/default/$service" ]] && enabled=true
        sv status "$service" 2>/dev/null | grep -q "^run:" && running=true
        
        if $enabled && $running; then
            print_status "ok" "$service: Enabled and Running"
        elif $enabled && ! $running; then
            print_status "warn" "$service: Enabled but Not Running"
            warning "Service $service is enabled but not running"
            all_ok=false
        elif ! $enabled && $running; then
            print_status "warn" "$service: Running but Not Enabled"
            info "Service $service is running but won't start on boot"
        else
            print_status "skip" "$service: Disabled"
        fi
    done
    
    echo ""
    
    if $all_ok; then
        success "All enabled services are running correctly"
    else
        warning "Some services may need attention"
    fi
}

show_summary() {
    header "Summary"
    
    success "ZFS Service Configuration Complete!"
    echo ""
    
    subheader "Configured Services:"
    echo ""
    
    for service in zed zfs-import zfs-mount zfs-share; do
        if [[ -L "/etc/runit/runsvdir/default/$service" ]]; then
            bullet "$service (enabled)"
        elif [[ -d "/etc/sv/$service" ]]; then
            indent 1 "⊝ $service (available but disabled)"
        fi
    done
    
    echo ""
    separator "="
    echo ""
    
    info "Service management commands:"
    indent 1 "• Check status:  sv status <service>"
    indent 1 "• Start service: sv up <service>"
    indent 1 "• Stop service:  sv down <service>"
    indent 1 "• Restart:       sv restart <service>"
    echo ""
    
    info "Log file location: $LOG_FILE"
    info "To re-run this script: sudo $0"
}

# ============================================
# Main Execution
# ============================================
main() {
    # Check root privileges
    require_root
    
    # Script header
    header "$SCRIPT_NAME v$SCRIPT_VERSION for Void Linux"
    info "This script will audit your ZFS setup and configure services"
    info "Log file: $LOG_FILE"
    echo ""
    
    # Run audit
    if ! audit_service_existence; then
        die "Cannot continue without ZFS services"
    fi
    
    if ! audit_pools; then
        warning "No pools found, but continuing with audit"
    fi
    
    if ! audit_datasets; then
        warning "No datasets found, but continuing with audit"
    fi
    
    analyze_requirements
    
    # Ask for confirmation before setup
    separator "="
    echo ""
    if ask_yes_no "Do you want to configure services based on this analysis?" "y"; then
        setup_services
        verify_setup
        show_summary
    else
        info "Setup cancelled by user"
        info "Services were not modified"
    fi
    
    echo ""
    success "Script completed successfully"
}

# Run main function
main "$@"