#!/usr/bin/env bash
# ZFS Health Check Script
# Version: 3.0
# Date: 2025-12-12
# 
# Comprehensive health check for ZFS pools and system configuration
# Validates against settings defined in zfs-setup.conf
# Can automatically repair common issues

set -euo pipefail

# ============================================
# SCRIPT INITIALIZATION
# ============================================

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    source "${SCRIPT_DIR}/common.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/common.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/common.sh"
else
    echo "ERROR: common.sh not found" >&2
    exit 1
fi

# Source configuration helper functions
if [[ -f "${SCRIPT_DIR}/zfs-setup-conf-helper.sh" ]]; then
    source "${SCRIPT_DIR}/zfs-setup-conf-helper.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/zfs-setup-conf-helper.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/zfs-setup-conf-helper.sh"
else
    echo "ERROR: zfs-setup-conf-helper.sh not found" >&2
    exit 1
fi

# Validate configuration is loaded
validate_config_loaded || {
    error "Failed to load configuration"
    exit 1
}

# ============================================
# SCRIPT METADATA
# ============================================

readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="ZFS Health Check"
readonly SCRIPT_DATE="2025-12-12"

# ============================================
# SCRIPT OPTIONS
# ============================================

TARGET_POOL=""              # Specific pool to check (empty = all pools)
REPAIR_MODE=false          # Auto-repair mode
VERBOSE_MODE=false         # Verbose output
SNAPSHOT_ON_SUCCESS=false  # Create snapshot if all checks pass
DRY_RUN=false             # Show what would be repaired without doing it

# ============================================
# CHECK COUNTERS
# ============================================

CHECK_OK=0
CHECK_WARN=0
CHECK_ERROR=0

# ============================================
# ISSUE TRACKING
# ============================================

declare -A POOL_ERRORS=()
declare -A POOL_WARNINGS=()
declare -A SYSTEM_ISSUES=()
declare -A SYSTEM_REPAIRS=()

# ============================================
# HELPER FUNCTIONS
# ============================================

increment_check() {
    local status="$1"
    case "$status" in
        ok|OK)
            ((CHECK_OK++))
            ;;
        warn|WARN|warning)
            ((CHECK_WARN++))
            ;;
        error|ERROR|critical)
            ((CHECK_ERROR++))
            ;;
    esac
}

show_usage() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

OPTIONS:
    --pool POOL         Check specific pool only
    --repair            Automatically repair issues
    --dry-run          Show what would be repaired without doing it
    --verbose          Show detailed output
    --snapshot         Create snapshot if all checks pass
    --help             Show this help message

EXAMPLES:
    # Check all pools
    $(basename "$0")
    
    # Check specific pool with verbose output
    $(basename "$0") --pool zroot --verbose
    
    # Check and auto-repair issues
    $(basename "$0") --repair
    
    # Dry-run repair mode
    $(basename "$0") --repair --dry-run

CONFIGURATION:
    This script uses settings from: zfs-setup.conf v${CONFIG_VERSION}
    Configuration helper functions: zfs-setup-conf-helper.sh

EXIT CODES:
    0 - All checks passed
    1 - Warnings found
    2 - Errors found
    3 - Script error

EOF
}

# ============================================
# POOL HEALTH CHECK FUNCTIONS
# ============================================

check_pool_status() {
    local pool="$1"
    
    header "Pool Status: $pool"
    
    debug "Checking pool status: $pool"
    
    local status
    status=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
    
    case "$status" in
        ONLINE)
            success "Pool is ONLINE"
            increment_check "ok"
            ;;
        DEGRADED)
            warning "Pool is DEGRADED"
            POOL_WARNINGS["$pool"]="DEGRADED"
            increment_check "warn"
            ;;
        FAULTED|UNAVAIL)
            error "Pool is $status"
            POOL_ERRORS["$pool"]="$status"
            increment_check "error"
            ;;
        *)
            error "Pool status unknown: $status"
            POOL_ERRORS["$pool"]="UNKNOWN"
            increment_check "error"
            ;;
    esac
    
    # Show pool details if verbose
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        info "Pool details:"
        zpool status "$pool" 2>/dev/null | sed 's/^/  /'
    fi
}

check_pool_capacity() {
    local pool="$1"
    
    header "Pool Capacity: $pool"
    
    debug "Checking pool capacity: $pool"
    
    local capacity
    capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%' || echo "0")
    
    info "Current capacity: ${capacity}%"
    
    if [[ $capacity -ge $CAPACITY_CRITICAL ]]; then
        error "Capacity critical: ${capacity}% (threshold: ${CAPACITY_CRITICAL}%)"
        POOL_ERRORS["${pool}_capacity"]="Critical: ${capacity}%"
        increment_check "error"
    elif [[ $capacity -ge $CAPACITY_WARNING ]]; then
        warning "Capacity high: ${capacity}% (threshold: ${CAPACITY_WARNING}%)"
        POOL_WARNINGS["${pool}_capacity"]="High: ${capacity}%"
        increment_check "warn"
    else
        success "Capacity OK: ${capacity}%"
        increment_check "ok"
    fi
}

check_pool_fragmentation() {
    local pool="$1"
    
    header "Pool Fragmentation: $pool"
    
    debug "Checking pool fragmentation: $pool"
    
    local frag
    frag=$(zpool list -H -o frag "$pool" 2>/dev/null | tr -d '%' || echo "0")
    
    info "Current fragmentation: ${frag}%"
    
    if [[ $frag -ge $FRAGMENTATION_CRITICAL ]]; then
        error "Fragmentation critical: ${frag}% (threshold: ${FRAGMENTATION_CRITICAL}%)"
        POOL_ERRORS["${pool}_frag"]="Critical: ${frag}%"
        increment_check "error"
        info "Consider running: zpool scrub $pool"
    elif [[ $frag -ge $FRAGMENTATION_WARNING ]]; then
        warning "Fragmentation high: ${frag}% (threshold: ${FRAGMENTATION_WARNING}%)"
        POOL_WARNINGS["${pool}_frag"]="High: ${frag}%"
        increment_check "warn"
    else
        success "Fragmentation OK: ${frag}%"
        increment_check "ok"
    fi
}

check_pool_properties() {
    local pool="$1"
    
    header "Pool Properties: $pool"
    
    debug "Checking pool properties: $pool"
    
    # Check ashift (from config: EXPECTED_POOL_PROPERTY_ASHIFT)
    local ashift
    ashift=$(zpool get -H -o value ashift "$pool" 2>/dev/null || echo "")
    
    if [[ "$ashift" == "$EXPECTED_POOL_PROPERTY_ASHIFT" ]]; then
        success "ashift: $ashift (matches config)"
        increment_check "ok"
    else
        warning "ashift: $ashift (expected: $EXPECTED_POOL_PROPERTY_ASHIFT from config)"
        POOL_WARNINGS["${pool}_ashift"]="Mismatch: $ashift != $EXPECTED_POOL_PROPERTY_ASHIFT"
        increment_check "warn"
        info "Note: ashift cannot be changed after pool creation"
    fi
    
    # Check autotrim (from config: EXPECTED_POOL_PROPERTY_AUTOTRIM)
    local autotrim
    autotrim=$(zpool get -H -o value autotrim "$pool" 2>/dev/null || echo "")
    
    if [[ "$autotrim" == "$EXPECTED_POOL_PROPERTY_AUTOTRIM" ]]; then
        success "autotrim: $autotrim (matches config)"
        increment_check "ok"
    else
        warning "autotrim: $autotrim (expected: $EXPECTED_POOL_PROPERTY_AUTOTRIM from config)"
        POOL_WARNINGS["${pool}_autotrim"]="Mismatch: $autotrim != $EXPECTED_POOL_PROPERTY_AUTOTRIM"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_pool_property "$pool" "autotrim" "$EXPECTED_POOL_PROPERTY_AUTOTRIM"
        fi
    fi
    
    # Check cachefile (should be pool-specific from config pattern)
    local expected_cachefile
    expected_cachefile="$(get_pool_cache_file "$pool")"
    
    local cachefile
    cachefile=$(zpool get -H -o value cachefile "$pool" 2>/dev/null || echo "")
    
    if [[ "$cachefile" == "$expected_cachefile" ]]; then
        success "cachefile: $cachefile (matches config pattern)"
        increment_check "ok"
    else
        warning "cachefile: $cachefile (expected: $expected_cachefile from config)"
        POOL_WARNINGS["${pool}_cachefile"]="Mismatch"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_pool_property "$pool" "cachefile" "$expected_cachefile"
        fi
    fi
}

check_bootfs_property() {
    local pool="$1"
    
    header "Bootfs Property: $pool"
    
    debug "Checking bootfs property: $pool"
    
    local bootfs
    bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
    
    if [[ "$bootfs" == "-" ]]; then
        warning "No bootfs set for pool: $pool"
        POOL_WARNINGS["${pool}_bootfs"]="Not set"
        increment_check "warn"
        info "This may be intentional for non-root pools"
    else
        success "bootfs: $bootfs"
        increment_check "ok"
        
        # Verify bootfs dataset exists
        if ! zfs list -H -o name "$bootfs" &>/dev/null; then
            error "bootfs dataset does not exist: $bootfs"
            POOL_ERRORS["${pool}_bootfs"]="Dataset missing"
            increment_check "error"
        fi
    fi
}

check_pool_encryption() {
    local pool="$1"
    
    header "Pool Encryption: $pool"
    
    debug "Checking pool encryption: $pool"
    
    # Check root dataset encryption
    local encryption
    encryption=$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo "off")
    
    if [[ "$encryption" == "off" ]]; then
        info "Pool is not encrypted"
        increment_check "ok"
        return 0
    fi
    
    success "Encryption enabled: $encryption"
    
    # Verify encryption algorithm matches config
    if [[ "$encryption" != "$ENCRYPTION_ALGORITHM" ]]; then
        warning "Encryption algorithm: $encryption (expected: $ENCRYPTION_ALGORITHM from config)"
        POOL_WARNINGS["${pool}_encryption_algo"]="Mismatch"
        increment_check "warn"
    else
        success "Encryption algorithm matches config: $ENCRYPTION_ALGORITHM"
        increment_check "ok"
    fi
    
    # Check key format (from config: KEY_FORMAT)
    local keyformat
    keyformat=$(zfs get -H -o value keyformat "$pool" 2>/dev/null || echo "")
    
    if [[ "$keyformat" != "$KEY_FORMAT" ]]; then
        warning "Key format: $keyformat (expected: $KEY_FORMAT from config)"
        POOL_WARNINGS["${pool}_keyformat"]="Mismatch"
        increment_check "warn"
    else
        success "Key format matches config: $KEY_FORMAT"
        increment_check "ok"
    fi
    
    # Check key location (should match config pattern)
    local expected_keylocation
    expected_keylocation="$(get_pool_key_location "$pool")"
    
    local keylocation
    keylocation=$(zfs get -H -o value keylocation "$pool" 2>/dev/null || echo "")
    
    if [[ "$keylocation" != "$expected_keylocation" ]]; then
        warning "Key location: $keylocation (expected: $expected_keylocation from config)"
        POOL_WARNINGS["${pool}_keylocation"]="Mismatch"
        increment_check "warn"
    else
        success "Key location matches config pattern"
        increment_check "ok"
    fi
    
    # Check key file exists
    local key_file
    key_file="$(get_pool_key_file "$pool")"
    
    if [[ ! -f "$key_file" ]]; then
        error "Key file not found: $key_file"
        POOL_ERRORS["${pool}_keyfile"]="Missing"
        increment_check "error"
    else
        success "Key file exists: $key_file"
        increment_check "ok"
        
        # Check key file permissions (should be 000)
        local perms
        perms=$(stat -c "%a" "$key_file" 2>/dev/null || echo "")
        
        if [[ "$perms" != "000" ]]; then
            error "Key file permissions: $perms (should be 000)"
            POOL_ERRORS["${pool}_keyfile_perms"]="Insecure: $perms"
            increment_check "error"
            
            if [[ "$REPAIR_MODE" == "true" ]]; then
                repair_key_permissions "$key_file"
            fi
        else
            success "Key file permissions correct: 000"
            increment_check "ok"
        fi
    fi
    
    # Check key backup exists (from config: ZFS_KEY_BACKUP_DIR)
    local backup_key="${ZFS_KEY_BACKUP_DIR}/$(basename "$key_file")"
    
    if [[ ! -f "$backup_key" ]]; then
        warning "Key backup not found: $backup_key"
        POOL_WARNINGS["${pool}_keybackup"]="Missing"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_key_backup "$key_file" "$backup_key"
        fi
    else
        success "Key backup exists: $backup_key"
        increment_check "ok"
        
        # Check backup permissions
        local backup_perms
        backup_perms=$(stat -c "%a" "$backup_key" 2>/dev/null || echo "")
        
        if [[ "$backup_perms" != "000" ]]; then
            warning "Key backup permissions: $backup_perms (should be 000)"
            POOL_WARNINGS["${pool}_keybackup_perms"]="Insecure"
            increment_check "warn"
            
            if [[ "$REPAIR_MODE" == "true" ]]; then
                repair_key_permissions "$backup_key"
            fi
        fi
    fi
    
    # Check keystatus
    local keystatus
    keystatus=$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo "")
    
    case "$keystatus" in
        available)
            success "Key status: available"
            increment_check "ok"
            ;;
        unavailable)
            error "Key status: unavailable (key not loaded)"
            POOL_ERRORS["${pool}_keystatus"]="Unavailable"
            increment_check "error"
            ;;
        *)
            warning "Key status unknown: $keystatus"
            POOL_WARNINGS["${pool}_keystatus"]="Unknown"
            increment_check "warn"
            ;;
    esac
}

