#!/bin/bash

# WireGuard UDP Port Forwarding Manager
# Manages multiple UDP port forwarding rules for WireGuard

set -e

CONFIG_DIR="/etc/wg-forward"
CONFIG_FILE="$CONFIG_DIR/forwards.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Verbose mode flag
VERBOSE=0

# Verbose logging function
log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   exit 1
fi

# Check and install iptables-persistent if needed
ensure_iptables_persistent() {
    log_verbose "Checking if iptables-persistent is installed"
    
    if command -v netfilter-persistent &> /dev/null; then
        log_verbose "iptables-persistent is already installed"
        return 0
    fi
    
    log_verbose "iptables-persistent not found, attempting to install"
    
    # Detect package manager
    if command -v apt-get &> /dev/null; then
        log_verbose "Detected apt-get package manager (Debian/Ubuntu)"
        echo -e "${YELLOW}Installing iptables-persistent...${NC}"
        
        # Pre-seed debconf to avoid interactive prompts
        log_verbose "Pre-configuring iptables-persistent to avoid prompts"
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        
        log_verbose "Running apt-get update"
        apt-get update -qq
        
        log_verbose "Installing iptables-persistent package"
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
        
        echo -e "${GREEN}iptables-persistent installed successfully${NC}"
        log_verbose "iptables-persistent installation completed"
        
    elif command -v yum &> /dev/null; then
        log_verbose "Detected yum package manager (RHEL/CentOS)"
        echo -e "${YELLOW}Installing iptables-services...${NC}"
        
        log_verbose "Installing iptables-services package"
        yum install -y iptables-services
        
        log_verbose "Enabling iptables service"
        systemctl enable iptables
        
        echo -e "${GREEN}iptables-services installed successfully${NC}"
        log_verbose "iptables-services installation completed"
        
    elif command -v dnf &> /dev/null; then
        log_verbose "Detected dnf package manager (Fedora)"
        echo -e "${YELLOW}Installing iptables-services...${NC}"
        
        log_verbose "Installing iptables-services package"
        dnf install -y iptables-services
        
        log_verbose "Enabling iptables service"
        systemctl enable iptables
        
        echo -e "${GREEN}iptables-services installed successfully${NC}"
        log_verbose "iptables-services installation completed"
        
    else
        echo -e "${YELLOW}Warning: Could not detect package manager${NC}"
        echo -e "${YELLOW}Please install iptables-persistent manually${NC}"
        log_verbose "Unknown package manager, manual installation required"
        return 1
    fi
    
    return 0
}

# Initialize config directory
init_config() {
    log_verbose "Initializing configuration directory: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    log_verbose "Configuration directory created/verified"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_verbose "Creating new configuration file: $CONFIG_FILE"
        echo "# WireGuard Port Forwarding Configuration" > "$CONFIG_FILE"
        echo "# Format: NAME|RELAY_PORT|DST_IP|DST_PORT" >> "$CONFIG_FILE"
        log_verbose "Configuration file created"
    else
        log_verbose "Configuration file already exists: $CONFIG_FILE"
    fi
}

# Enable IP forwarding
enable_ip_forward() {
    log_verbose "Checking IP forwarding status"
    local current_status=$(cat /proc/sys/net/ipv4/ip_forward)
    log_verbose "Current IP forwarding status: $current_status"
    
    if [[ $current_status -eq 0 ]]; then
        log_verbose "Enabling IP forwarding..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        log_verbose "Adding IP forwarding to sysctl.conf for persistence"
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo -e "${GREEN}IP forwarding enabled${NC}"
    else
        log_verbose "IP forwarding already enabled"
    fi
}

