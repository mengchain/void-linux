# Add these functions to the existing common.sh file

# ============================================
# CONFIGURATION HELPER FUNCTIONS
# ============================================

# Get pool-specific key file path
# Usage: key_file=$(get_pool_key_file "zroot")
get_pool_key_file() {
    local pool="$1"
    echo "${ZFS_KEY_FILE_PATTERN//\{\{POOL_NAME\}\}/${pool}}"
}

# Get pool-specific cache file path
# Usage: cache_file=$(get_pool_cache_file "zroot")
get_pool_cache_file() {
    local pool="$1"
    echo "${ZFS_CACHE_FILE_PATTERN//\{\{POOL_NAME\}\}/${pool}}"
}

# Get pool-specific key location property value
# Usage: key_location=$(get_pool_key_location "zroot")
get_pool_key_location() {
    local pool="$1"
    echo "${KEY_LOCATION_PATTERN//\{\{POOL_NAME\}\}/${pool}}"
}

# Get all pool key files for multiple pools
# Usage: keys=$(get_all_pool_keys "zroot" "tank")
# Returns: space-separated list of key files that exist
get_all_pool_keys() {
    local pools=("$@")
    local keys=()
    
    for pool in "${pools[@]}"; do
        local key_file
        key_file="$(get_pool_key_file "$pool")"
        if [[ -f "$key_file" ]]; then
            keys+=("$key_file")
        fi
    done
    
    echo "${keys[@]}"
}

# Substitute placeholders in template
# Usage: result=$(substitute_template "$template" "VAR1=value1" "VAR2=value2")
substitute_template() {
    local template="$1"
    shift
    
    local result="$template"
    
    for assignment in "$@"; do
        local var="${assignment%%=*}"
        local value="${assignment#*=}"
        result="${result//\{\{${var}\}\}/${value}}"
    done
    
    echo "$result"
}

# Generate dracut ZFS config with actual pool keys
# Usage: config=$(generate_dracut_zfs_config "zroot" "tank")
generate_dracut_zfs_config() {
    local pools=("$@")
    local pool_keys
    
    # Get all pool keys as space-separated string
    pool_keys="$(get_all_pool_keys "${pools[@]}")"
    
    # Substitute placeholders
    substitute_template "$DRACUT_ZFS_CONF_TEMPLATE" \
        "POOL_KEYS=$pool_keys" \
        "HOSTID_FILE=$ZFS_HOSTID_FILE"
}

# Generate rc.conf content with system values
# Usage: config=$(generate_rc_conf_content "$timezone" "$hardwareclock" "$keymap" "$font")
generate_rc_conf_content() {
    local timezone="${1:-$DEFAULT_TIMEZONE}"
    local hardwareclock="${2:-$DEFAULT_HARDWARECLOCK}"
    local keymap="${3:-$DEFAULT_KEYMAP}"
    local font="${4:-$DEFAULT_FONT}"
    
    substitute_template "$RC_CONF_TEMPLATE" \
        "TIMEZONE=$timezone" \
        "HARDWARECLOCK=$hardwareclock" \
        "KEYMAP=$keymap" \
        "FONT=$font"
}

# Generate complete fstab content
# Usage: fstab=$(generate_fstab_content "$efi_uuid" "$pool_name" "true")
generate_fstab_content() {
    local efi_uuid="$1"
    local pool_name="$2"
    local create_swap="${3:-false}"
    
    local fstab="$FSTAB_HEADER"$'\n'
    
    # EFI entry
    local efi_entry
    efi_entry="$(substitute_template "$FSTAB_EFI_TEMPLATE" "EFI_UUID=$efi_uuid")"
    fstab+="$efi_entry"$'\n'
    
    # tmpfs entries
    fstab+="$FSTAB_TMP_ENTRY"$'\n'
    fstab+="$FSTAB_SHM_ENTRY"$'\n'
    fstab+="$FSTAB_EFIVARFS_ENTRY"$'\n'
    
    # Swap entry if requested
    if [[ "$create_swap" == "true" ]]; then
        local swap_entry
        swap_entry="$(substitute_template "$FSTAB_SWAP_TEMPLATE" "POOL_NAME=$pool_name")"
        fstab+="$swap_entry"$'\n'
    fi
    
    echo "$fstab"
}

# Validate that required configuration variables are loaded
# Usage: validate_config_loaded || exit 1
validate_config_loaded() {
    local required_vars=(
        "CONFIG_VERSION"
        "ZFS_HOSTID_FILE"
        "ZFS_CONFIG_DIR"
        "DRACUT_CONF"
        "DRACUT_CONF_DIR"
        "ESP_MOUNT"
        "DRACUT_CONF_CONTENT"
        "DRACUT_ZFS_CONF_TEMPLATE"
    )
    
    local missing=0
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            error "Configuration variable not set: $var"
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        error "Configuration incomplete. Ensure zfs-setup.conf is loaded"
        return 1
    fi
    
    debug "Configuration validated: all required variables present (version $CONFIG_VERSION)"
    return 0
}

# Convert space-separated string to array
# Usage: array=($(string_to_array "$ESSENTIAL_SERVICES"))
string_to_array() {
    local string="$1"
    echo "$string"
}

# Get list of all ZFS pools
# Usage: pools=$(get_pools)
get_pools() {
    zpool list -H -o name 2>/dev/null || echo ""
}