check_scrub_status() {
    local pool="$1"
    
    header "Scrub Status: $pool"
    
    debug "Checking scrub status: $pool"
    
    local scrub_info
    scrub_info=$(zpool status "$pool" 2>/dev/null | grep -A 2 "scan:" || echo "")
    
    if [[ -z "$scrub_info" ]]; then
        warning "No scrub information available"
        POOL_WARNINGS["${pool}_scrub"]="No info"
        increment_check "warn"
        return 0
    fi
    
    if echo "$scrub_info" | grep -q "scrub in progress"; then
        info "Scrub currently in progress"
        increment_check "ok"
        return 0
    fi
    
    if echo "$scrub_info" | grep -q "none requested"; then
        warning "No scrub has been performed"
        POOL_WARNINGS["${pool}_scrub"]="Never run"
        increment_check "warn"
        info "Run: zpool scrub $pool"
        return 0
    fi
    
    # Extract scrub date
    local scrub_date
    scrub_date=$(echo "$scrub_info" | grep -oP '(?<=on ).*' | head -n1 || echo "")
    
    if [[ -n "$scrub_date" ]]; then
        local scrub_epoch
        scrub_epoch=$(date -d "$scrub_date" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local age_days=$(( (now_epoch - scrub_epoch) / 86400 ))
        
        info "Last scrub: $scrub_date ($age_days days ago)"
        
        # Check against threshold from config: SCRUB_MAX_AGE_DAYS
        if [[ $age_days -gt $SCRUB_MAX_AGE_DAYS ]]; then
            warning "Scrub is overdue (> $SCRUB_MAX_AGE_DAYS days from config)"
            POOL_WARNINGS["${pool}_scrub"]="Overdue: $age_days days"
            increment_check "warn"
            info "Run: zpool scrub $pool"
        else
            success "Scrub is current (< $SCRUB_MAX_AGE_DAYS days from config)"
            increment_check "ok"
        fi
        
        # Check for errors
        if echo "$scrub_info" | grep -q "with 0 errors"; then
            success "No errors found during scrub"
            increment_check "ok"
        else
            error "Errors found during scrub!"
            POOL_ERRORS["${pool}_scrub"]="Errors found"
            increment_check "error"
        fi
    fi
}

check_dataset_properties() {
    local dataset="$1"
    
    debug "Checking dataset properties: $dataset"
    
    # Properties to check from config: EXPECTED_DATASET_PROPERTY_*
    local properties=(
        "acltype:$EXPECTED_DATASET_PROPERTY_ACLTYPE"
        "compression:$EXPECTED_DATASET_PROPERTY_COMPRESSION"
        "relatime:$EXPECTED_DATASET_PROPERTY_RELATIME"
        "xattr:$EXPECTED_DATASET_PROPERTY_XATTR"
        "dnodesize:$EXPECTED_DATASET_PROPERTY_DNODESIZE"
        "normalization:$EXPECTED_DATASET_PROPERTY_NORMALIZATION"
        "devices:$EXPECTED_DATASET_PROPERTY_DEVICES"
    )
    
    local mismatches=0
    
    for prop_pair in "${properties[@]}"; do
        local prop="${prop_pair%%:*}"
        local expected="${prop_pair#*:}"
        
        local actual
        actual=$(zfs get -H -o value "$prop" "$dataset" 2>/dev/null || echo "")
        
        if [[ "$actual" != "$expected" ]]; then
            warning "  $prop: $actual (expected: $expected from config)"
            ((mismatches++))
            
            # Some properties can be changed
            if [[ "$prop" =~ ^(acltype|compression|relatime|xattr|devices)$ ]]; then
                if [[ "$REPAIR_MODE" == "true" ]]; then
                    repair_dataset_property "$dataset" "$prop" "$expected"
                fi
            else
                info "  Note: $prop cannot be changed after dataset creation"
            fi
        elif [[ "$VERBOSE_MODE" == "true" ]]; then
            success "  $prop: $actual (matches config)"
        fi
    done
    
    if [[ $mismatches -eq 0 ]]; then
        success "All dataset properties match config"
        increment_check "ok"
    else
        warning "$mismatches property mismatch(es) found"
        increment_check "warn"
    fi
}

check_root_dataset_properties() {
    local pool="$1"
    
    header "Root Dataset Properties: $pool"
    
    local bootfs
    bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
    
    if [[ "$bootfs" == "-" ]]; then
        info "No bootfs set, skipping root dataset checks"
        return 0
    fi
    
    debug "Checking root dataset: $bootfs"
    
    # Check properties from config: EXPECTED_ROOT_PROPERTY_*
    local properties=(
        "mountpoint:$EXPECTED_ROOT_PROPERTY_MOUNTPOINT"
        "canmount:$EXPECTED_ROOT_PROPERTY_CANMOUNT"
        "recordsize:$EXPECTED_ROOT_PROPERTY_RECORDSIZE"
        "atime:$EXPECTED_ROOT_PROPERTY_ATIME"
        "relatime:$EXPECTED_ROOT_PROPERTY_RELATIME"
    )
    
    local mismatches=0
    
    for prop_pair in "${properties[@]}"; do
        local prop="${prop_pair%%:*}"
        local expected="${prop_pair#*:}"
        
        local actual
        actual=$(zfs get -H -o value "$prop" "$bootfs" 2>/dev/null || echo "")
        
        if [[ "$actual" != "$expected" ]]; then
            warning "$prop: $actual (expected: $expected from config)"
            ((mismatches++))
            
            # Canmount, atime, relatime can be changed
            if [[ "$prop" =~ ^(canmount|atime|relatime)$ ]]; then
                if [[ "$REPAIR_MODE" == "true" ]]; then
                    repair_dataset_property "$bootfs" "$prop" "$expected"
                fi
            else
                info "Note: $prop cannot be changed after dataset creation"
            fi
        else
            success "$prop: $actual (matches config)"
        fi
    done
    
    if [[ $mismatches -eq 0 ]]; then
        increment_check "ok"
    else
        increment_check "warn"
    fi
    
    # Check base dataset properties
    check_dataset_properties "$bootfs"
}

check_home_dataset_properties() {
    local pool="$1"
    
    header "Home Dataset Properties: $pool"
    
    # Construct home dataset path: pool/DATA_CONTAINER/home
    local home_dataset="${pool}/${DATA_CONTAINER}/home"
    
    if ! zfs list -H -o name "$home_dataset" &>/dev/null; then
        info "Home dataset not found: $home_dataset"
        return 0
    fi
    
    debug "Checking home dataset: $home_dataset"
    
    # Check properties from config: EXPECTED_HOME_PROPERTY_*
    local properties=(
        "mountpoint:$EXPECTED_HOME_PROPERTY_MOUNTPOINT"
        "recordsize:$EXPECTED_HOME_PROPERTY_RECORDSIZE"
        "compression:$EXPECTED_HOME_PROPERTY_COMPRESSION"
        "atime:$EXPECTED_HOME_PROPERTY_ATIME"
    )
    
    local mismatches=0
    
    for prop_pair in "${properties[@]}"; do
        local prop="${prop_pair%%:*}"
        local expected="${prop_pair#*:}"
        
        local actual
        actual=$(zfs get -H -o value "$prop" "$home_dataset" 2>/dev/null || echo "")
        
        if [[ "$actual" != "$expected" ]]; then
            warning "$prop: $actual (expected: $expected from config)"
            ((mismatches++))
            
            # Compression and atime can be changed
            if [[ "$prop" =~ ^(compression|atime)$ ]]; then
                if [[ "$REPAIR_MODE" == "true" ]]; then
                    repair_dataset_property "$home_dataset" "$prop" "$expected"
                fi
            else
                info "Note: $prop cannot be changed after dataset creation"
            fi
        else
            success "$prop: $actual (matches config)"
        fi
    done
    
    if [[ $mismatches -eq 0 ]]; then
        increment_check "ok"
    else
        increment_check "warn"
    fi
}

check_dataset_quotas() {
    local pool="$1"
    
    header "Dataset Quotas: $pool"
    
    debug "Checking dataset quotas: $pool"
    
    local datasets
    datasets=$(zfs list -H -o name -r "$pool" 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No datasets found in pool"
        increment_check "warn"
        return 0
    fi
    
    local quota_count=0
    
    while IFS= read -r dataset; do
        local quota
        quota=$(zfs get -H -o value quota "$dataset" 2>/dev/null || echo "none")
        
        if [[ "$quota" != "none" ]]; then
            info "Quota set on $dataset: $quota"
            ((quota_count++))
        fi
    done <<< "$datasets"
    
    if [[ $quota_count -eq 0 ]]; then
        info "No quotas configured"
    else
        success "Quotas configured on $quota_count dataset(s)"
    fi
    
    increment_check "ok"
}

check_snapshot_count() {
    local pool="$1"
    
    header "Snapshot Counts: $pool"
    
    debug "Checking snapshot counts: $pool"
    
    local datasets
    datasets=$(zfs list -H -o name -r "$pool" 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No datasets found in pool"
        increment_check "warn"
        return 0
    fi
    
    local excessive_count=0
    
    while IFS= read -r dataset; do
        local snap_count
        snap_count=$(zfs list -t snapshot -H -o name -r "$dataset" 2>/dev/null | wc -l || echo "0")
        
        # Check against threshold from config: MAX_SNAPSHOTS_PER_DATASET
        if [[ $snap_count -gt $MAX_SNAPSHOTS_PER_DATASET ]]; then
            warning "$dataset: $snap_count snapshots (> $MAX_SNAPSHOTS_PER_DATASET from config)"
            ((excessive_count++))
        elif [[ "$VERBOSE_MODE" == "true" ]] && [[ $snap_count -gt 0 ]]; then
            info "$dataset: $snap_count snapshots"
        fi
    done <<< "$datasets"
    
    if [[ $excessive_count -eq 0 ]]; then
        success "All datasets have reasonable snapshot counts"
        increment_check "ok"
    else
        warning "$excessive_count dataset(s) have excessive snapshots"
        increment_check "warn"
        info "Consider pruning old snapshots"
    fi
}

check_dataset_structure() {
    local pool="$1"
    
    header "Dataset Structure: $pool"
    
    debug "Checking dataset structure: $pool"
    
    # Check for ROOT container (from config: ROOT_CONTAINER)
    local root_container="${pool}/${ROOT_CONTAINER}"
    if ! zfs list -H -o name "$root_container" &>/dev/null; then
        warning "ROOT container not found: $root_container (expected from config)"
        POOL_WARNINGS["${pool}_structure"]="Missing ROOT container"
        increment_check "warn"
    else
        success "ROOT container exists: $root_container"
        increment_check "ok"
    fi
    
    # Check for data container (from config: DATA_CONTAINER)
    local data_container="${pool}/${DATA_CONTAINER}"
    if ! zfs list -H -o name "$data_container" &>/dev/null; then
        info "Data container not found: $data_container (optional)"
    else
        success "Data container exists: $data_container"
        increment_check "ok"
    fi
}

# ============================================
# SYSTEM CONFIGURATION CHECK FUNCTIONS
# ============================================

check_hostid() {
    header "System: Hostid"
    
    debug "Checking system hostid from config: $ZFS_HOSTID_FILE"
    
    if [[ ! -f "$ZFS_HOSTID_FILE" ]]; then
        error "Hostid file not found: $ZFS_HOSTID_FILE (from config)"
        SYSTEM_ISSUES["hostid"]="Missing"
        increment_check "error"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_hostid
        fi
        return 1
    fi
    
    # Check file size (must be exactly 4 bytes)
    local size
    size=$(stat -c %s "$ZFS_HOSTID_FILE" 2>/dev/null || echo "0")
    if [[ "$size" != "4" ]]; then
        error "Hostid file has incorrect size: $size bytes (should be 4)"
        SYSTEM_ISSUES["hostid"]="Invalid size"
        increment_check "error"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_hostid
        fi
        return 1
    fi
    
    # Verify hostid matches current system
    local file_hostid current_hostid
    file_hostid=$(od -An -tx4 "$ZFS_HOSTID_FILE" | tr -d ' ' 2>/dev/null || echo "")
    current_hostid=$(hostid 2>/dev/null || echo "")
    
    if [[ "$file_hostid" != "$current_hostid" ]]; then
        warning "Hostid mismatch: file=$file_hostid, current=$current_hostid"
        SYSTEM_ISSUES["hostid"]="Mismatch"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_hostid
        fi
    else
        success "Hostid OK: $current_hostid"
        increment_check "ok"
    fi
}

check_zpool_cache() {
    header "System: ZPool Cache Files"
    
    debug "Checking zpool cache files"
    
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    local cache_issues=0
    
    for pool in "${pools[@]}"; do
        local cache_file
        cache_file="$(get_pool_cache_file "$pool")"
        
        debug "Checking cache file: $cache_file (from config pattern)"
        
        if [[ ! -f "$cache_file" ]]; then
            error "Pool cache file not found: $cache_file"
            SYSTEM_ISSUES["cache_$pool"]="Missing"
            ((cache_issues++))
            increment_check "error"
            
            if [[ "$REPAIR_MODE" == "true" ]]; then
                repair_zpool_cache "$pool"
            fi
        else
            success "Pool cache file exists: $cache_file"
            increment_check "ok"
            
            # Check permissions (should be 644)
            local perms
            perms=$(stat -c "%a" "$cache_file" 2>/dev/null || echo "")
            if [[ "$perms" != "644" ]]; then
                warning "Cache file permissions: $perms (should be 644)"
                SYSTEM_ISSUES["cache_${pool}_perms"]="Incorrect: $perms"
                increment_check "warn"
                
                if [[ "$REPAIR_MODE" == "true" ]]; then
                    repair_cache_permissions "$cache_file"
                fi
            fi
        fi
    done
    
    if [[ $cache_issues -eq 0 ]]; then
        success "All pool cache files OK"
    fi
}

check_dracut_config() {
    header "System: Dracut Configuration"
    
    debug "Checking dracut configuration from config paths"
    
    # Check main dracut.conf (from config: DRACUT_CONF)
    if [[ ! -f "$DRACUT_CONF" ]]; then
        error "Main dracut config not found: $DRACUT_CONF (from config)"
        SYSTEM_ISSUES["dracut_conf"]="Missing"
        increment_check "error"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_dracut_main_config
        fi
    else
        success "Main dracut config exists: $DRACUT_CONF"
        increment_check "ok"
        
        # Validate content against template
        validate_dracut_main_content
    fi
    
    # Check ZFS dracut config (from config: DRACUT_ZFS_CONF)
    if [[ ! -f "$DRACUT_ZFS_CONF" ]]; then
        error "ZFS dracut config not found: $DRACUT_ZFS_CONF (from config)"
        SYSTEM_ISSUES["dracut_zfs_conf"]="Missing"
        increment_check "error"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_dracut_zfs_config
        fi
    else
        success "ZFS dracut config exists: $DRACUT_ZFS_CONF"
        increment_check "ok"
        
        # Validate content
        validate_dracut_zfs_content
    fi
}

validate_dracut_main_content() {
    debug "Validating dracut main config content"
    
    # Check for required settings from template
    local required_settings=(
        'hostonly="yes"'
        'compress="zstd"'
        'early_microcode="yes"'
    )
    
    local missing=0
    for setting in "${required_settings[@]}"; do
        if ! grep -qF "$setting" "$DRACUT_CONF" 2>/dev/null; then
            warning "Missing setting in $DRACUT_CONF: $setting"
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        SYSTEM_ISSUES["dracut_conf_content"]="Incomplete: $missing settings"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_dracut_main_config
        fi
    else
        success "Dracut main config content validated"
        increment_check "ok"
    fi
}

validate_dracut_zfs_content() {
    debug "Validating dracut ZFS config content"
    
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    # Check that hostid is in install_items (from config: ZFS_HOSTID_FILE)
    if ! grep -qF "$ZFS_HOSTID_FILE" "$DRACUT_ZFS_CONF" 2>/dev/null; then
        warning "Hostid not in dracut config: $ZFS_HOSTID_FILE"
        SYSTEM_ISSUES["dracut_hostid"]="Not included"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_dracut_zfs_config
        fi
    fi
    
    # Check that pool keys are in install_items
    local missing_keys=0
    for pool in "${pools[@]}"; do
        local key_file
        key_file="$(get_pool_key_file "$pool")"
        
        if [[ -f "$key_file" ]]; then
            if ! grep -qF "$key_file" "$DRACUT_ZFS_CONF" 2>/dev/null; then
                warning "Pool key not in dracut config: $key_file"
                SYSTEM_ISSUES["dracut_key_$pool"]="Not included"
                ((missing_keys++))
                increment_check "warn"
            fi
        fi
    done
    
    if [[ $missing_keys -gt 0 ]] && [[ "$REPAIR_MODE" == "true" ]]; then
        repair_dracut_zfs_config
    fi
    
    if [[ $missing_keys -eq 0 ]]; then
        success "All pool keys in dracut config"
        increment_check "ok"
    fi
}

check_initramfs() {
    header "System: Initramfs"
    
    debug "Checking initramfs from config: $INITRAMFS_DIR"
    
    local kernel_version
    kernel_version=$(uname -r)
    
    local initramfs_file="${INITRAMFS_DIR}/initramfs-${kernel_version}.img"
    
    if [[ ! -f "$initramfs_file" ]]; then
        error "Initramfs not found: $initramfs_file"
        SYSTEM_ISSUES["initramfs"]="Missing"
        increment_check "error"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_initramfs
        fi
        return 1
    fi
    
    success "Initramfs exists: $initramfs_file"
    increment_check "ok"
    
    # Check initramfs age vs kernel
    local initramfs_age kernel_age
    initramfs_age=$(stat -c %Y "$initramfs_file" 2>/dev/null || echo "0")
    kernel_age=$(stat -c %Y "/boot/vmlinuz-${kernel_version}" 2>/dev/null || echo "0")
    
    if [[ $initramfs_age -lt $kernel_age ]]; then
        warning "Initramfs is older than kernel"
        SYSTEM_ISSUES["initramfs_age"]="Outdated"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_initramfs
        fi
    fi
    
    # Verify critical files in initramfs
    verify_initramfs_contents "$initramfs_file"
}

verify_initramfs_contents() {
    local initramfs_file="$1"
    
    info "Verifying initramfs contents..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Extract initramfs
    if ! (cd "$temp_dir" && zcat "$initramfs_file" 2>/dev/null | cpio -id 2>/dev/null); then
        warning "Failed to extract initramfs for inspection"
        rm -rf "$temp_dir"
        return 0
    fi
    
    local verification_failed=false
    
    # Check for hostid (from config: ZFS_HOSTID_FILE)
    if [[ ! -f "$temp_dir${ZFS_HOSTID_FILE}" ]]; then
        error "Hostid not found in initramfs: $ZFS_HOSTID_FILE"
        SYSTEM_ISSUES["initramfs_hostid"]="Missing"
        verification_failed=true
        increment_check "error"
    else
        success "Hostid found in initramfs"
        increment_check "ok"
    fi
    
    # Check for pool keys
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    local missing_keys=0
    for pool in "${pools[@]}"; do
        local key_file
        key_file="$(get_pool_key_file "$pool")"
        
        if [[ -f "$key_file" ]]; then
            if [[ ! -f "$temp_dir${key_file}" ]]; then
                error "Pool key not found in initramfs: $key_file"
                SYSTEM_ISSUES["initramfs_key_$pool"]="Missing"
                ((missing_keys++))
                verification_failed=true
                increment_check "error"
            else
                success "Pool key found in initramfs: $key_file"
                increment_check "ok"
            fi
        fi
    done
    
    rm -rf "$temp_dir"
    
    if [[ "$verification_failed" == "true" ]] && [[ "$REPAIR_MODE" == "true" ]]; then
        repair_initramfs
    fi
}

check_zfsbootmenu() {
    header "System: ZFSBootMenu"
    
    debug "Checking ZFSBootMenu configuration"
    
    # Check if ZFSBootMenu is installed
    if ! command -v generate-zbm &>/dev/null; then
        warning "ZFSBootMenu not installed"
        SYSTEM_ISSUES["zbm"]="Not installed"
        increment_check "warn"
        return 0
    fi
    
    success "ZFSBootMenu is installed"
    increment_check "ok"
    
    # Check ZBM config (from config: ZBM_CONFIG)
    if [[ ! -f "$ZBM_CONFIG" ]]; then
        warning "ZFSBootMenu config not found: $ZBM_CONFIG (from config)"
        SYSTEM_ISSUES["zbm_config"]="Missing"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_zfsbootmenu_config
        fi
    else
        success "ZFSBootMenu config exists: $ZBM_CONFIG"
        increment_check "ok"
    fi
    
    # Check EFI directory (from config: ZBM_EFI_DIR)
    if [[ ! -d "$ZBM_EFI_DIR" ]]; then
        warning "ZFSBootMenu EFI directory not found: $ZBM_EFI_DIR (from config)"
        SYSTEM_ISSUES["zbm_efi"]="Missing"
        increment_check "warn"
    else
        success "ZFSBootMenu EFI directory exists: $ZBM_EFI_DIR"
        increment_check "ok"
        
        # Check for ZBM EFI files
        if [[ ! -f "$ZBM_EFI_DIR/vmlinuz.EFI" ]] && [[ ! -f "$ZBM_EFI_DIR/vmlinuz-backup.EFI" ]]; then
            error "ZFSBootMenu EFI files not found in $ZBM_EFI_DIR"
            SYSTEM_ISSUES["zbm_efi_files"]="Missing"
            increment_check "error"
            
            if [[ "$REPAIR_MODE" == "true" ]]; then
                repair_zfsbootmenu
            fi
        else
            success "ZFSBootMenu EFI files found"
            increment_check "ok"
        fi
    fi
    
    # Check org.zfsbootmenu:commandline property on boot datasets
    check_zbm_properties
}

check_zbm_properties() {
    debug "Checking ZFSBootMenu properties on boot datasets"
    
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    for pool in "${pools[@]}"; do
        local bootfs
        bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "")
        
        if [[ -n "$bootfs" ]] && [[ "$bootfs" != "-" ]]; then
            local cmdline
            cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "$bootfs" 2>/dev/null || echo "")
            
            if [[ -z "$cmdline" ]] || [[ "$cmdline" == "-" ]]; then
                warning "Boot dataset $bootfs missing org.zfsbootmenu:commandline"
                SYSTEM_ISSUES["zbm_cmdline_$pool"]="Missing"
                increment_check "warn"
                
                if [[ "$REPAIR_MODE" == "true" ]]; then
                    repair_zbm_property "$bootfs"
                fi
            else
                success "Boot dataset $bootfs has ZFSBootMenu commandline"
                increment_check "ok"
            fi
        fi
    done
}

check_fstab() {
    header "System: fstab"
    
    debug "Checking fstab from config: $FSTAB"
    
    if [[ ! -f "$FSTAB" ]]; then
        error "fstab not found: $FSTAB (from config)"
        SYSTEM_ISSUES["fstab"]="Missing"
        increment_check "error"
        return 1
    fi
    
    success "fstab exists"
    increment_check "ok"
    
    # Check for EFI mount entry (from config: ESP_MOUNT)
    if ! grep -q "${ESP_MOUNT}" "$FSTAB" 2>/dev/null; then
        warning "EFI mount not found in fstab: $ESP_MOUNT (from config)"
        SYSTEM_ISSUES["fstab_efi"]="Missing entry"
        increment_check "warn"
        
        if [[ "$REPAIR_MODE" == "true" ]]; then
            repair_fstab
        fi
    else
        success "EFI mount entry found in fstab"
        increment_check "ok"
    fi
}

check_system_configs() {
    header "System: Configuration Files"
    
    debug "Checking system configuration files from config"
    
    # Check rc.conf (from config: RC_CONF)
    if [[ ! -f "$RC_CONF" ]]; then
        warning "rc.conf not found: $RC_CONF (from config)"
        SYSTEM_ISSUES["rc_conf"]="Missing"
        increment_check "warn"
    else
        success "rc.conf exists"
        increment_check "ok"
    fi
    
    # Check other configs if verbose
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        check_optional_config "$IWD_CONF" "iwd.conf"
        check_optional_config "$RESOLVCONF_CONF" "resolvconf.conf"
        check_optional_config "$SYSCTL_CONF" "sysctl.conf"
        check_optional_config "$SUDOERS_WHEEL_FILE" "sudoers wheel"
    fi
}

check_optional_config() {
    local config_file="$1"
    local config_name="$2"
    
    if [[ -f "$config_file" ]]; then
        success "$config_name exists: $config_file"
    else
        info "$config_name not found: $config_file (may use defaults)"
    fi
}

check_runit_services() {
    header "System: Runit Services"
    
    debug "Checking runit service links"
    
    local service_dir="/etc/runit/runsvdir/default"
    
    if [[ ! -d "$service_dir" ]]; then
        warning "Runit service directory not found: $service_dir"
        SYSTEM_ISSUES["runit_dir"]="Missing"
        increment_check "warn"
        return 1
    fi
    
    # Check essential services (from config: ESSENTIAL_SERVICES)
    local essential_missing=0
    for service in $ESSENTIAL_SERVICES; do
        if [[ ! -L "$service_dir/$service" ]]; then
            warning "Essential service not enabled: $service"
            SYSTEM_ISSUES["service_$service"]="Not enabled"
            ((essential_missing++))
            increment_check "warn"
        elif [[ "$VERBOSE_MODE" == "true" ]]; then
            success "Service enabled: $service"
        fi
    done
    
    # Check ZFS services (from config: ZFS_SERVICES)
    local zfs_missing=0
    for service in $ZFS_SERVICES; do
        if [[ ! -L "$service_dir/$service" ]]; then
            warning "ZFS service not enabled: $service"
            SYSTEM_ISSUES["service_$service"]="Not enabled"
            ((zfs_missing++))
            increment_check "warn"
        elif [[ "$VERBOSE_MODE" == "true" ]]; then
            success "ZFS service enabled: $service"
        fi
    done
    
    if [[ $essential_missing -eq 0 ]] && [[ $zfs_missing -eq 0 ]]; then
        success "All configured services are enabled"
        increment_check "ok"
    fi
}

# Part 2: Repair Functions and Main

# ============================================
# REPAIR FUNCTIONS
# ============================================

repair_pool_property() {
    local pool="$1"
    local property="$2"
    local value="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set $pool property: $property=$value"
        return 0
    fi
    
    info "Setting $pool property: $property=$value"
    
    if zpool set "$property=$value" "$pool" 2>/dev/null; then
        success "Property set successfully"
        SYSTEM_REPAIRS["${pool}_${property}"]="Set to $value"
        return 0
    else
        error "Failed to set property"
        return 1
    fi
}

repair_dataset_property() {
    local dataset="$1"
    local property="$2"
    local value="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set $dataset property: $property=$value"
        return 0
    fi
    
    info "Setting $dataset property: $property=$value"
    
    if zfs set "$property=$value" "$dataset" 2>/dev/null; then
        success "Property set successfully"
        SYSTEM_REPAIRS["${dataset}_${property}"]="Set to $value"
        return 0
    else
        error "Failed to set property"
        return 1
    fi
}

repair_key_permissions() {
    local key_file="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set permissions on: $key_file to 000"
        return 0
    fi
    
    info "Setting secure permissions on key file: $key_file"
    
    if chmod 000 "$key_file" 2>/dev/null; then
        success "Permissions set to 000"
        SYSTEM_REPAIRS["key_perms_$(basename "$key_file")"]="Set to 000"
        return 0
    else
        error "Failed to set permissions"
        return 1
    fi
}

repair_key_backup() {
    local key_file="$1"
    local backup_file="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would backup $key_file to $backup_file"
        return 0
    fi
    
    info "Creating key backup: $backup_file"
    
    # Ensure backup directory exists (from config: ZFS_KEY_BACKUP_DIR)
    mkdir -p "$(dirname "$backup_file")"
    
    if cp "$key_file" "$backup_file" 2>/dev/null && chmod 000 "$backup_file" 2>/dev/null; then
        success "Key backup created with secure permissions"
        SYSTEM_REPAIRS["key_backup_$(basename "$key_file")"]="Created"
        return 0
    else
        error "Failed to create key backup"
        return 1
    fi
}

repair_hostid() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would regenerate hostid: $ZFS_HOSTID_FILE"
        return 0
    fi
    
    info "Regenerating hostid: $ZFS_HOSTID_FILE (from config)"
    
    # Generate new hostid
    if zgenhostid -f 2>/dev/null; then
        success "Hostid regenerated: $ZFS_HOSTID_FILE"
        SYSTEM_REPAIRS["hostid"]="Regenerated"
        
        # Hostid changed, need to rebuild initramfs
        info "Hostid changed, initramfs needs to be rebuilt"
        repair_initramfs
        return 0
    else
        error "Failed to generate hostid"
        return 1
    fi
}

