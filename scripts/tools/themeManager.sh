#!/bin/bash

#############################################
# Theme Manager - Unified Color & Font Tool
#############################################

show_help() {
    cat << EOF
Theme Manager - Apply colors and fonts separately

Usage:
  theme-manager colors <theme-file>     Apply color theme
  theme-manager font <font-name> [size] Apply font
  theme-manager both <theme> <font>     Apply both
  theme-manager list-colors             List available color themes
  theme-manager list-fonts              List popular fonts
  theme-manager help                    Show this help

Examples:
  theme-manager colors dracula
  theme-manager font FiraCode 12
  theme-manager both monokai-pro JetBrainsMono
EOF
}

THEMES_DIR="$HOME/.config/themes"

case "$1" in
    colors)
        if [ -z "$2" ]; then
            echo "Error: Theme name required"
            echo "Available themes:"
            ls -1 "$THEMES_DIR"/*.colortheme 2>/dev/null | xargs -n1 basename -s .colortheme
            exit 1
        fi
        
        THEME_FILE="$THEMES_DIR/${2}.colortheme"
        if [ ! -f "$THEME_FILE" ]; then
            THEME_FILE="$2"
        fi
        
        apply-colors "$THEME_FILE"
        ;;
    
    font)
        if [ -z "$2" ]; then
            echo "Error: Font name required"
            apply-font
            exit 1
        fi
        
        apply-font "$2" "${3:-11}"
        ;;
    
    both)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Error: Both theme and font required"
            echo "Usage: theme-manager both <theme> <font> [size]"
            exit 1
        fi
        
        THEME_FILE="$THEMES_DIR/${2}.colortheme"
        if [ ! -f "$THEME_FILE" ]; then
            THEME_FILE="$2"
        fi
        
        apply-colors "$THEME_FILE"
        apply-font "$3" "${4:-11}"
        ;;
    
    list-colors)
        echo "Available color themes:"
        ls -1 "$THEMES_DIR"/*.colortheme 2>/dev/null | xargs -n1 basename -s .colortheme
        ;;
    
    list-fonts)
        echo "Popular monospace fonts:"
        echo "  - FiraCode"
        echo "  - JetBrainsMono"
        echo "  - CascadiaCode"
        echo "  - Hack"
        echo "  - SourceCodePro"
        echo ""
        echo "Installed monospace fonts:"
        fc-list : family | grep -i mono | sort -u | head -20
        ;;
    
    help|--help|-h|"")
        show_help
        ;;
    
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac