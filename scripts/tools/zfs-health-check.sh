#!/usr/bin/env bash
# filepath: zfs-health-check.sh
# ZFS Health Check Script
# Version: 3.3
# Description: Comprehensive ZFS pool and dataset health monitoring with repair capabilities
#
# This script checks:
# - Pool status and health
# - Scrub status and errors
# - Dataset quotas and usage
# - Snapshot status
# - I/O errors and checksums
# - Fragmentation levels
# - System configuration (hostid, cache, dracut, initramfs, ZFSBootMenu)
# - Critical files in initramfs (pool keys, hostid)
# - Boot filesystem configuration
# - Pool encryption status
#
# Usage:
#   sudo bash zfs-health-check.sh [options]
#
# Options:
#   --pool <name>         Check specific pool (default: all pools)
#   --repair              Enable automatic repair of configuration issues
#   --verbose             Show detailed output
#   --help                Show this help message

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
    echo "ERROR: common.sh library not found!"
    echo "Searched locations:"
    echo "  - $LIB_DIR/common.sh"
    echo "  - $SCRIPT_DIR/../lib/common.sh"
    echo "  - $SCRIPT_DIR/common.sh"
    exit 1
fi


# Enable strict mode and error trapping
set_strict_mode      # Sets: set -euo pipefail
set_error_trap       # Traps ERR signal

# ============================================
# Load Configuration
# ============================================
load_config "zfs-setup.conf"

# ============================================
# Script Configuration
# ============================================
SCRIPT_NAME="zfs-health-check"
SCRIPT_VERSION="3.3"
LOG_FILE="${LOG_FILE:-/var/log/zfs-health-check.log}"
USE_LOG_FILE=true

# ============================================
# Global Variables
# ============================================
REPAIR_MODE=false
VERBOSE_MODE=false
TARGET_POOL=""
SNAPSHOT_ON_SUCCESS=false

# Check counters
declare -g CHECK_OK=0
declare -g CHECK_WARN=0
declare -g CHECK_ERROR=0

# Issue tracking
declare -gA POOL_ERRORS
declare -gA POOL_WARNINGS
declare -gA SYSTEM_ISSUES
declare -gA SYSTEM_REPAIRS
declare -gA BOOTFS_CANDIDATES

# ============================================
# Utility Functions
# ============================================

increment_check() {
    local status="$1"
    case "$status" in
        ok|success)
            ((CHECK_OK++))
            ;;
        warn|warning)
            ((CHECK_WARN++))
            ;;
        error|fail)
            ((CHECK_ERROR++))
            ;;
    esac
}

get_pools() {
    zpool list -H -o name 2>/dev/null || echo ""
}

get_pool_key_file() {
    local pool="$1"
    echo "/etc/zfs/${pool}.key"
}

get_all_pool_keys() {
    local pools=("$@")
    local keys=()
    
    for pool in "${pools[@]}"; do
        local key_file="/etc/zfs/${pool}.key"
        if [[ -f "$key_file" ]]; then
            keys+=("$key_file")
        fi
    done
    
    echo "${keys[@]}"
}

show_usage() {
    cat <<EOF
ZFS Health Check Script v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  --pool <name>         Check specific pool only (default: all pools)
  --repair              Enable automatic repair mode
  --verbose             Show detailed output
  --snapshot            Create snapshot on 100% success
  --help                Show this help message

Examples:
  $(basename "$0")                    # Check all pools
  $(basename "$0") --pool zroot       # Check specific pool
  $(basename "$0") --repair           # Check and repair issues
  $(basename "$0") --verbose          # Detailed output
  $(basename "$0") --snapshot         # Create snapshot if all checks pass

EOF
}

# ============================================
# Pool Health Check Functions
# ============================================

check_pool_status() {
    local pool="$1"
    
    debug "Checking pool status: $pool"
    
    local status
    status=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
    
    case "$status" in
        ONLINE)
            print_status "ok" "Pool status: ONLINE"
            increment_check "ok"
            ;;
        DEGRADED)
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Pool is DEGRADED"
            print_status "warn" "Pool status: DEGRADED"
            increment_check "warn"
            ;;
        FAULTED|OFFLINE|UNAVAIL)
            POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Pool is $status"
            print_status "error" "Pool status: $status"
            increment_check "error"
            ;;
        *)
            POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Unknown pool status: $status"
            print_status "error" "Pool status: $status"
            increment_check "error"
            ;;
    esac
    
    # Check for errors
    local errors
    errors=$(zpool status "$pool" | grep -E "errors:" | awk '{print $2}' || echo "")
    
    if [[ "$errors" == "No" ]] || [[ "$errors" == "0" ]]; then
        print_status "ok" "No pool errors detected"
        increment_check "ok"
    else
        POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Pool has errors: $errors"
        print_status "error" "Pool errors detected: $errors"
        increment_check "error"
    fi
}

check_pool_capacity() {
    local pool="$1"
    
    debug "Checking pool capacity: $pool"
    
    local capacity
    capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%' || echo "0")
    
    if [[ $capacity -ge ${CAPACITY_CRITICAL:-90} ]]; then
        POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Capacity critical: ${capacity}%"
        print_status "error" "Capacity: ${capacity}% (critical)"
        increment_check "error"
    elif [[ $capacity -ge ${CAPACITY_WARNING:-80} ]]; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Capacity high: ${capacity}%"
        print_status "warn" "Capacity: ${capacity}% (warning)"
        increment_check "warn"
    else
        print_status "ok" "Capacity: ${capacity}%"
        increment_check "ok"
    fi
}

