#!/bin/sh
# filepath: networkConnect.sh
# Network Connection Script for Void Linux
# Supports both WiFi and Ethernet connections

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "${BLUE}[INFO]${NC} $1"
}

error() {
    echo "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Check required services and tools
check_requirements() {
    log "Checking system requirements..."
    
    # Check if NetworkManager is installed and running
    if ! command -v nmcli >/dev/null 2>&1; then
        error "NetworkManager not found. Install with: xbps-install -S NetworkManager"
        exit 1
    fi
    
    # Check if NetworkManager service is enabled
    if ! sv status NetworkManager >/dev/null 2>&1; then
        warning "NetworkManager service not running. Starting..."
        ln -sf /etc/sv/NetworkManager /var/service/
        sleep 2
    fi
    
    # Check if wpa_supplicant is available for WiFi
    if ! command -v wpa_supplicant >/dev/null 2>&1; then
        warning "wpa_supplicant not found. WiFi connections may not work."
        echo "Install with: xbps-install -S wpa_supplicant"
    fi
}

# Discover network devices
discover_devices() {
    log "Discovering network devices..."
    
    # Get WiFi devices
    wifi_devices=$(nmcli device | grep wifi | awk '{print $1}' | grep -v "^$" || true)
    
    # Get Ethernet devices
    ethernet_devices=$(nmcli device | grep ethernet | awk '{print $1}' | grep -v "^$" || true)
    
    if [ -z "$wifi_devices" ] && [ -z "$ethernet_devices" ]; then
        error "No network devices found"
        exit 1
    fi
    
    log "Available devices:"
    if [ -n "$wifi_devices" ]; then
        echo "${GREEN}WiFi devices:${NC}"
        echo "$wifi_devices" | while read -r device; do
            echo "  - $device"
        done
    fi
    
    if [ -n "$ethernet_devices" ]; then
        echo "${GREEN}Ethernet devices:${NC}"
        echo "$ethernet_devices" | while read -r device; do
            echo "  - $device"
        done
    fi
}

# Connect to Ethernet
connect_ethernet() {
    local device="$1"
    
    log "Attempting to connect via Ethernet on $device..."
    
    # Enable the device
    nmcli device set "$device" managed yes
    
    # Connect using DHCP
    if nmcli device connect "$device"; then
        success "Successfully connected to Ethernet on $device"
        return 0
    else
        error "Failed to connect to Ethernet on $device"
        return 1
    fi
}

# Scan for WiFi networks
scan_wifi() {
    local device="$1"
    
    log "Scanning for WiFi networks on $device..."
    
    # Enable WiFi if disabled
    nmcli radio wifi on
    
    # Rescan for networks
    nmcli device wifi rescan ifname "$device" 2>/dev/null || true
    sleep 3
    
    # List available networks
    log "Available WiFi networks:"
    nmcli device wifi list ifname "$device" | head -20
}

# Connect to WiFi
connect_wifi() {
    local device="$1"
    local ssid="$2"
    local password="$3"
    
    log "Attempting to connect to WiFi network: $ssid"
    
    # Check if network is open (no password required)
    security=$(nmcli device wifi list ifname "$device" | grep "^.*$ssid" | awk '{print $7}' | head -1)
    
    if [ "$security" = "--" ]; then
        # Open network
        if nmcli device wifi connect "$ssid" ifname "$device"; then
            success "Successfully connected to open WiFi network: $ssid"
            return 0
        fi
    else
        # Secured network
        if [ -z "$password" ]; then
            error "Password required for secured network: $ssid"
            return 1
        fi
        
        if nmcli device wifi connect "$ssid" password "$password" ifname "$device"; then
            success "Successfully connected to WiFi network: $ssid"
            return 0
        fi
    fi
    
    error "Failed to connect to WiFi network: $ssid"
    return 1
}

# Test connection
test_connection() {
    log "Testing internet connectivity..."
    
    if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        success "Internet connection is working"
        
        # Show connection details
        echo "\n${BLUE}Connection details:${NC}"
        nmcli connection show --active
        
        return 0
    else
        warning "No internet connectivity detected"
        return 1
    fi
}

# Main menu
main_menu() {
    discover_devices
    
    echo "\n${BLUE}Select connection type:${NC}"
    echo "1) Ethernet"
    echo "2) WiFi"
    echo "3) Exit"
    
    printf "Enter your choice (1-3): "
    read -r choice
    
    case $choice in
        1)
            if [ -z "$ethernet_devices" ]; then
                error "No Ethernet devices available"
                return 1
            fi
            
            # If multiple Ethernet devices, let user choose
            device_count=$(echo "$ethernet_devices" | wc -l)
            if [ "$device_count" -gt 1 ]; then
                echo "\n${BLUE}Available Ethernet devices:${NC}"
                echo "$ethernet_devices" | nl -w2 -s') '
                printf "Select device: "
                read -r device_num
                device=$(echo "$ethernet_devices" | sed -n "${device_num}p")
            else
                device=$(echo "$ethernet_devices" | head -1)
            fi
            
            if [ -n "$device" ]; then
                connect_ethernet "$device"
                test_connection
            else
                error "Invalid device selection"
            fi
            ;;
        2)
            if [ -z "$wifi_devices" ]; then
                error "No WiFi devices available"
                return 1
            fi
            
            # If multiple WiFi devices, let user choose
            device_count=$(echo "$wifi_devices" | wc -l)
            if [ "$device_count" -gt 1 ]; then
                echo "\n${BLUE}Available WiFi devices:${NC}"
                echo "$wifi_devices" | nl -w2 -s') '
                printf "Select device: "
                read -r device_num
                device=$(echo "$wifi_devices" | sed -n "${device_num}p")
            else
                device=$(echo "$wifi_devices" | head -1)
            fi
            
            if [ -n "$device" ]; then
                scan_wifi "$device"
                
                printf "\nEnter SSID: "
                read -r ssid
                
                if [ -n "$ssid" ]; then
                    printf "Enter password (press Enter for open network): "
                    # Hide password input
                    stty -echo
                    read -r password
                    stty echo
                    echo
                    
                    connect_wifi "$device" "$ssid" "$password"
                    test_connection
                else
                    error "SSID cannot be empty"
                fi
            else
                error "Invalid device selection"
            fi
            ;;
        3)
            log "Exiting..."
            exit 0
            ;;
        *)
            error "Invalid choice"
            return 1
            ;;
    esac
}

# Signal handlers
cleanup() {
    echo "\n${YELLOW}Script interrupted${NC}"
    exit 130
}

trap cleanup INT TERM

# Main execution
main() {
    echo "${BLUE}=== Void Linux Network Connection Script ===${NC}\n"
    
    check_root
    check_requirements
    
    while true; do
        main_menu
        echo "\n${BLUE}Press Enter to continue or Ctrl+C to exit${NC}"
        read -r
    done
}

# Run main function
main "$@"fffff