# Add a new forwarding rule
add_forward() {
    local name="$1"
    local relay_port="$2"
    local dst_ip="$3"
    local dst_port="$4"

    log_verbose "Starting add_forward operation"
    log_verbose "Parameters: name=$name, relay_port=$relay_port, dst_ip=$dst_ip, dst_port=$dst_port"

    if [[ -z "$name" || -z "$relay_port" || -z "$dst_ip" || -z "$dst_port" ]]; then
        echo -e "${RED}Error: Missing required parameters${NC}"
        echo "Usage: $0 add <name> <relay_port> <dst_ip> <dst_port>"
        exit 1
    fi

    # Check if name already exists
    log_verbose "Checking if forward name '$name' already exists"
    if grep -q "^$name|" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Forward '$name' already exists${NC}"
        exit 1
    fi
    log_verbose "Forward name is unique"

    # Check if port is already in use
    log_verbose "Checking if port $relay_port is already in use"
    if grep -q "|$relay_port|" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Port $relay_port is already in use${NC}"
        exit 1
    fi
    log_verbose "Port is available"

    # Add iptables rules
    log_verbose "Adding DNAT rule: PREROUTING udp --dport $relay_port -> $dst_ip:$dst_port"
    iptables -t nat -A PREROUTING -p udp --dport "$relay_port" -j DNAT --to-destination "$dst_ip:$dst_port"
    log_verbose "DNAT rule added successfully"
    
    log_verbose "Adding MASQUERADE rule: POSTROUTING udp -d $dst_ip --dport $dst_port"
    iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
    log_verbose "MASQUERADE rule added successfully"

    # Save to config
    log_verbose "Saving configuration to $CONFIG_FILE"
    echo "$name|$relay_port|$dst_ip|$dst_port" >> "$CONFIG_FILE"
    log_verbose "Configuration saved"

    # Make permanent
    log_verbose "Persisting iptables rules"
    save_rules

    echo -e "${GREEN}Forward '$name' added successfully${NC}"
    echo "  Relay Port: $relay_port → $dst_ip:$dst_port"
}

