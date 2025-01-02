#!/usr/bin/env bash
#
# validate_numa_and_routes.sh
#
# This script validates which NUMA node each PCI-based NIC is located on and
# verifies that routes defined in /etc/sysconfig/network-scripts/route-<iface>
# are reachable via their respective NICs.

# Exit on error
set -euo pipefail

#######################################
# HELPER FUNCTIONS
#######################################

# Print an error message and exit
error_exit() {
    echo "[ERROR] $*" 1>&2
    exit 1
}

# Check if the script is run as root (required for some commands)
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root."
fi

#######################################
# 1. ENUMERATE NETWORK INTERFACES -> PCI -> NUMA
#######################################
# We will gather info from:
#   /sys/class/net/<iface>/device -> PCI device
#   /sys/bus/pci/devices/<pci-id>/numa_node -> NUMA node
#   lspci -v or lspci -nnk for device details

echo "Gathering NIC and PCI/NUMA information..."

declare -A IFACE_TO_PCI  # associative array: iface -> PCI address
declare -A PCI_TO_NUMA   # associative array: PCI address -> NUMA node

for iface in $(ls /sys/class/net); do
    # We skip the 'lo' interface
    if [[ "$iface" == "lo" ]]; then
        continue
    fi
    
    pci_path=$(readlink -f /sys/class/net/"$iface"/device || true)
    if [[ -z "$pci_path" ]]; then
        echo "Could not get PCI path for interface $iface, skipping..."
        continue
    fi
    
    # The last component of the path is the PCI bus ID, e.g., '0000:81:00.0'
    pci_id=$(basename "$pci_path")
    
    # Record in the IFACE_TO_PCI map
    IFACE_TO_PCI[$iface]="$pci_id"
    
    # Get NUMA node info from /sys/bus/pci/devices/<pci-id>/numa_node
    numa_node_file="/sys/bus/pci/devices/$pci_id/numa_node"
    if [[ -f "$numa_node_file" ]]; then
        numa_node=$(cat "$numa_node_file")
    else
        numa_node="N/A"
    fi
    
    PCI_TO_NUMA[$pci_id]="$numa_node"
done

echo "NIC -> PCI -> NUMA Summary:"
for nic in "${!IFACE_TO_PCI[@]}"; do
    pci_id="${IFACE_TO_PCI[$nic]}"
    numa_node="${PCI_TO_NUMA[$pci_id]}"
    echo "  * Interface: $nic"
    echo "       PCI ID: $pci_id"
    echo "    NUMA Node: $numa_node"
done
echo

#######################################
# 2. PARSE ROUTE FILES FOR EACH IFACE
#######################################
# Typically in RHEL/CentOS, route files are named /etc/sysconfig/network-scripts/route-<iface>
# Each line typically has the format:
#   <destination> via <gateway> dev <iface> [options]
# or
#   <destination> <gateway>
#   e.g. 192.168.10.0/24 via 192.168.10.1 dev eth0
# or   192.168.20.0/24 via 192.168.20.1

echo "Checking static route files for each interface..."

ROUTE_DIR="/etc/sysconfig/network-scripts"
declare -A IFACE_ROUTES # associative array: iface -> array of destinations

for nic in "${!IFACE_TO_PCI[@]}"; do
    route_file="${ROUTE_DIR}/route-${nic}"
    if [[ -f "$route_file" ]]; then
        echo "  Found route file $route_file for NIC $nic"
        
        # We will parse each line for destination (CIDR or IP)
        # If a line starts with # or is empty, skip it
        # Otherwise, extract the first field as destination
        while read -r line; do
            # Skip comments and empty lines
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            
            # Attempt to parse out the destination - handle different formats
            # Format: "192.168.10.0/24 via 192.168.10.1 dev eth0"
            dest=$(echo "$line" | awk '{print $1}')
            
            # Store the destination in an array
            IFACE_ROUTES["$nic"]+="$dest "
        done < "$route_file"
    else
        echo "  No route file for $nic, skipping route checks for this interface."
    fi
done
echo

#######################################
# 3. VALIDATE REACHABILITY OF ROUTE DESTINATIONS
#######################################
# For each interface's routes, we do a quick connectivity test.
# Typically, you might test with "ip route get <destination>" or a simple ping.

echo "Validating route reachability..."

for nic in "${!IFACE_ROUTES[@]}"; do
    echo "Interface: $nic"
    destinations=(${IFACE_ROUTES[$nic]})
    
    # Bring up the interface if not already up (optional)
    # ip link set dev "$nic" up
    
    for dest in "${destinations[@]}"; do
        # We'll do a single ping attempt to confirm route
        # (You might prefer 'ip route get' or multiple pings, etc.)
        echo "  Testing reachability to $dest via $nic..."
        
        # Ping only once with a short timeout
        # Using ping -c 1 -I <nic> ensures we source from the correct interface
        if ping -c 1 -W 2 -I "$nic" "$dest" &>/dev/null; then
            echo "    [OK] $dest is reachable via $nic"
        else
            echo "    [FAIL] $dest is NOT reachable via $nic"
        fi
    done
    echo
done

echo "Validation complete."

