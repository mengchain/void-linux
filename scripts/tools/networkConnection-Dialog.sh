#!/bin/sh
# filepath: networkConnect-dialog.sh
# Network Connection Script for Void Linux with Dialog Interface
# Supports both WiFi and Ethernet connections

set -e

# Dialog configuration
DIALOG_HEIGHT=20
DIALOG_WIDTH=60
DIALOG_MENU_HEIGHT=10
BACKTITLE="Void Linux Network Manager"

# Colors for fallback output (when dialog is not available)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Temporary files for dialog
TEMP_DIR="/tmp/void-network-$$"
WIFI_LIST="$TEMP_DIR/wifi_list"
DEVICE_LIST="$TEMP_DIR/device_list"
INPUT_FILE="$TEMP_DIR/input"

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Create temp directory
mkdir -p "$TEMP_DIR"

# Logging functions for fallback
log_fallback() {
    echo "${BLUE}[INFO]${NC} $1"
}

error_fallback() {
    echo "${RED}[ERROR]${NC} $1" >&2
}

# Check if dialog is available
check_dialog() {
    if ! command -v dialog >/dev/null 2>&1; then
        error_fallback "dialog package not found. Install with: xbps-install -S dialog"
        exit 1
    fi
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v dialog >/dev/null 2>&1; then
            dialog --title "Permission Error" \
                   --msgbox "This script must be run as root.\n\nPlease run: sudo $0" \
                   8 50
        else
            error_fallback "This script must be run as root"
        fi
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    local missing_packages=""
    
    # Check NetworkManager
    if ! command -v nmcli >/dev/null 2>&1; then
        missing_packages="${missing_packages}NetworkManager "
    fi
    
    # Check wpa_supplicant for WiFi
    if ! command -v wpa_supplicant >/dev/null 2>&1; then
        missing_packages="${missing_packages}wpa_supplicant "
    fi
    
    if [ -n "$missing_packages" ]; then
        dialog --title "Missing Dependencies" \
               --yesno "The following packages are missing:\n${missing_packages}\n\nWould you like to install them now?" \
               10 60
        
        if [ $? -eq 0 ]; then
            # Install missing packages
            if ! xbps-install -Sy $missing_packages; then
                dialog --title "Installation Failed" \
                       --msgbox "Failed to install required packages.\nPlease install manually: xbps-install -S $missing_packages" \
                       8 60
                exit 1
            fi
        else
            exit 1
        fi
    fi
    
    # Check and start NetworkManager service
    if ! sv status NetworkManager >/dev/null 2>&1; then
        dialog --title "Starting NetworkManager" \
               --infobox "NetworkManager service not running.\nStarting NetworkManager..." \
               6 50
        
        ln -sf /etc/sv/NetworkManager /var/service/
        sleep 3
        
        if ! sv status NetworkManager >/dev/null 2>&1; then
            dialog --title "Service Error" \
                   --msgbox "Failed to start NetworkManager service.\nPlease check system logs." \
                   6 50
            exit 1
        fi
    fi
}

# Get available network devices
get_network_devices() {
    # Get WiFi devices
    wifi_devices=$(nmcli device | awk '$2=="wifi" {print $1}' | grep -v "^$" || true)
    
    # Get Ethernet devices  
    ethernet_devices=$(nmcli device | awk '$2=="ethernet" {print $1}' | grep -v "^$" || true)
    
    if [ -z "$wifi_devices" ] && [ -z "$ethernet_devices" ]; then
        dialog --title "No Devices Found" \
               --msgbox "No network devices detected.\nPlease check your hardware." \
               6 50
        exit 1
    fi
}

# Select network device
select_device() {
    local device_type="$1"
    local devices
    
    case "$device_type" in
        "wifi")
            devices="$wifi_devices"
            ;;
        "ethernet")
            devices="$ethernet_devices"
            ;;
        *)
            return 1
            ;;
    esac
    
    if [ -z "$devices" ]; then
        dialog --title "No Devices" \
               --msgbox "No $device_type devices available." \
               6 40
        return 1
    fi
    
    # Count devices
    device_count=$(echo "$devices" | wc -l)
    
    if [ "$device_count" -eq 1 ]; then
        # Only one device, use it
        selected_device=$(echo "$devices" | head -1)
        return 0
    fi
    
    # Multiple devices, create menu
    > "$DEVICE_LIST"
    counter=1
    echo "$devices" | while IFS= read -r device; do
        if [ -n "$device" ]; then
            echo "$counter" "$device" >> "$DEVICE_LIST"
            counter=$((counter + 1))
        fi
    done
    
    dialog --title "Select Device" \
           --menu "Choose $device_type device:" \
           15 50 8 \
           --file "$DEVICE_LIST" 2> "$INPUT_FILE"
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    choice=$(cat "$INPUT_FILE")
    selected_device=$(echo "$devices" | sed -n "${choice}p")
    
    return 0
}

# Connect to Ethernet
connect_ethernet() {
    local device="$1"
    
    dialog --title "Connecting" \
           --infobox "Connecting to Ethernet on $device..." \
           5 40
    
    # Enable device management
    nmcli device set "$device" managed yes 2>/dev/null || true
    
    # Connect using DHCP
    if nmcli device connect "$device" >/dev/null 2>&1; then
        dialog --title "Success" \
               --msgbox "Successfully connected to Ethernet on $device" \
               6 50
        return 0
    else
        dialog --title "Connection Failed" \
               --msgbox "Failed to connect to Ethernet on $device" \
               6 50
        return 1
    fi
}