repair_zpool_cache() {
    local pool="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local cache_file
        cache_file="$(get_pool_cache_file "$pool")"
        info "[DRY-RUN] Would regenerate pool cache: $cache_file"
        return 0
    fi
    
    info "Regenerating pool cache for: $pool"
    
    local cache_file
    cache_file="$(get_pool_cache_file "$pool")"
    
    # Set cachefile property using config pattern
    if zpool set cachefile="$cache_file" "$pool" 2>/dev/null; then
        success "Pool cache regenerated: $cache_file"
        SYSTEM_REPAIRS["cache_$pool"]="Regenerated"
        return 0
    else
        error "Failed to regenerate pool cache"
        return 1
    fi
}

repair_cache_permissions() {
    local cache_file="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set permissions on: $cache_file to 644"
        return 0
    fi
    
    info "Setting permissions on cache file: $cache_file"
    
    if chmod 644 "$cache_file" 2>/dev/null; then
        success "Permissions set to 644"
        SYSTEM_REPAIRS["cache_perms_$(basename "$cache_file")"]="Set to 644"
        return 0
    else
        error "Failed to set permissions"
        return 1
    fi
}

repair_dracut_main_config() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would create/update: $DRACUT_CONF (from config)"
        return 0
    fi
    
    info "Creating/updating main dracut configuration: $DRACUT_CONF"
    
    # Use template from config: DRACUT_CONF_CONTENT
    echo "$DRACUT_CONF_CONTENT" > "$DRACUT_CONF"
    
    if [[ $? -eq 0 ]]; then
        success "Dracut main config created from template"
        info "Template source: zfs-setup.conf::DRACUT_CONF_CONTENT"
        SYSTEM_REPAIRS["dracut_conf"]="Created from template"
        
        # Config changed, rebuild initramfs
        repair_initramfs
        return 0
    else
        error "Failed to create dracut main config"
        return 1
    fi
}