check_pool_fragmentation() {
    local pool="$1"
    
    debug "Checking pool fragmentation: $pool"
    
    local frag
    frag=$(zpool list -H -o frag "$pool" 2>/dev/null | tr -d '%' || echo "0")
    
    if [[ "$frag" == "-" ]]; then
        print_status "info" "Fragmentation: N/A"
        increment_check "ok"
        return 0
    fi
    
    if [[ $frag -ge ${FRAGMENTATION_CRITICAL:-70} ]]; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; High fragmentation: ${frag}%"
        print_status "warn" "Fragmentation: ${frag}% (critical)"
        increment_check "warn"
    elif [[ $frag -ge ${FRAGMENTATION_WARNING:-50} ]]; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Moderate fragmentation: ${frag}%"
        print_status "warn" "Fragmentation: ${frag}% (warning)"
        increment_check "warn"
    else
        print_status "ok" "Fragmentation: ${frag}%"
        increment_check "ok"
    fi
}

check_scrub_status() {
    local pool="$1"
    
    debug "Checking scrub status: $pool"
    
    local scrub_status
    scrub_status=$(zpool status "$pool" | grep -A 2 "scan:" || echo "")
    
    if [[ -z "$scrub_status" ]]; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; No scrub information"
        print_status "warn" "No scrub information available"
        increment_check "warn"
        return 0
    fi
    
    # Check if scrub is in progress
    if echo "$scrub_status" | grep -q "scrub in progress"; then
        print_status "info" "Scrub in progress"
        increment_check "ok"
        return 0
    fi
    
    # Check if resilver is in progress
    if echo "$scrub_status" | grep -q "resilver in progress"; then
        print_status "info" "Resilver in progress"
        increment_check "ok"
        return 0
    fi
    
    # Check for scrub completed
    if echo "$scrub_status" | grep -q "scrub repaired"; then
        local repaired
        repaired=$(echo "$scrub_status" | grep "scrub repaired" | awk '{print $3}')
        
        if [[ "$repaired" == "0B" ]] || [[ "$repaired" == "0" ]]; then
            print_status "ok" "Last scrub: no repairs needed"
            increment_check "ok"
        else
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Last scrub repaired: $repaired"
            print_status "warn" "Last scrub repaired: $repaired"
            increment_check "warn"
        fi
    fi
    
    # Check scrub age
    if echo "$scrub_status" | grep -q "scrub completed"; then
        local scrub_date
        scrub_date=$(echo "$scrub_status" | grep "scrub completed" | sed -n 's/.*on \(.*\)/\1/p' || echo "")
        
        if [[ -n "$scrub_date" ]]; then
            local scrub_epoch
            scrub_epoch=$(date -d "$scrub_date" +%s 2>/dev/null || echo "0")
            local current_epoch
            current_epoch=$(date +%s)
            local days_since_scrub=$(( (current_epoch - scrub_epoch) / 86400 ))
            
            if [[ $days_since_scrub -ge ${SCRUB_AGE_CRITICAL:-60} ]]; then
                POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Last scrub: ${days_since_scrub} days ago"
                print_status "warn" "Last scrub: ${days_since_scrub} days ago (critical)"
                increment_check "warn"
            elif [[ $days_since_scrub -ge ${SCRUB_AGE_WARNING:-30} ]]; then
                POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Last scrub: ${days_since_scrub} days ago"
                print_status "warn" "Last scrub: ${days_since_scrub} days ago (warning)"
                increment_check "warn"
            else
                print_status "ok" "Last scrub: ${days_since_scrub} days ago"
                increment_check "ok"
            fi
        fi
    elif echo "$scrub_status" | grep -q "none requested"; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; No scrub has been performed"
        print_status "warn" "No scrub has been performed"
        increment_check "warn"
    fi
}

check_dataset_quotas() {
    local pool="$1"
    
    debug "Checking dataset quotas: $pool"
    
    local datasets_with_quotas
    datasets_with_quotas=$(zfs list -H -o name,quota,used -r "$pool" | awk '$2 != "-" && $2 != "none"' || echo "")
    
    if [[ -z "$datasets_with_quotas" ]]; then
        print_status "info" "No quota limits configured"
        increment_check "ok"
        return 0
    fi
    
    local quota_issues=0
    while IFS=$'\t' read -r dataset quota used; do
        local quota_bytes
        quota_bytes=$(numfmt --from=iec "$quota" 2>/dev/null || echo "0")
        local used_bytes
        used_bytes=$(numfmt --from=iec "$used" 2>/dev/null || echo "0")
        
        if [[ $quota_bytes -gt 0 ]]; then
            local usage_percent=$(( used_bytes * 100 / quota_bytes ))
            
            if [[ $usage_percent -ge 95 ]]; then
                POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Quota ${usage_percent}% on $dataset"
                print_status "warn" "Dataset $dataset: ${usage_percent}% of quota"
                ((quota_issues++))
            fi
        fi
    done <<< "$datasets_with_quotas"
    
    if [[ $quota_issues -eq 0 ]]; then
        print_status "ok" "All quotas within limits"
        increment_check "ok"
    else
        increment_check "warn"
    fi
}

