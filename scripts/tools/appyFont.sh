#!/bin/bash

#############################################
# Universal Wayland Font Applicator
# Sets consistent font across applications
#############################################

set -e

FONT_NAME="$1"
FONT_SIZE="${2:-11}"
CONFIG_DIR="$HOME/.config"
BACKUP_DIR="$CONFIG_DIR/font-backups/$(date +%Y%m%d-%H%M%S)"
MAX_BACKUPS=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Popular monospace fonts
POPULAR_FONTS=(
    "FiraCode"
    "JetBrainsMono"
    "CascadiaCode"
    "Hack"
    "SourceCodePro"
    "UbuntuMono"
    "DejaVuSansMono"
    "RobotoMono"
    "IBMPlexMono"
    "Inconsolata"
    "Monospace"
)

# Show usage
show_usage() {
    echo "Usage: $0 <font-name> [font-size]"
    echo ""
    echo "Examples:"
    echo "  $0 FiraCode 11"
    echo "  $0 JetBrainsMono 12"
    echo "  $0 Hack"
    echo ""
    echo "Popular monospace fonts:"
    for font in "${POPULAR_FONTS[@]}"; do
        echo "  - $font"
    done
    echo ""
    echo "Installed fonts:"
    fc-list : family | grep -i mono | sort -u | head -20
}

# Validate input
if [ -z "$FONT_NAME" ]; then
    log_error "Font name required"
    echo ""
    show_usage
    exit 1
fi

# Check if font exists
if ! fc-list | grep -qi "$FONT_NAME"; then
    log_warn "Font '$FONT_NAME' may not be installed"
    log_warn "Install with: sudo xbps-install -S font-$FONT_NAME (on Void Linux)"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