repair_dracut_zfs_config() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would create/update: $DRACUT_ZFS_CONF (from config)"
        return 0
    fi
    
    info "Creating/updating ZFS dracut configuration: $DRACUT_ZFS_CONF"
    
    # Ensure directory exists (from config: DRACUT_CONF_DIR)
    mkdir -p "$DRACUT_CONF_DIR"
    
    # Get all pools
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    if [[ ${#pools[@]} -eq 0 ]]; then
        error "No ZFS pools found"
        return 1
    fi
    
    # Generate config using helper function and template from config
    local config_content
    config_content="$(generate_dracut_zfs_config "${pools[@]}")"
    
    if [[ -z "$config_content" ]]; then
        error "Failed to generate dracut ZFS config from template"
        return 1
    fi
    
    # Write config
    echo "$config_content" > "$DRACUT_ZFS_CONF"
    
    if [[ $? -eq 0 ]]; then
        success "Dracut ZFS config created from template"
        info "Template source: zfs-setup.conf::DRACUT_ZFS_CONF_TEMPLATE"
        
        # Show what was included
        info "Included files:"
        echo "$config_content" | grep -oP '(?<=install_items\+=" ).*(?= ")' | tr ' ' '\n' | sed 's/^/  - /'
        
        SYSTEM_REPAIRS["dracut_zfs_conf"]="Created from template"
        
        # Config changed, rebuild initramfs
        repair_initramfs
        return 0
    else
        error "Failed to create dracut ZFS config"
        return 1
    fi
}

repair_initramfs() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would rebuild initramfs"
        return 0
    fi
    
    info "Rebuilding initramfs..."
    
    # Validate prerequisites from config
    validate_config_loaded || return 1
    
    # Ensure dracut configs exist
    if [[ ! -f "$DRACUT_CONF" ]]; then
        warning "Main dracut config missing, creating from template..."
        repair_dracut_main_config || return 1
    fi
    
    if [[ ! -f "$DRACUT_ZFS_CONF" ]]; then
        warning "ZFS dracut config missing, creating from template..."
        repair_dracut_zfs_config || return 1
    fi
    
    # Ensure hostid exists (from config: ZFS_HOSTID_FILE)
    if [[ ! -f "$ZFS_HOSTID_FILE" ]]; then
        warning "Hostid missing, generating..."
        repair_hostid || return 1
    fi
    
    # Get kernel version
    local kernel_version
    kernel_version=$(uname -r)
    
    local initramfs_file="${INITRAMFS_DIR}/initramfs-${kernel_version}.img"
    
    info "Rebuilding initramfs for kernel: $kernel_version"
    info "Output: $initramfs_file"
    info "Using configuration:"
    info "  Main config: $DRACUT_CONF"
    info "  ZFS config: $DRACUT_ZFS_CONF"
    info "  Templates from: zfs-setup.conf v${CONFIG_VERSION}"
    
    # Rebuild initramfs
    if dracut --force \
             --hostonly \
             --no-hostonly-cmdline \
             --kver "$kernel_version" \
             "$initramfs_file" \
             2>&1 | tee /tmp/dracut-rebuild.log; then
        success "Initramfs rebuilt successfully"
        SYSTEM_REPAIRS["initramfs"]="Rebuilt with config templates"
        
        # Verify contents
        verify_initramfs_contents "$initramfs_file"
        return $?
    else
        error "Failed to rebuild initramfs"
        error "Check log: /tmp/dracut-rebuild.log"
        return 1
    fi
}

repair_zfsbootmenu_config() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would create ZFSBootMenu config: $ZBM_CONFIG (from config)"
        return 0
    fi
    
    info "Creating ZFSBootMenu configuration: $ZBM_CONFIG"
    
    # Ensure config directory exists
    mkdir -p "$(dirname "$ZBM_CONFIG")"
    
    # Use template from config: ZBM_CONFIG_CONTENT
    echo "$ZBM_CONFIG_CONTENT" > "$ZBM_CONFIG"
    
    if [[ $? -eq 0 ]]; then
        success "ZFSBootMenu config created from template"
        info "Template source: zfs-setup.conf::ZBM_CONFIG_CONTENT"
        SYSTEM_REPAIRS["zbm_config"]="Created from template"
        
        # Config created, regenerate ZFSBootMenu
        repair_zfsbootmenu
        return 0
    else
        error "Failed to create ZFSBootMenu config"
        return 1
    fi
}