# Scan for WiFi networks
scan_wifi_networks() {
    local device="$1"
    
    dialog --title "Scanning" \
           --infobox "Scanning for WiFi networks on $device..." \
           5 40
    
    # Enable WiFi radio
    nmcli radio wifi on 2>/dev/null || true
    
    # Rescan for networks
    nmcli device wifi rescan ifname "$device" 2>/dev/null || true
    sleep 3
    
    # Get available networks
    nmcli device wifi list ifname "$device" --rescan no | \
    awk 'NR>1 && $1!="*" {
        # Extract SSID (handling spaces in SSID names)
        ssid = $2
        for(i=3; i<=NF-6; i++) ssid = ssid " " $i
        
        # Extract security info
        security = $(NF-3)
        if(security == "--") security = "Open"
        
        # Extract signal strength
        signal = $(NF-2)
        
        if(ssid != "" && ssid != "--") 
            printf "%s|%s|%s\n", ssid, security, signal
    }' | sort -t'|' -k3 -nr > "$WIFI_LIST"
    
    if [ ! -s "$WIFI_LIST" ]; then
        dialog --title "No Networks" \
               --msgbox "No WiFi networks found.\nTry moving closer to an access point." \
               6 50
        return 1
    fi
    
    return 0
}

# Select WiFi network
select_wifi_network() {
    > "$DEVICE_LIST"
    counter=1
    
    while IFS='|' read -r ssid security signal; do
        if [ -n "$ssid" ]; then
            echo "$counter" "$ssid ($security) - Signal: $signal%" >> "$DEVICE_LIST"
            counter=$((counter + 1))
        fi
    done < "$WIFI_LIST"
    
    dialog --title "Select WiFi Network" \
           --menu "Choose network to connect:" \
           20 70 12 \
           --file "$DEVICE_LIST" 2> "$INPUT_FILE"
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    choice=$(cat "$INPUT_FILE")
    selected_wifi=$(sed -n "${choice}p" "$WIFI_LIST" | cut -d'|' -f1)
    selected_security=$(sed -n "${choice}p" "$WIFI_LIST" | cut -d'|' -f2)
    
    return 0
}

# Get WiFi password
get_wifi_password() {
    if [ "$selected_security" = "Open" ]; then
        wifi_password=""
        return 0
    fi
    
    dialog --title "WiFi Password" \
           --passwordbox "Enter password for network: $selected_wifi" \
           8 60 2> "$INPUT_FILE"
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    wifi_password=$(cat "$INPUT_FILE")
    return 0
}

# Connect to WiFi
connect_wifi() {
    local device="$1"
    local ssid="$2"
    local password="$3"
    
    dialog --title "Connecting" \
           --infobox "Connecting to WiFi network: $ssid" \
           5 50
    
    if [ -z "$password" ]; then
        # Open network
        if nmcli device wifi connect "$ssid" ifname "$device" >/dev/null 2>&1; then
            dialog --title "Success" \
                   --msgbox "Successfully connected to WiFi network: $ssid" \
                   6 50
            return 0
        fi
    else
        # Secured network
        if nmcli device wifi connect "$ssid" password "$password" ifname "$device" >/dev/null 2>&1; then
            dialog --title "Success" \
                   --msgbox "Successfully connected to WiFi network: $ssid" \
                   6 50
            return 0
        fi
    fi
    
    dialog --title "Connection Failed" \
           --msgbox "Failed to connect to WiFi network: $ssid\n\nPlease check your password and try again." \
           8 60
    return 1
}

# Test internet connection
test_connection() {
    dialog --title "Testing Connection" \
           --infobox "Testing internet connectivity..." \
           5 40
    
    if ping -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
        # Get connection info
        active_connection=$(nmcli connection show --active | head -2 | tail -1)
        
        dialog --title "Connection Test" \
               --msgbox "Internet connection is working!\n\nActive connection:\n$active_connection" \
               10 60
        return 0
    else
        dialog --title "Connection Test" \
               --msgbox "Connected to network but no internet access.\nPlease check network configuration." \
               8 60
        return 1
    fi
}

# Show connection status
show_status() {
    local status_info
    status_info=$(nmcli connection show --active | head -10)
    
    if [ -z "$status_info" ]; then
        status_info="No active connections"
    fi
    
    dialog --title "Connection Status" \
           --msgbox "$status_info" \
           20 70
}

# Main menu
main_menu() {
    while true; do
        dialog --title "Network Connection Manager" \
               --backtitle "$BACKTITLE" \
               --menu "Select an option:" \
               $DIALOG_HEIGHT $DIALOG_WIDTH $DIALOG_MENU_HEIGHT \
               1 "Connect to Ethernet" \
               2 "Connect to WiFi" \
               3 "Show connection status" \
               4 "Exit" 2> "$INPUT_FILE"
        
        if [ $? -ne 0 ]; then
            break
        fi
        
        choice=$(cat "$INPUT_FILE")
        
        case $choice in
            1)
                get_network_devices
                if select_device "ethernet"; then
                    if connect_ethernet "$selected_device"; then
                        test_connection
                    fi
                fi
                ;;
            2)
                get_network_devices
                if select_device "wifi"; then
                    if scan_wifi_networks "$selected_device"; then
                        if select_wifi_network; then
                            if get_wifi_password; then
                                if connect_wifi "$selected_device" "$selected_wifi" "$wifi_password"; then
                                    test_connection
                                fi
                            fi
                        fi
                    fi
                fi
                ;;
            3)
                show_status
                ;;
            4)
                break
                ;;
        esac
    done
}

# Main execution
main() {
    check_dialog
    check_root
    check_requirements
    main_menu
    
    dialog --title "Goodbye" \
           --msgbox "Network configuration complete!" \
           6 40
}

# Run the script
main "$@"