# Remove a forwarding rule
remove_forward() {
    local name="$1"

    log_verbose "Starting remove_forward operation for: $name"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Missing name parameter${NC}"
        echo "Usage: $0 remove <name>"
        exit 1
    fi

    # Get forward details
    log_verbose "Searching for forward '$name' in configuration"
    local line=$(grep "^$name|" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$line" ]]; then
        echo -e "${RED}Error: Forward '$name' not found${NC}"
        exit 1
    fi
    log_verbose "Forward found: $line"

    IFS='|' read -r _ relay_port dst_ip dst_port <<< "$line"
    log_verbose "Parsed values: relay_port=$relay_port, dst_ip=$dst_ip, dst_port=$dst_port"

    # Remove iptables rules
    log_verbose "Removing DNAT rule: PREROUTING udp --dport $relay_port"
    iptables -t nat -D PREROUTING -p udp --dport "$relay_port" -j DNAT --to-destination "$dst_ip:$dst_port" 2>/dev/null || true
    log_verbose "DNAT rule removed"
    
    log_verbose "Removing MASQUERADE rule: POSTROUTING udp -d $dst_ip --dport $dst_port"
    iptables -t nat -D POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE 2>/dev/null || true
    log_verbose "MASQUERADE rule removed"

    # Remove from config
    log_verbose "Removing entry from configuration file"
    sed -i "/^$name|/d" "$CONFIG_FILE"
    log_verbose "Configuration entry removed"

    # Make permanent
    log_verbose "Persisting iptables rules"
    save_rules

    echo -e "${GREEN}Forward '$name' removed successfully${NC}"
}

# Update a forwarding rule
update_forward() {
    local name="$1"
    local new_relay_port="$2"
    local new_dst_ip="$3"
    local new_dst_port="$4"

    log_verbose "Starting update_forward operation"
    log_verbose "Parameters: name=$name, new_relay_port=$new_relay_port, new_dst_ip=$new_dst_ip, new_dst_port=$new_dst_port"

    if [[ -z "$name" || -z "$new_relay_port" || -z "$new_dst_ip" || -z "$new_dst_port" ]]; then
        echo -e "${RED}Error: Missing required parameters${NC}"
        echo "Usage: $0 update <name> <relay_port> <dst_ip> <dst_port>"
        exit 1
    fi

    # Check if forward exists and get old values
    log_verbose "Verifying forward '$name' exists"
    local line=$(grep "^$name|" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$line" ]]; then
        echo -e "${RED}Error: Forward '$name' not found${NC}"
        exit 1
    fi
    log_verbose "Forward exists: $line"

    IFS='|' read -r _ old_relay_port old_dst_ip old_dst_port <<< "$line"
    log_verbose "Old values: relay_port=$old_relay_port, dst_ip=$old_dst_ip, dst_port=$old_dst_port"

    # Check if new port is already in use by another forward (not this one)
    if [[ "$new_relay_port" != "$old_relay_port" ]]; then
        log_verbose "Port is changing from $old_relay_port to $new_relay_port"
        log_verbose "Checking if new port $new_relay_port is already in use by another forward"
        
        # Check for port usage excluding the current forward name
        local port_check=$(grep "|$new_relay_port|" "$CONFIG_FILE" 2>/dev/null | grep -v "^$name|" || true)
        if [[ -n "$port_check" ]]; then
            echo -e "${RED}Error: Port $new_relay_port is already in use by another forward${NC}"
            exit 1
        fi
        log_verbose "New port is available"
    else
        log_verbose "Port remains unchanged: $new_relay_port"
    fi

    # Remove old iptables rules
    log_verbose "Removing old iptables rules"
    log_verbose "Removing DNAT rule: PREROUTING udp --dport $old_relay_port"
    iptables -t nat -D PREROUTING -p udp --dport "$old_relay_port" -j DNAT --to-destination "$old_dst_ip:$old_dst_port" 2>/dev/null || true
    log_verbose "Old DNAT rule removed"
    
    log_verbose "Removing MASQUERADE rule: POSTROUTING udp -d $old_dst_ip --dport $old_dst_port"
    iptables -t nat -D POSTROUTING -p udp -d "$old_dst_ip" --dport "$old_dst_port" -j MASQUERADE 2>/dev/null || true
    log_verbose "Old MASQUERADE rule removed"

    # Add new iptables rules
    log_verbose "Adding new iptables rules"
    log_verbose "Adding DNAT rule: PREROUTING udp --dport $new_relay_port -> $new_dst_ip:$new_dst_port"
    iptables -t nat -A PREROUTING -p udp --dport "$new_relay_port" -j DNAT --to-destination "$new_dst_ip:$new_dst_port"
    log_verbose "New DNAT rule added"
    
    log_verbose "Adding MASQUERADE rule: POSTROUTING udp -d $new_dst_ip --dport $new_dst_port"
    iptables -t nat -A POSTROUTING -p udp -d "$new_dst_ip" --dport "$new_dst_port" -j MASQUERADE
    log_verbose "New MASQUERADE rule added"

    # Update config file
    log_verbose "Updating configuration file"
    sed -i "s/^$name|.*/$name|$new_relay_port|$new_dst_ip|$new_dst_port/" "$CONFIG_FILE"
    log_verbose "Configuration file updated"

    # Make permanent
    log_verbose "Persisting iptables rules"
    save_rules

    echo -e "${GREEN}Forward '$name' updated successfully${NC}"
    echo "  Old: $old_relay_port → $old_dst_ip:$old_dst_port"
    echo "  New: $new_relay_port → $new_dst_ip:$new_dst_port"
}

# List all forwarding rules
list_forwards() {
    echo -e "${GREEN}Current Port Forwards:${NC}"
    echo "----------------------------------------"
    
    if [[ ! -s "$CONFIG_FILE" ]] || ! grep -q "^[^#]" "$CONFIG_FILE"; then
        echo "No forwards configured"
        return
    fi

    printf "%-20s %-15s %-25s\n" "NAME" "RELAY PORT" "DESTINATION"
    printf "%-20s %-15s %-25s\n" "----" "----------" "-----------"
    
    while IFS='|' read -r name relay_port dst_ip dst_port; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        printf "%-20s %-15s %-25s\n" "$name" "$relay_port" "$dst_ip:$dst_port"
    done < "$CONFIG_FILE"
}

# Export configuration
export_config() {
    local export_file="$1"
    
    log_verbose "Starting export_config operation"
    log_verbose "Export destination: $export_file"

    if [[ -z "$export_file" ]]; then
        echo -e "${RED}Error: Missing export file parameter${NC}"
        echo "Usage: $0 export <file>"
        exit 1
    fi

    log_verbose "Copying configuration from $CONFIG_FILE to $export_file"
    cp "$CONFIG_FILE" "$export_file"
    log_verbose "Configuration copied successfully"
    
    echo -e "${GREEN}Configuration exported to: $export_file${NC}"
}

# Import configuration
import_config() {
    local import_file="$1"
    
    log_verbose "Starting import_config operation"
    log_verbose "Import source: $import_file"

    if [[ -z "$import_file" ]]; then
        echo -e "${RED}Error: Missing import file parameter${NC}"
        echo "Usage: $0 import <file>"
        exit 1
    fi

    if [[ ! -f "$import_file" ]]; then
        echo -e "${RED}Error: File not found: $import_file${NC}"
        exit 1
    fi
    log_verbose "Import file found and accessible"

    # Clear existing rules
    echo -e "${YELLOW}Clearing existing forwards...${NC}"
    log_verbose "Reading existing configuration from $CONFIG_FILE"
    while IFS='|' read -r name _ _ _; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        log_verbose "Removing existing forward: $name"
        remove_forward "$name" 2>/dev/null || true
    done < "$CONFIG_FILE"
    log_verbose "All existing forwards cleared"

    # Import new configuration
    log_verbose "Copying import file to $CONFIG_FILE"
    cp "$import_file" "$CONFIG_FILE"
    log_verbose "Configuration file replaced"

    # Apply all rules
    echo -e "${YELLOW}Applying imported configuration...${NC}"
    log_verbose "Reading and applying rules from imported configuration"
    while IFS='|' read -r name relay_port dst_ip dst_port; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        echo "Adding: $name"
        log_verbose "Applying rule: $name ($relay_port -> $dst_ip:$dst_port)"
        log_verbose "Adding DNAT rule for $name"
        iptables -t nat -A PREROUTING -p udp --dport "$relay_port" -j DNAT --to-destination "$dst_ip:$dst_port"
        log_verbose "Adding MASQUERADE rule for $name"
        iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
        log_verbose "Rules applied for $name"
    done < "$CONFIG_FILE"

    log_verbose "Persisting iptables rules"
    save_rules
    echo -e "${GREEN}Configuration imported successfully${NC}"
}

# Reload all rules from config
reload_forwards() {
    echo -e "${YELLOW}Reloading all forwards...${NC}"
    log_verbose "Starting reload_forwards operation"
    
    # Clear all NAT rules (be careful!)
    log_verbose "Flushing PREROUTING chain in NAT table"
    iptables -t nat -F PREROUTING
    log_verbose "Flushing POSTROUTING chain in NAT table"
    iptables -t nat -F POSTROUTING
    log_verbose "NAT chains flushed"

    # Reapply all rules
    log_verbose "Reading configuration from $CONFIG_FILE"
    while IFS='|' read -r name relay_port dst_ip dst_port; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        echo "Loading: $name"
        log_verbose "Reloading forward: $name ($relay_port -> $dst_ip:$dst_port)"
        log_verbose "Adding DNAT rule for $name"
        iptables -t nat -A PREROUTING -p udp --dport "$relay_port" -j DNAT --to-destination "$dst_ip:$dst_port"
        log_verbose "Adding MASQUERADE rule for $name"
        iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
        log_verbose "Rules reloaded for $name"
    done < "$CONFIG_FILE"

    log_verbose "Persisting iptables rules"
    save_rules
    echo -e "${GREEN}All forwards reloaded${NC}"
}

# Clean/fix duplicate rules and sync with config
clean_rules() {
    echo -e "${YELLOW}Cleaning and syncing iptables rules with configuration...${NC}"
    log_verbose "Starting clean_rules operation"
    
    # Flush all NAT rules
    log_verbose "Flushing all NAT rules"
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    echo "All NAT rules cleared"
    
    # Reapply rules from config
    log_verbose "Reapplying rules from configuration"
    local count=0
    while IFS='|' read -r name relay_port dst_ip dst_port; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        echo "Restoring: $name ($relay_port -> $dst_ip:$dst_port)"
        log_verbose "Adding DNAT rule for $name"
        iptables -t nat -A PREROUTING -p udp --dport "$relay_port" -j DNAT --to-destination "$dst_ip:$dst_port"
        log_verbose "Adding MASQUERADE rule for $name"
        iptables -t nat -A POSTROUTING -p udp -d "$dst_ip" --dport "$dst_port" -j MASQUERADE
        ((count++))
    done < "$CONFIG_FILE"
    
    log_verbose "Persisting iptables rules"
    save_rules
    
    echo -e "${GREEN}Clean completed: $count forward(s) restored${NC}"
    echo "All duplicate rules removed and synced with configuration"
}

# Save iptables rules
save_rules() {
    log_verbose "Attempting to persist iptables rules"
    if command -v netfilter-persistent &> /dev/null; then
        log_verbose "Using netfilter-persistent to save rules"
        netfilter-persistent save
        log_verbose "Rules saved with netfilter-persistent"
    elif command -v iptables-save &> /dev/null; then
        log_verbose "Using iptables-save to save rules to /etc/iptables/rules.v4"
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        log_verbose "Rules saved with iptables-save"
    else
        log_verbose "Warning: No persistence method found (netfilter-persistent or iptables-save)"
    fi
}

# Show usage
usage() {
    cat << EOF
WireGuard UDP Port Forwarding Manager

Usage: $0 [--verbose] <command> [arguments]

Options:
    --verbose, -v       Show detailed operation steps

Commands:
    add <name> <relay_port> <dst_ip> <dst_port>
        Add a new port forwarding rule
        Example: $0 add server1 51821 185.229.64.239 51820

    remove <name>
        Remove a forwarding rule
        Example: $0 remove server1

    update <name> <relay_port> <dst_ip> <dst_port>
        Update an existing forwarding rule
        Example: $0 update server1 51822 185.229.64.239 51820

    list
        List all configured forwarding rules

    export <file>
        Export configuration to a file
        Example: $0 export /tmp/forwards.conf

    import <file>
        Import configuration from a file (replaces current config)
        Example: $0 import /tmp/forwards.conf

    reload
        Reload all forwarding rules from configuration

    clean
        Clean all NAT rules and sync with configuration
        (Useful for removing duplicates or fixing inconsistencies)

    help
        Show this help message

Examples with verbose mode:
    $0 --verbose add server1 51821 185.229.64.239 51820
    $0 -v list
    $0 --verbose reload

EOF
}

# Main script logic
ensure_iptables_persistent
init_config
enable_ip_forward

# Parse verbose flag
if [[ "$1" == "--verbose" || "$1" == "-v" ]]; then
    VERBOSE=1
    log_verbose "Verbose mode enabled"
    shift
fi

log_verbose "Command: ${1:-none}"
log_verbose "Script started at $(date)"

case "${1:-}" in
    add)
        log_verbose "Executing add command"
        add_forward "$2" "$3" "$4" "$5"
        ;;
    remove)
        log_verbose "Executing remove command"
        remove_forward "$2"
        ;;
    update)
        log_verbose "Executing update command"
        update_forward "$2" "$3" "$4" "$5"
        ;;
    list)
        log_verbose "Executing list command"
        list_forwards
        ;;
    export)
        log_verbose "Executing export command"
        export_config "$2"
        ;;
    import)
        log_verbose "Executing import command"
        import_config "$2"
        ;;
    reload)
        log_verbose "Executing reload command"
        reload_forwards
        ;;
    clean)
        log_verbose "Executing clean command"
        clean_rules
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo -e "${RED}Error: Invalid command${NC}\n"
        usage
        exit 1
        ;;
esac

log_verbose "Script completed at $(date)"