repair_zfsbootmenu() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would regenerate ZFSBootMenu"
        return 0
    fi
    
    info "Regenerating ZFSBootMenu..."
    
    # Ensure config exists
    if [[ ! -f "$ZBM_CONFIG" ]]; then
        warning "ZFSBootMenu config missing, creating from template..."
        repair_zfsbootmenu_config || return 1
    fi
    
    # Ensure EFI directory exists (from config: ZBM_EFI_DIR)
    mkdir -p "$ZBM_EFI_DIR"
    
    # Regenerate ZFSBootMenu
    if generate-zbm --config "$ZBM_CONFIG" 2>&1 | tee /tmp/zbm-generate.log; then
        success "ZFSBootMenu regenerated successfully"
        SYSTEM_REPAIRS["zbm"]="Regenerated"
        
        # Verify EFI files were created
        if [[ -f "$ZBM_EFI_DIR/vmlinuz.EFI" ]]; then
            success "ZFSBootMenu EFI files created"
        else
            warning "ZFSBootMenu EFI files not found after generation"
        fi
        
        return 0
    else
        error "Failed to regenerate ZFSBootMenu"
        error "Check log: /tmp/zbm-generate.log"
        return 1
    fi
}

repair_zbm_property() {
    local dataset="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would set org.zfsbootmenu:commandline on: $dataset"
        return 0
    fi
    
    info "Setting org.zfsbootmenu:commandline on: $dataset"
    
    # Use commandline from config: ZBM_COMMANDLINE_PROPERTY
    if zfs set org.zfsbootmenu:commandline="$ZBM_COMMANDLINE_PROPERTY" "$dataset" 2>/dev/null; then
        success "ZFSBootMenu commandline property set"
        info "Value: $ZBM_COMMANDLINE_PROPERTY (from config)"
        SYSTEM_REPAIRS["zbm_cmdline_$dataset"]="Set from config"
        return 0
    else
        error "Failed to set ZFSBootMenu property"
        return 1
    fi
}