check_snapshot_count() {
    local pool="$1"
    
    debug "Checking snapshot count: $pool"
    
    local datasets
    datasets=$(zfs list -H -o name -r "$pool" -t filesystem,volume 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        print_status "info" "No datasets found"
        increment_check "ok"
        return 0
    fi
    
    local excessive_snapshots=0
    local max_snapshots=${MAX_SNAPSHOTS_PER_DATASET:-1000}
    
    while IFS= read -r dataset; do
        local snapshot_count
        snapshot_count=$(zfs list -H -o name -t snapshot -r "$dataset" 2>/dev/null | wc -l || echo "0")
        
        if [[ $snapshot_count -gt $max_snapshots ]]; then
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Excessive snapshots on $dataset: $snapshot_count"
            print_status "warn" "Dataset $dataset: $snapshot_count snapshots (exceeds $max_snapshots)"
            ((excessive_snapshots++))
        fi
    done <<< "$datasets"
    
    if [[ $excessive_snapshots -eq 0 ]]; then
        print_status "ok" "Snapshot counts within limits"
        increment_check "ok"
    else
        increment_check "warn"
    fi
}

check_pool_features() {
    local pool="$1"
    
    debug "Checking pool features: $pool"
    
    # Check for unsupported features
    local unsupported
    unsupported=$(zpool get -H all "$pool" | grep "feature@" | grep "unsupported" || echo "")
    
    if [[ -n "$unsupported" ]]; then
        POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Unsupported features detected"
        print_status "error" "Unsupported features detected"
        increment_check "error"
    else
        print_status "ok" "All features supported"
        increment_check "ok"
    fi
}

check_pool_encryption() {
    local pool="$1"
    
    debug "Checking pool encryption: $pool"
    
    # Check if pool/datasets are encrypted
    local encrypted_datasets
    encrypted_datasets=$(zfs get -H -o name,value encryption -r "$pool" | grep -v "off$" | grep -v "^encryption" || echo "")
    
    if [[ -z "$encrypted_datasets" ]]; then
        print_status "info" "Pool has no encryption"
        increment_check "ok"
        return 0
    fi
    
    # Count encrypted datasets
    local encrypted_count
    encrypted_count=$(echo "$encrypted_datasets" | wc -l)
    print_status "info" "Encrypted datasets: $encrypted_count"
    
    # Check encryption algorithm on pool root
    local encryption_algo
    encryption_algo=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "")
    
    if [[ "$encryption_algo" == "aes-256-gcm" ]]; then
        print_status "ok" "Encryption: $encryption_algo"
        increment_check "ok"
    elif [[ "$encryption_algo" != "off" ]] && [[ -n "$encryption_algo" ]] && [[ "$encryption_algo" != "-" ]]; then
        POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Weak encryption: $encryption_algo"
        print_status "warn" "Encryption: $encryption_algo (consider aes-256-gcm)"
        increment_check "warn"
    else
        # Check child datasets
        local has_aes256gcm=false
        while IFS=$'\t' read -r dataset algo; do
            if [[ "$algo" == "aes-256-gcm" ]]; then
                has_aes256gcm=true
                break
            fi
        done <<< "$encrypted_datasets"
        
        if [[ "$has_aes256gcm" == true ]]; then
            print_status "ok" "Encryption: aes-256-gcm (on datasets)"
            increment_check "ok"
        fi
    fi
    
    # Check key file
    local key_file="/etc/zfs/${pool}.key"
    if [[ -f "$key_file" ]]; then
        # Check permissions (should be 000)
        local perms
        perms=$(stat -c "%a" "$key_file")
        if [[ "$perms" == "000" ]]; then
            print_status "ok" "Key file permissions: $perms"
            increment_check "ok"
        else
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Key file permissions: $perms (should be 000)"
            print_status "warn" "Key file permissions: $perms (should be 000)"
            increment_check "warn"
        fi
        
        # Check key file is not empty
        if [[ ! -s "$key_file" ]]; then
            POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Key file is empty: $key_file"
            print_status "error" "Key file is empty: $key_file"
            increment_check "error"
        fi
    else
        if [[ -n "$encrypted_datasets" ]]; then
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Key file missing: $key_file"
            print_status "warn" "Key file missing: $key_file"
            increment_check "warn"
        fi
    fi
    
    return 0
}