log_info "Applying font: $FONT_NAME (size: $FONT_SIZE)"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Cleanup old backups
cleanup_backups() {
    local backup_root="$CONFIG_DIR/font-backups"
    local backup_count=$(ls -1d "$backup_root"/*/ 2>/dev/null | wc -l)
    
    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        log_debug "Cleaning old backups (keeping last $MAX_BACKUPS)..."
        ls -1td "$backup_root"/*/ | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -rf
    fi
}

# Safe backup function
backup_file() {
    local file="$1"
    local name="$2"
    
    if [ -f "$file" ]; then
        cp "$file" "$BACKUP_DIR/$name"
        log_debug "Backed up: $name"
    fi
}

# Replace or add line
replace_or_add() {
    local file="$1"
    local pattern="$2"
    local replacement="$3"
    
    if [ ! -f "$file" ]; then
        echo "$replacement" > "$file"
        return
    fi
    
    if grep -q "^${pattern%%=*}" "$file"; then
        sed -i "s|^${pattern%%=*}.*|$replacement|" "$file"
    else
        echo "$replacement" >> "$file"
    fi
}

#############################################
# Application-specific font functions
#############################################

apply_foot_font() {
    log_info "Applying font to foot..."
    
    local foot_config="$CONFIG_DIR/foot/foot.ini"
    
    mkdir -p "$CONFIG_DIR/foot"
    backup_file "$foot_config" "foot.ini"
    
    if [ ! -f "$foot_config" ]; then
        cat > "$foot_config" << EOF
[main]
font=${FONT_NAME}:size=${FONT_SIZE}
EOF
    else
        replace_or_add "$foot_config" "font=" "font=${FONT_NAME}:size=${FONT_SIZE}"
    fi
    
    log_info "✓ foot"
}

apply_btop_font() {
    log_info "✓ btop (uses terminal font)"
}

apply_alacritty_font() {
    local alacritty_config="$CONFIG_DIR/alacritty/alacritty.yml"
    
    if [ -f "$alacritty_config" ]; then
        log_info "Applying font to alacritty..."
        backup_file "$alacritty_config" "alacritty.yml"
        
        # Update or add font configuration
        if grep -q "^font:" "$alacritty_config"; then
            sed -i "/^font:/,/^[^ ]/ s/family:.*/family: $FONT_NAME/" "$alacritty_config"
            sed -i "/^font:/,/^[^ ]/ s/size:.*/size: $FONT_SIZE/" "$alacritty_config"
        else
            cat >> "$alacritty_config" << EOF

font:
  normal:
    family: $FONT_NAME
  size: $FONT_SIZE
EOF
        fi
        log_info "✓ alacritty"
    fi
}

apply_kitty_font() {
    local kitty_config="$CONFIG_DIR/kitty/kitty.conf"
    
    if [ -f "$kitty_config" ]; then
        log_info "Applying font to kitty..."
        backup_file "$kitty_config" "kitty.conf"
        
        replace_or_add "$kitty_config" "font_family" "font_family $FONT_NAME"
        replace_or_add "$kitty_config" "font_size" "font_size $FONT_SIZE"
        
        log_info "✓ kitty"
    fi
}

apply_wezterm_font() {
    local wezterm_config="$CONFIG_DIR/wezterm/wezterm.lua"
    
    if [ -f "$wezterm_config" ]; then
        log_info "Applying font to wezterm..."
        backup_file "$wezterm_config" "wezterm.lua"
        
        # This is basic; manual editing may be needed for WezTerm
        log_warn "WezTerm font config may need manual adjustment"
        log_info "Add to wezterm.lua: config.font = wezterm.font('$FONT_NAME')"
        log_info "Add to wezterm.lua: config.font_size = $FONT_SIZE"
    fi
}

apply_neovim_font() {
    log_info "✓ neovim (uses terminal font)"
}

apply_gtk_font() {
    log_info "Setting GTK terminal font..."
    
    local gtk3_config="$CONFIG_DIR/gtk-3.0/settings.ini"
    
    mkdir -p "$CONFIG_DIR/gtk-3.0"
    backup_file "$gtk3_config" "gtk-settings.ini"
    
    if [ ! -f "$gtk3_config" ]; then
        cat > "$gtk3_config" << EOF
[Settings]
gtk-font-name=$FONT_NAME $FONT_SIZE
EOF
    else
        if grep -q "gtk-font-name" "$gtk3_config"; then
            sed -i "s/gtk-font-name=.*/gtk-font-name=$FONT_NAME $FONT_SIZE/" "$gtk3_config"
        else
            echo "gtk-font-name=$FONT_NAME $FONT_SIZE" >> "$gtk3_config"
        fi
    fi
    
    log_info "✓ GTK"
}

apply_fontconfig() {
    log_info "Setting fontconfig preferences..."
    
    local fontconfig="$CONFIG_DIR/fontconfig/fonts.conf"
    
    mkdir -p "$CONFIG_DIR/fontconfig"
    backup_file "$fontconfig" "fonts.conf"
    
    cat > "$fontconfig" << EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- Auto-generated by apply-font -->
  <!-- Generated: $(date) -->
  
  <!-- Default monospace font -->
  <match target="pattern">
    <test qual="any" name="family">
      <string>monospace</string>
    </test>
    <edit name="family" mode="prepend" binding="strong">
      <string>$FONT_NAME</string>
    </edit>
  </match>
  
  <!-- Terminal-specific -->
  <match target="pattern">
    <test qual="any" name="family">
      <string>terminal</string>
    </test>
    <edit name="family" mode="prepend" binding="strong">
      <string>$FONT_NAME</string>
    </edit>
  </match>
</fontconfig>
EOF

    # Update font cache
    fc-cache -f 2>/dev/null && log_debug "Font cache updated"
    
    log_info "✓ fontconfig"
}

#############################################
# Main execution
#############################################

log_info "Applying font configuration..."
echo ""

apply_foot_font
apply_btop_font
apply_alacritty_font
apply_kitty_font
apply_wezterm_font
apply_neovim_font
apply_gtk_font
apply_fontconfig

cleanup_backups

echo ""
log_info "✓ Font applied: $FONT_NAME (size: $FONT_SIZE)"
log_info "Backups: $BACKUP_DIR"
echo ""
log_info "Restart applications to see changes:"
echo "  - foot: Open new terminal"
echo "  - Other terminals: Restart them"
echo "  - GTK apps: May need session restart"