repair_fstab() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would update fstab: $FSTAB (from config)"
        return 0
    fi
    
    info "Updating fstab: $FSTAB"
    
    # Find EFI partition (from config: ESP_MOUNT)
    local efi_partition
    efi_partition=$(findmnt -n -o SOURCE "$ESP_MOUNT" 2>/dev/null)
    
    if [[ -z "$efi_partition" ]]; then
        error "Cannot determine EFI partition for $ESP_MOUNT (from config)"
        return 1
    fi
    
    # Get EFI UUID
    local efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$efi_partition" 2>/dev/null)
    
    if [[ -z "$efi_uuid" ]]; then
        error "Cannot determine EFI partition UUID"
        return 1
    fi
    
    info "EFI partition: $efi_partition (UUID: $efi_uuid)"
    
    # Backup fstab
    local backup="${FSTAB}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$FSTAB" "$backup"
    success "Backed up fstab to: $backup"
    
    # Check if EFI entry already exists
    if grep -q "${ESP_MOUNT}" "$FSTAB" 2>/dev/null; then
        info "EFI mount entry already exists in fstab"
        return 0
    fi
    
    # Generate EFI entry using template from config and helper function
    local efi_entry
    efi_entry="$(substitute_template "$FSTAB_EFI_TEMPLATE" "EFI_UUID=$efi_uuid")"
    
    # Add entry to fstab
    echo "$efi_entry" >> "$FSTAB"
    
    if [[ $? -eq 0 ]]; then
        success "Added EFI mount entry to fstab"
        info "Template source: zfs-setup.conf::FSTAB_EFI_TEMPLATE"
        info "Entry: $efi_entry"
        SYSTEM_REPAIRS["fstab_efi"]="Added from template"
        return 0
    else
        error "Failed to update fstab"
        return 1
    fi
}

# ============================================
# REPORTING FUNCTIONS
# ============================================