check_bootfs_property() {
    local pool="$1"
    
    debug "Checking bootfs property: $pool"
    
    local has_issue=false
    
    # Get bootfs property
    local bootfs
    bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "")
    
    # Check if bootfs is set
    if [[ -z "$bootfs" ]] || [[ "$bootfs" == "-" ]]; then
        # Try to find a likely boot dataset
        local root_datasets
        root_datasets=$(zfs list -H -o name,mountpoint -r "$pool" | grep -E '\s/$' | awk '{print $1}')
        
        if [[ -n "$root_datasets" ]]; then
            local dataset_count
            dataset_count=$(echo "$root_datasets" | wc -l)
            
            if [[ $dataset_count -eq 1 ]]; then
                POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; No bootfs set but found root dataset: $root_datasets"
                print_status "warn" "No bootfs set (found candidate: $root_datasets)"
                increment_check "warn"
                has_issue=true
                
                # Store candidate for repair
                BOOTFS_CANDIDATES["$pool"]="$root_datasets"
            else
                POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; No bootfs set, multiple root candidates found"
                print_status "warn" "No bootfs set (multiple candidates found)"
                increment_check "warn"
                has_issue=true
            fi
        else
            print_status "info" "No bootfs property set (not a boot pool)"
            increment_check "ok"
        fi
        
        return $([ "$has_issue" = true ] && echo 1 || echo 0)
    fi
    
    print_status "info" "Bootfs dataset: $bootfs"
    
    # Verify bootfs dataset exists
    if ! zfs list "$bootfs" &>/dev/null; then
        POOL_ERRORS["$pool"]="${POOL_ERRORS[$pool]:-}; Bootfs dataset does not exist: $bootfs"
        print_status "error" "Bootfs dataset does not exist: $bootfs"
        increment_check "error"
        return 1
    fi
    
    # Check mountpoint
    local mountpoint
    mountpoint=$(zfs get -H -o value mountpoint "$bootfs" 2>/dev/null || echo "")
    
    case "$mountpoint" in
        "/")
            print_status "ok" "Bootfs mountpoint: / (root filesystem)"
            increment_check "ok"
            ;;
        "none")
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Bootfs mountpoint is 'none' (should be /)"
            print_status "warn" "Bootfs mountpoint: none (should be /)"
            increment_check "warn"
            has_issue=true
            ;;
        *)
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Bootfs mountpoint: $mountpoint (expected /)"
            print_status "warn" "Bootfs mountpoint: $mountpoint (expected /)"
            increment_check "warn"
            has_issue=true
            ;;
    esac
    
    # Check canmount property
    local canmount
    canmount=$(zfs get -H -o value canmount "$bootfs" 2>/dev/null || echo "")
    
    case "$canmount" in
        "noauto")
            print_status "ok" "Bootfs canmount: noauto (correct for boot environments)"
            increment_check "ok"
            ;;
        "on")
            print_status "info" "Bootfs canmount: on"
            increment_check "ok"
            ;;
        *)
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Bootfs canmount: $canmount (should be noauto or on)"
            print_status "warn" "Bootfs canmount: $canmount"
            increment_check "warn"
            has_issue=true
            ;;
    esac
    
    # Check if currently booted from this dataset
    if mountpoint -q /; then
        local current_root
        current_root=$(df --output=source / 2>/dev/null | tail -n1)
        
        if [[ "$current_root" == "$bootfs" ]]; then
            print_status "ok" "Currently booted from: $bootfs ✓"
            increment_check "ok"
        else
            print_status "info" "Currently booted from: $current_root (bootfs: $bootfs)"
            increment_check "ok"
        fi
    fi
    
    # Check ZFSBootMenu properties
    local zbm_cmdline
    zbm_cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "$bootfs" 2>/dev/null || echo "")
    
    if [[ -n "$zbm_cmdline" ]] && [[ "$zbm_cmdline" != "-" ]]; then
        # Validate cmdline contains expected parameters
        local expected_params=("ro" "quiet")
        local missing_params=()
        
        for param in "${expected_params[@]}"; do
            if [[ "$zbm_cmdline" != *"$param"* ]]; then
                missing_params+=("$param")
            fi
        done
        
        if [[ ${#missing_params[@]} -eq 0 ]]; then
            print_status "ok" "ZFSBootMenu cmdline: $zbm_cmdline"
            increment_check "ok"
        else
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; ZFSBootMenu cmdline missing: ${missing_params[*]}"
            print_status "warn" "ZFSBootMenu cmdline missing: ${missing_params[*]}"
            increment_check "warn"
            has_issue=true
        fi
    else
        # Only warn if this is actually a boot pool
        if [[ "$mountpoint" == "/" ]]; then
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; No ZFSBootMenu commandline property"
            print_status "warn" "No ZFSBootMenu commandline property set"
            increment_check "warn"
            has_issue=true
        else
            print_status "info" "No ZFSBootMenu commandline (not a boot dataset)"
            increment_check "ok"
        fi
    fi
    
    # Check for encryption if dataset should be encrypted
    local encryption
    encryption=$(zfs get -H -o value encryption "$bootfs" 2>/dev/null || echo "")
    
    if [[ "$encryption" == "off" ]]; then
        print_status "info" "Bootfs encryption: off"
        increment_check "ok"
    else
        print_status "ok" "Bootfs encryption: $encryption"
        increment_check "ok"
        
        # Verify key is loaded
        local keystatus
        keystatus=$(zfs get -H -o value keystatus "$bootfs" 2>/dev/null || echo "")
        
        if [[ "$keystatus" == "available" ]]; then
            print_status "ok" "Encryption key: available"
            increment_check "ok"
        else
            POOL_WARNINGS["$pool"]="${POOL_WARNINGS[$pool]:-}; Encryption key not available"
            print_status "warn" "Encryption key: $keystatus"
            increment_check "warn"
            has_issue=true
        fi
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

# ============================================
# System Configuration Check Functions
# ============================================

check_hostid() {
    subheader "Checking System Hostid"
    
    local has_issue=false
    
    if [[ ! -f /etc/hostid ]]; then
        SYSTEM_ISSUES["hostid"]="Hostid file missing: /etc/hostid"
        print_status "error" "Hostid file missing"
        increment_check "error"
        has_issue=true
    else
        local hostid_size
        hostid_size=$(stat -c%s /etc/hostid 2>/dev/null || echo "0")
        
        if [[ $hostid_size -ne 4 ]]; then
            SYSTEM_ISSUES["hostid"]="Hostid file corrupted (wrong size: $hostid_size bytes)"
            print_status "error" "Hostid file corrupted"
            increment_check "error"
            has_issue=true
        else
            local hostid_value
            hostid_value=$(hostid 2>/dev/null || echo "")
            print_status "ok" "Hostid: $hostid_value"
            increment_check "ok"
        fi
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

check_zpool_cache() {
    subheader "Checking ZPool Cache"
    
    local has_issue=false
    
    if [[ ! -f /etc/zfs/zpool.cache ]]; then
        SYSTEM_ISSUES["cache"]="Pool cache missing: /etc/zfs/zpool.cache"
        print_status "warn" "Pool cache missing"
        increment_check "warn"
        has_issue=true
    else
        if [[ ! -s /etc/zfs/zpool.cache ]]; then
            SYSTEM_ISSUES["cache"]="Pool cache is empty"
            print_status "warn" "Pool cache is empty"
            increment_check "warn"
            has_issue=true
        else
            print_status "ok" "Pool cache exists"
            increment_check "ok"
        fi
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

check_dracut_config() {
    subheader "Checking Dracut Configuration"
    
    local has_issue=false
    local pools
    pools=$(get_pools) || return 1
    
    # Check dracut config directory
    if [[ ! -d "$DRACUT_CONF_DIR" ]]; then
        SYSTEM_ISSUES["dracut"]="Dracut config directory missing: $DRACUT_CONF_DIR"
        print_status "error" "Dracut config directory missing"
        increment_check "error"
        has_issue=true
        return 1
    fi
    
    # Check main dracut config
    if [[ ! -f "$DRACUT_CONF" ]]; then
        SYSTEM_ISSUES["dracut"]="${SYSTEM_ISSUES[dracut]:-}; Main dracut.conf missing"
        print_status "warn" "Main dracut.conf missing"
        increment_check "warn"
        has_issue=true
    fi
    
    # Check ZFS-specific config
    if [[ -f "$DRACUT_ZFS_CONF" ]]; then
        local dracut_content
        dracut_content=$(cat "$DRACUT_ZFS_CONF")
        
        # Check for ZFS module
        if [[ "$dracut_content" != *"add_dracutmodules"*"zfs"* ]]; then
            SYSTEM_ISSUES["dracut"]="${SYSTEM_ISSUES[dracut]:-}; ZFS module not configured"
            print_status "warn" "ZFS module not in dracut config"
            has_issue=true
        fi
        
        # Check install_items exists
        if [[ "$dracut_content" != *"install_items"* ]]; then
            SYSTEM_ISSUES["dracut"]="${SYSTEM_ISSUES[dracut]:-}; install_items not configured"
            print_status "warn" "install_items not configured"
            has_issue=true
        else
            # Check hostid
            if [[ "$dracut_content" != *"/etc/hostid"* ]]; then
                SYSTEM_ISSUES["dracut"]="${SYSTEM_ISSUES[dracut]:-}; hostid not in install_items"
                print_status "warn" "hostid not in install_items"
                has_issue=true
            fi
            
            # Check for pool key files
            local missing_keys=()
            while IFS= read -r pool; do
                local key_file="/etc/zfs/${pool}.key"
                if [[ -f "$key_file" ]]; then
                    if [[ "$dracut_content" != *"$key_file"* ]]; then
                        missing_keys+=("$key_file")
                    fi
                fi
            done <<< "$pools"
            
            if [[ ${#missing_keys[@]} -gt 0 ]]; then
                SYSTEM_ISSUES["dracut"]="${SYSTEM_ISSUES[dracut]:-}; Missing keys: ${missing_keys[*]}"
                print_status "warn" "Pool keys not in install_items: ${missing_keys[*]}"
                has_issue=true
            else
                print_status "ok" "All pool keys in install_items"
            fi
        fi
        
        if [[ "$has_issue" == false ]]; then
            print_status "ok" "Dracut ZFS config valid"
            increment_check "ok"
        else
            increment_check "warn"
        fi
    else
        SYSTEM_ISSUES["dracut"]="ZFS dracut config missing: $DRACUT_ZFS_CONF"
        print_status "error" "ZFS dracut config missing"
        increment_check "error"
        has_issue=true
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

check_initramfs() {
    subheader "Checking Initramfs"
    
    local has_issue=false
    local pools
    pools=$(get_pools) || return 1
    
    # Find initramfs images
    local initramfs_images
    initramfs_images=$(find /boot -name "initramfs-*.img" 2>/dev/null || echo "")
    
    if [[ -z "$initramfs_images" ]]; then
        SYSTEM_ISSUES["initramfs"]="No initramfs images found in /boot"
        print_status "error" "No initramfs found"
        increment_check "error"
        has_issue=true
    else
        local image_count
        image_count=$(echo "$initramfs_images" | wc -l)
        info "Found $image_count initramfs image(s)"
        
        # Check each image
        while IFS= read -r img; do
            local img_name
            img_name=$(basename "$img")
            
            if command_exists lsinitrd; then
                local initrd_content
                initrd_content=$(lsinitrd "$img" 2>/dev/null || echo "")
                
                # Check ZFS module
                if [[ "$initrd_content" == *"zfs.ko"* ]]; then
                    print_status "ok" "$img_name contains ZFS module"
                else
                    SYSTEM_ISSUES["initramfs"]="${SYSTEM_ISSUES[initramfs]:-}; $img_name missing ZFS module"
                    print_status "error" "$img_name missing ZFS module"
                    increment_check "error"
                    has_issue=true
                    continue
                fi
                
                # Check hostid
                if [[ "$initrd_content" == *"etc/hostid"* ]]; then
                    print_status "ok" "$img_name contains hostid"
                    increment_check "ok"
                else
                    SYSTEM_ISSUES["initramfs"]="${SYSTEM_ISSUES[initramfs]:-}; $img_name missing hostid"
                    print_status "warn" "$img_name missing hostid"
                    increment_check "warn"
                    has_issue=true
                fi
                
                # Check for pool keys
                local missing_keys=()
                while IFS= read -r pool; do
                    local key_path="etc/zfs/${pool}.key"
                    if [[ -f "/etc/zfs/${pool}.key" ]]; then
                        if [[ "$initrd_content" != *"$key_path"* ]]; then
                            missing_keys+=("${pool}.key")
                        fi
                    fi
                done <<< "$pools"
                
                if [[ ${#missing_keys[@]} -gt 0 ]]; then
                    SYSTEM_ISSUES["initramfs"]="${SYSTEM_ISSUES[initramfs]:-}; $img_name missing keys: ${missing_keys[*]}"
                    print_status "warn" "$img_name missing keys: ${missing_keys[*]}"
                    increment_check "warn"
                    has_issue=true
                else
                    print_status "ok" "$img_name contains all pool keys"
                fi
            else
                print_status "info" "Cannot verify $img_name (lsinitrd not available)"
                increment_check "ok"
            fi
        done <<< "$initramfs_images"
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

check_zfsbootmenu() {
    subheader "Checking ZFSBootMenu"
    
    local has_issue=false
    
    # Check if ZFSBootMenu is installed
    if ! command_exists generate-zbm; then
        SYSTEM_ISSUES["zbm"]="ZFSBootMenu not installed"
        print_status "warn" "ZFSBootMenu not installed"
        increment_check "warn"
        return 1
    fi
    
    print_status "ok" "ZFSBootMenu installed"
    increment_check "ok"
    
    # Check EFI directory
    if [[ ! -d /boot/efi/EFI/ZBM ]]; then
        SYSTEM_ISSUES["zbm"]="${SYSTEM_ISSUES[zbm]:-}; ZFSBootMenu EFI directory missing"
        print_status "warn" "ZFSBootMenu EFI directory missing"
        increment_check "warn"
        has_issue=true
    else
        # Check for EFI images
        if [[ -f /boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
            print_status "ok" "ZFSBootMenu EFI image exists"
            increment_check "ok"
        else
            SYSTEM_ISSUES["zbm"]="${SYSTEM_ISSUES[zbm]:-}; ZFSBootMenu EFI image missing"
            print_status "error" "ZFSBootMenu EFI image missing"
            increment_check "error"
            has_issue=true
        fi
        
        # Check for backup image
        if [[ -f /boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
            print_status "info" "Backup EFI image exists"
        fi
    fi
    
    return $([ "$has_issue" = true ] && echo 1 || echo 0)
}

# ============================================
# Repair Functions
# ============================================

repair_hostid() {
    subheader "Repairing System Hostid"
    
    if [[ -f /etc/hostid ]]; then
        info "Backing up existing hostid..."
        backup_file /etc/hostid
    fi
    
    info "Generating new hostid..."
    if zgenhostid -f; then
        success "Hostid generated"
        
        if [[ -f /etc/hostid ]] && [[ $(stat -c%s /etc/hostid) -eq 4 ]]; then
            local new_hostid
            new_hostid=$(hostid)
            info "New hostid: $new_hostid"
            SYSTEM_REPAIRS["hostid"]="Generated new hostid: $new_hostid"
            return 0
        else
            error "Generated hostid file is invalid"
            return 1
        fi
    else
        error "Failed to generate hostid"
        return 1
    fi
}

repair_zpool_cache() {
    subheader "Repairing ZPool Cache"
    
    local pools
    pools=$(get_pools) || return 1
    
    if [[ -z "$pools" ]]; then
        error "No pools found to cache"
        return 1
    fi
    
    info "Backing up existing cache..."
    if [[ -f /etc/zfs/zpool.cache ]]; then
        backup_file /etc/zfs/zpool.cache
    fi
    
    info "Regenerating pool cache..."
    mkdir -p /etc/zfs
    
    # Set cachefile property on all pools
    while IFS= read -r pool; do
        info "Setting cachefile on pool: $pool"
        zpool set cachefile=/etc/zfs/zpool.cache "$pool"
    done <<< "$pools"
    
    sleep 2
    
    if [[ -s /etc/zfs/zpool.cache ]]; then
        success "Pool cache regenerated"
        SYSTEM_REPAIRS["cache"]="Regenerated pool cache for pools: $(echo $pools | tr '\n' ' ')"
        return 0
    else
        error "Failed to regenerate pool cache"
        return 1
    fi
}

repair_dracut_config() {
    subheader "Repairing Dracut Configuration"
    
    # Get all pools
    local pools
    pools=$(get_pools) || return 1
    
    # Create config directory if missing
    if [[ ! -d "$DRACUT_CONF_DIR" ]]; then
        info "Creating dracut config directory..."
        ensure_directory "$DRACUT_CONF_DIR" 755
    fi
    
    # Backup existing config
    if [[ -f "$DRACUT_ZFS_CONF" ]]; then
        info "Backing up existing config..."
        backup_file "$DRACUT_ZFS_CONF"
    fi
    
    info "Writing dracut ZFS configuration..."
    
    # Build install_items with all pool keys
    local install_items="/etc/hostid"
    while IFS= read -r pool; do
        local key_file="/etc/zfs/${pool}.key"
        if [[ -f "$key_file" ]]; then
            install_items="$install_items $key_file"
        fi
    done <<< "$pools"
    
    # Write configuration
    cat > "$DRACUT_ZFS_CONF" <<EOF
hostonly="yes"
hostonly_cmdline="no"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" $install_items "
force_drivers+=" zfs "
filesystems+=" zfs "
EOF
    
    if [[ -f "$DRACUT_ZFS_CONF" ]]; then
        success "Dracut ZFS config created"
        SYSTEM_REPAIRS["dracut"]="Created/updated dracut ZFS configuration with keys: $install_items"
        
        # Verify content
        local dracut_content
        dracut_content=$(cat "$DRACUT_ZFS_CONF")
        
        if [[ "$dracut_content" == *"add_dracutmodules"*"zfs"* ]] && \
           [[ "$dracut_content" == *"force_drivers"*"zfs"* ]] && \
           [[ "$dracut_content" == *"install_items"* ]] && \
           [[ "$dracut_content" == *"/etc/hostid"* ]]; then
            print_status "ok" "Configuration verified"
            return 0
        else
            error "Configuration verification failed"
            return 1
        fi
    else
        error "Failed to create dracut config"
        return 1
    fi
}

repair_initramfs() {
    subheader "Rebuilding Initramfs"
    
    info "This will rebuild all initramfs images..."
    
    if ! ask_yes_no "Proceed with initramfs rebuild?" "n"; then
        info "Skipping initramfs rebuild"
        return 0
    fi
    
    info "Running dracut to rebuild initramfs..."
    if dracut --force --hostonly --kver "$(uname -r)"; then
        success "Initramfs rebuilt"
        SYSTEM_REPAIRS["initramfs"]="Rebuilt initramfs for kernel $(uname -r)"
        return 0
    else
        error "Failed to rebuild initramfs"
        return 1
    fi
}

repair_zfsbootmenu() {
    subheader "Rebuilding ZFSBootMenu"
    
    if ! command_exists generate-zbm; then
        error "ZFSBootMenu not installed"
        return 1
    fi
    
    info "This will regenerate ZFSBootMenu EFI images..."
    
    if ! ask_yes_no "Proceed with ZFSBootMenu rebuild?" "n"; then
        info "Skipping ZFSBootMenu rebuild"
        return 0
    fi
    
    info "Running generate-zbm..."
    if generate-zbm; then
        success "ZFSBootMenu regenerated"
        SYSTEM_REPAIRS["zbm"]="Regenerated ZFSBootMenu EFI images"
        
        # Verify images exist
        if [[ -f /boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
            print_status "ok" "EFI image verified"
            return 0
        else
            error "EFI image missing after rebuild"
            return 1
        fi
    else
        error "Failed to regenerate ZFSBootMenu"
        return 1
    fi
}

repair_bootfs_property() {
    local pool="$1"
    
    subheader "Repairing Bootfs Property for Pool: $pool"
    
    local current_bootfs
    current_bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "")
    
    # Case 1: No bootfs set but candidate found
    if [[ -z "$current_bootfs" ]] || [[ "$current_bootfs" == "-" ]]; then
        local candidate="${BOOTFS_CANDIDATES[$pool]:-}"
        
        if [[ -n "$candidate" ]]; then
            warning "No bootfs set on pool $pool"
            info "Found candidate dataset: $candidate"
            
            if ask_yes_no "Set $candidate as bootfs?" "n"; then
                info "Setting bootfs property..."
                if zpool set bootfs="$candidate" "$pool"; then
                    success "Bootfs property set to: $candidate"
                    SYSTEM_REPAIRS["bootfs_$pool"]="Set bootfs to $candidate"
                    return 0
                else
                    error "Failed to set bootfs property"
                    return 1
                fi
            else
                info "Skipping bootfs repair"
                return 0
            fi
        else
            error "No bootfs candidate found for pool $pool"
            return 1
        fi
    fi
    
    # Case 2: Bootfs exists but properties need fixing
    if zfs list "$current_bootfs" &>/dev/null; then
        local needs_repair=false
        local repairs=()
        
        # Check mountpoint
        local mountpoint
        mountpoint=$(zfs get -H -o value mountpoint "$current_bootfs" 2>/dev/null || echo "")
        if [[ "$mountpoint" != "/" ]] && [[ "$mountpoint" != "none" ]]; then
            needs_repair=true
            repairs+=("mountpoint: $mountpoint → /")
        fi
        
        # Check ZFSBootMenu cmdline
        local zbm_cmdline
        zbm_cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "$current_bootfs" 2>/dev/null || echo "")
        if [[ -z "$zbm_cmdline" ]] || [[ "$zbm_cmdline" == "-" ]]; then
            needs_repair=true
            repairs+=("Add ZFSBootMenu commandline")
        fi
        
        if [[ "$needs_repair" == true ]]; then
            warning "Bootfs dataset $current_bootfs needs repairs:"
            for repair in "${repairs[@]}"; do
                bullet "$repair"
            done
            echo ""
            
            if ask_yes_no "Apply repairs?" "n"; then
                # Fix mountpoint if needed
                if [[ "$mountpoint" != "/" ]] && [[ "$mountpoint" != "none" ]]; then
                    info "Setting mountpoint to /..."
                    if zfs set mountpoint=/ "$current_bootfs"; then
                        success "Mountpoint updated"
                    else
                        error "Failed to update mountpoint"
                        return 1
                    fi
                fi
                
                # Set ZFSBootMenu cmdline if missing
                if [[ -z "$zbm_cmdline" ]] || [[ "$zbm_cmdline" == "-" ]]; then
                    info "Setting ZFSBootMenu commandline..."
                    local default_cmdline="ro quiet nowatchdog loglevel=0 zbm.timeout=5"
                    if zfs set org.zfsbootmenu:commandline="$default_cmdline" "$current_bootfs"; then
                        success "ZFSBootMenu commandline set"
                    else
                        error "Failed to set ZFSBootMenu commandline"
                        return 1
                    fi
                fi
                
                SYSTEM_REPAIRS["bootfs_$pool"]="Repaired properties for $current_bootfs"
                success "Bootfs properties repaired"
                return 0
            else
                info "Skipping bootfs repairs"
                return 0
            fi
        else
            info "Bootfs properties are correct, no repairs needed"
            return 0
        fi
    else
        error "Bootfs dataset $current_bootfs does not exist!"
        return 1
    fi
}

# ============================================
# Snapshot Functions
# ============================================

offer_snapshot_creation() {
    if [[ "$SNAPSHOT_ON_SUCCESS" != true ]]; then
        return 0
    fi
    
    if [[ $CHECK_ERROR -gt 0 ]] || [[ $CHECK_WARN -gt 0 ]]; then
        info "Skipping snapshot creation (checks did not pass 100%)"
        return 0
    fi
    
    header "SNAPSHOT CREATION"
    
    success "All health checks passed!"
    echo ""
    
    if ! ask_yes_no "Would you like to create a snapshot of the root dataset?" "y"; then
        info "Snapshot creation skipped"
        return 0
    fi
    
    # Find pool containing root filesystem
    local pools
    pools=$(get_pools) || return 1
    
    local root_pool=""
    local root_dataset=""
    
    while IFS= read -r pool; do
        local has_root
        has_root=$(zfs list -H -o name,mountpoint -r "$pool" | grep -E '\s/$' || echo "")
        if [[ -n "$has_root" ]]; then
            root_pool="$pool"
            root_dataset=$(echo "$has_root" | awk '{print $1}')
            break
        fi
    done <<< "$pools"
    
    if [[ -z "$root_pool" ]] || [[ -z "$root_dataset" ]]; then
        error "Could not find root dataset"
        return 1
    fi
    
    # Generate snapshot name
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snap_name="health-check-${timestamp}"
    local full_snap_name="${root_dataset}@${snap_name}"
    
    info "Creating recursive snapshot: $full_snap_name"
    
    if zfs snapshot -r "$full_snap_name"; then
        success "Snapshot created: $full_snap_name"
        echo ""
        info "To rollback to this snapshot:"
        echo "  zfs rollback -r $full_snap_name"
        echo ""
        info "To destroy this snapshot:"
        echo "  zfs destroy -r $full_snap_name"
        echo ""
        return 0
    else
        error "Failed to create snapshot"
        return 1
    fi
}

# ============================================
# Report Functions
# ============================================

show_summary() {
    header "HEALTH CHECK SUMMARY"
    
    local total_checks=$((CHECK_OK + CHECK_WARN + CHECK_ERROR))
    
    subheader "Check Results:"
    bullet "Total checks: $total_checks"
    bullet "Passed: ${GREEN}${CHECK_OK}${NC}"
    if [[ $CHECK_WARN -gt 0 ]]; then
        bullet "Warnings: ${YELLOW}${CHECK_WARN}${NC}"
    else
        bullet "Warnings: 0"
    fi
    if [[ $CHECK_ERROR -gt 0 ]]; then
        bullet "Errors: ${RED}${CHECK_ERROR}${NC}"
    else
        bullet "Errors: 0"
    fi
    echo ""
    
    # Show pool issues
    if [[ ${#POOL_ERRORS[@]} -gt 0 ]] || [[ ${#POOL_WARNINGS[@]} -gt 0 ]]; then
        subheader "Pool Issues:"
        
        for pool in "${!POOL_ERRORS[@]}"; do
            echo -e "${RED}✗${NC} ${BOLD}$pool${NC}: ${POOL_ERRORS[$pool]}"
        done
        
        for pool in "${!POOL_WARNINGS[@]}"; do
            echo -e "${YELLOW}⚠${NC} ${BOLD}$pool${NC}: ${POOL_WARNINGS[$pool]}"
        done
        echo ""
    fi
    
    # Show system issues
    if [[ ${#SYSTEM_ISSUES[@]} -gt 0 ]]; then
        subheader "System Issues:"
        for component in "${!SYSTEM_ISSUES[@]}"; do
            echo -e "${YELLOW}⚠${NC} ${BOLD}$component${NC}: ${SYSTEM_ISSUES[$component]}"
        done
        echo ""
    fi
    
    # Show repairs if any were made
    if [[ ${#SYSTEM_REPAIRS[@]} -gt 0 ]]; then
        subheader "Repairs Applied:"
        for component in "${!SYSTEM_REPAIRS[@]}"; do
            echo -e "${GREEN}✓${NC} ${BOLD}$component${NC}: ${SYSTEM_REPAIRS[$component]}"
        done
        echo ""
    fi
    
    # Overall status
    if [[ $CHECK_ERROR -eq 0 ]] && [[ $CHECK_WARN -eq 0 ]]; then
        success "System is healthy! All checks passed."
        return 0
    elif [[ $CHECK_ERROR -eq 0 ]]; then
        warning "System is mostly healthy with some warnings"
        return 1
    else
        error "System has errors that require attention"
        return 2
    fi
}

# ============================================
# Main Function
# ============================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pool)
                TARGET_POOL="$2"
                shift 2
                ;;
            --repair)
                REPAIR_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE_MODE=true
                DEBUG_MODE=true
                shift
                ;;
            --snapshot)
                SNAPSHOT_ON_SUCCESS=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
    
    # Display header
    header "ZFS HEALTH CHECK - Version ${SCRIPT_VERSION}"
    
    if [[ "$REPAIR_MODE" == true ]]; then
        warning "Repair mode enabled - will attempt to fix issues"
    fi
    
    if [[ "$SNAPSHOT_ON_SUCCESS" == true ]]; then
        info "Will create snapshot if all checks pass"
    fi
    
    echo ""
    
    # Get pools to check
    local pools
    if [[ -n "$TARGET_POOL" ]]; then
        if zpool list "$TARGET_POOL" &>/dev/null; then
            pools="$TARGET_POOL"
        else
            die "Pool not found: $TARGET_POOL"
        fi
    else
        pools=$(get_pools)
        if [[ -z "$pools" ]]; then
            die "No ZFS pools found"
        fi
    fi
    
    # Convert to array
    local pool_array=()
    while IFS= read -r pool; do
        pool_array+=("$pool")
    done <<< "$pools"
    
    info "Checking ${#pool_array[@]} pool(s)"
    echo ""
    
    # System Configuration Checks
    header "SYSTEM CONFIGURATION"
    
    check_hostid
    check_zpool_cache
    check_dracut_config
    check_initramfs
    check_zfsbootmenu
    
    echo ""
    
    # Pool Health Checks
    header "POOL HEALTH CHECKS"
    
    for pool in "${pool_array[@]}"; do
        subheader "Pool: $pool"
        
        debug "Processing pool: $pool"
        
        check_pool_status "$pool"
        check_pool_capacity "$pool"
        check_pool_fragmentation "$pool"
        check_scrub_status "$pool"
        check_dataset_quotas "$pool"
        check_snapshot_count "$pool"
        check_pool_features "$pool"
        check_pool_encryption "$pool"
        check_bootfs_property "$pool"
        
        echo ""
    done
    
    # Repair section
    if [[ "$REPAIR_MODE" == true ]]; then
        if [[ ${#SYSTEM_ISSUES[@]} -gt 0 ]] || [[ ${#POOL_WARNINGS[@]} -gt 0 ]]; then
            header "REPAIR MODE"
            
            # Repair system issues
            if [[ -n "${SYSTEM_ISSUES[hostid]:-}" ]]; then
                repair_hostid
            fi
            
            if [[ -n "${SYSTEM_ISSUES[cache]:-}" ]]; then
                repair_zpool_cache
            fi
            
            if [[ -n "${SYSTEM_ISSUES[dracut]:-}" ]]; then
                repair_dracut_config
            fi
            
            if [[ -n "${SYSTEM_ISSUES[initramfs]:-}" ]]; then
                repair_initramfs
            fi
            
            if [[ -n "${SYSTEM_ISSUES[zbm]:-}" ]]; then
                repair_zfsbootmenu
            fi
            
            # Repair bootfs issues
            for pool in "${pool_array[@]}"; do
                if [[ -n "${POOL_WARNINGS[$pool]:-}" ]] && [[ "${POOL_WARNINGS[$pool]}" == *"bootfs"* ]]; then
                    repair_bootfs_property "$pool"
                fi
            done
            
            echo ""
        fi
    fi
    
    # Show summary
    show_summary
    local exit_code=$?
    
    echo ""
    
    # Offer snapshot creation
    offer_snapshot_creation
    
    # Final message
    if [[ $exit_code -eq 0 ]]; then
        success "Health check complete - No issues found"
    elif [[ $exit_code -eq 1 ]]; then
        warning "Health check complete - Some warnings found"
    else
        error "Health check complete - Errors found"
    fi
    
    exit $exit_code
}

# Run main function
main "$@"