show_summary() {
    echo ""
    section "Health Check Summary"
    
    info "Total checks performed: $((CHECK_OK + CHECK_WARN + CHECK_ERROR))"
    
    if [[ $CHECK_OK -gt 0 ]]; then
        success "Passed: $CHECK_OK"
    fi
    
    if [[ $CHECK_WARN -gt 0 ]]; then
        warning "Warnings: $CHECK_WARN"
    fi
    
    if [[ $CHECK_ERROR -gt 0 ]]; then
        error "Errors: $CHECK_ERROR"
    fi
    
    # Show configuration version
    echo ""
    info "Configuration: zfs-setup.conf v${CONFIG_VERSION} (${CONFIG_DATE})"
    info "Installation script: v${INSTALLATION_SCRIPT_VERSION}"
    
    # Show pool issues
    if [[ ${#POOL_ERRORS[@]} -gt 0 ]] || [[ ${#POOL_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        section "Pool Issues"
        
        if [[ ${#POOL_ERRORS[@]} -gt 0 ]]; then
            error "Pool Errors:"
            for key in "${!POOL_ERRORS[@]}"; do
                echo "  - $key: ${POOL_ERRORS[$key]}"
            done
        fi
        
        if [[ ${#POOL_WARNINGS[@]} -gt 0 ]]; then
            warning "Pool Warnings:"
            for key in "${!POOL_WARNINGS[@]}"; do
                echo "  - $key: ${POOL_WARNINGS[$key]}"
            done
        fi
    fi
    
    # Show system issues
    if [[ ${#SYSTEM_ISSUES[@]} -gt 0 ]]; then
        echo ""
        section "System Issues"
        
        for key in "${!SYSTEM_ISSUES[@]}"; do
            echo "  - $key: ${SYSTEM_ISSUES[$key]}"
        done
    fi
    
    # Show repairs performed
    if [[ ${#SYSTEM_REPAIRS[@]} -gt 0 ]]; then
        echo ""
        section "Repairs Performed"
        
        for key in "${!SYSTEM_REPAIRS[@]}"; do
            success "  - $key: ${SYSTEM_REPAIRS[$key]}"
        done
    fi
    
    echo ""
}

show_recommendations() {
    if [[ $CHECK_ERROR -eq 0 ]] && [[ $CHECK_WARN -eq 0 ]]; then
        return 0
    fi
    
    section "Recommendations"
    
    if [[ $CHECK_ERROR -gt 0 ]]; then
        error "Critical issues found. Recommended actions:"
        
        if [[ ${#POOL_ERRORS[@]} -gt 0 ]]; then
            echo "  - Check pool status with: zpool status"
            echo "  - Review pool errors: zpool status -v"
        fi
        
        if [[ -n "${SYSTEM_ISSUES[hostid]}" ]]; then
            echo "  - Regenerate hostid: zgenhostid -f"
            echo "  - Rebuild initramfs after hostid change"
        fi
        
        if [[ -n "${SYSTEM_ISSUES[initramfs]}" ]]; then
            echo "  - Rebuild initramfs: dracut --force"
        fi
    fi
    
    if [[ $CHECK_WARN -gt 0 ]]; then
        warning "Warnings found. Consider:"
        
        for key in "${!POOL_WARNINGS[@]}"; do
            if [[ "$key" =~ _scrub$ ]]; then
                local pool="${key%_scrub}"
                echo "  - Run scrub: zpool scrub $pool"
            fi
            
            if [[ "$key" =~ _capacity$ ]]; then
                local pool="${key%_capacity}"
                echo "  - Free up space on pool: $pool"
                echo "  - Consider: zfs list -t snapshot | grep $pool"
            fi
            
            if [[ "$key" =~ _frag$ ]]; then
                local pool="${key%_frag}"
                echo "  - Consider defragmentation for: $pool"
            fi
        done
    fi
    
    if [[ "$REPAIR_MODE" == "false" ]] && [[ $CHECK_ERROR -gt 0 ]]; then
        echo ""
        info "To automatically repair issues, run with --repair flag"
    fi
    
    echo ""
}

# ============================================
# MAIN CHECK ORCHESTRATION
# ============================================

run_pool_checks() {
    local pool="$1"
    
    banner "Checking Pool: $pool"
    
    check_pool_status "$pool"
    check_pool_capacity "$pool"
    check_pool_fragmentation "$pool"
    check_pool_properties "$pool"
    check_bootfs_property "$pool"
    check_pool_encryption "$pool"
    check_scrub_status "$pool"
    check_root_dataset_properties "$pool"
    check_home_dataset_properties "$pool"
    check_dataset_quotas "$pool"
    check_snapshot_count "$pool"
    check_dataset_structure "$pool"
}

run_system_checks() {
    banner "Checking System Configuration"
    
    check_hostid
    check_zpool_cache
    check_dracut_config
    check_initramfs
    check_zfsbootmenu
    check_fstab
    check_system_configs
    check_runit_services
}

run_all_checks() {
    # Get pools
    local pools
    if [[ -n "$TARGET_POOL" ]]; then
        # Check if specified pool exists
        if ! zpool list -H "$TARGET_POOL" &>/dev/null; then
            error "Pool not found: $TARGET_POOL"
            exit 1
        fi
        pools="$TARGET_POOL"
    else
        pools="$(get_pools)"
    fi
    
    if [[ -z "$pools" ]]; then
        error "No ZFS pools found"
        exit 1
    fi
    
    # Check each pool
    IFS=' ' read -ra pool_array <<< "$pools"
    for pool in "${pool_array[@]}"; do
        run_pool_checks "$pool"
    done
    
    # Check system configuration
    run_system_checks
}

create_success_snapshot() {
    if [[ "$SNAPSHOT_ON_SUCCESS" != "true" ]]; then
        return 0
    fi
    
    if [[ $CHECK_ERROR -gt 0 ]] || [[ $CHECK_WARN -gt 0 ]]; then
        info "Skipping snapshot creation due to warnings/errors"
        return 0
    fi
    
    section "Creating Success Snapshot"
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    local pools
    IFS=' ' read -ra pools <<< "$(get_pools)"
    
    for pool in "${pools[@]}"; do
        local snapshot_name="${pool}@health_check_${timestamp}"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] Would create snapshot: $snapshot_name"
        else
            info "Creating snapshot: $snapshot_name"
            
            if zfs snapshot -r "$snapshot_name" 2>/dev/null; then
                success "Snapshot created: $snapshot_name"
            else
                warning "Failed to create snapshot: $snapshot_name"
            fi
        fi
    done
}

# ============================================
# ARGUMENT PARSING
# ============================================

parse_arguments() {
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
            --dry-run)
                DRY_RUN=true
                REPAIR_MODE=true
                shift
                ;;
            --verbose|-v)
                VERBOSE_MODE=true
                shift
                ;;
            --snapshot)
                SNAPSHOT_ON_SUCCESS=true
                shift
                ;;
            --help|-h)
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
    
    # Enable debug mode if verbose
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        DEBUG_MODE=true
    fi
}

# ============================================
# MAIN FUNCTION
# ============================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Show script header
    banner "${SCRIPT_NAME} v${SCRIPT_VERSION}"
    info "Date: ${SCRIPT_DATE}"
    info "Configuration: zfs-setup.conf v${CONFIG_VERSION}"
    echo ""
    
    # Check prerequisites
    if ! check_root; then
        error "This script must be run as root"
        exit 3
    fi
    
    if ! command -v zpool &>/dev/null; then
        error "ZFS utilities not found"
        exit 3
    fi
    
    # Show mode information
    if [[ "$REPAIR_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            warning "DRY-RUN MODE: No changes will be made"
        else
            warning "REPAIR MODE: Issues will be automatically fixed"
            info "Press Ctrl+C within 5 seconds to cancel..."
            sleep 5
        fi
    fi
    
    if [[ -n "$TARGET_POOL" ]]; then
        info "Target pool: $TARGET_POOL"
    else
        info "Checking all pools"
    fi
    
    echo ""
    
    # Run all checks
    run_all_checks
    
    # Create success snapshot if requested
    create_success_snapshot
    
    # Show summary
    show_summary
    
    # Show recommendations
    show_recommendations
    
    # Exit with appropriate code
    if [[ $CHECK_ERROR -gt 0 ]]; then
        exit 2
    elif [[ $CHECK_WARN -gt 0 ]]; then
        exit 1
    else
        success "All checks passed!"
        exit 0
    fi
}

# ============================================
# SCRIPT ENTRY POINT
# ============================================

main "$@"
