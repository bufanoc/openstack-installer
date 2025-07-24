#!/bin/bash

#############################################################
# Final OpenStack All-in-One Installation Script for Ubuntu 24.04 LTS
# OpenStack Release: 2024.2 (Dalmatian)
# 
# This script incorporates all fixes and lessons learned
# Components: Keystone, Glance, Placement, Nova, Neutron, 
#             Horizon, Cinder
#
# Requirements:
# - Ubuntu 24.04 LTS (fresh installation)
# - Minimum 8GB RAM (16GB recommended)
# - Minimum 50GB disk space
# - 2 Network interfaces:
#   - Management interface with static IP
#   - Provider interface with NO IP configured
#
# Author: Carmine Bufano
# Date: November 2024
#############################################################

set -e

# Set non-interactive mode to avoid debconf warnings
export DEBIAN_FRONTEND=noninteractive

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Configuration variables
CONTROLLER_IP=""
PROVIDER_INTERFACE=""
ADMIN_PASS="Admin123!"
DEMO_PASS="Demo123!"
DB_PASS="DBPass123!"
RABBIT_PASS="Rabbit123!"
SERVICE_PASS="Service123!"
METADATA_SECRET=$(openssl rand -hex 10)

# State file to track installation progress
STATE_FILE="/root/.openstack_install_state"
CONFIG_FILE="/root/.openstack_config"

# Initialize state file if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
    touch "$STATE_FILE"
fi

# Function to check if a step has been completed
is_completed() {
    grep -q "^$1$" "$STATE_FILE" 2>/dev/null
}

# Function to mark a step as completed
mark_completed() {
    if ! is_completed "$1"; then
        echo "$1" >> "$STATE_FILE"
    fi
}

# Pre-flight checks
pre_flight_checks() {
    log "Running pre-flight checks..."
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu 24.04" /etc/os-release; then
        warning "This script is designed for Ubuntu 24.04 LTS"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check available memory
    TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 8 ]; then
        warning "System has less than 8GB RAM. OpenStack may not run properly."
    fi
    
    # Check disk space
    AVAILABLE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$AVAILABLE_SPACE" -lt 50 ]; then
        warning "Less than 50GB disk space available. This might not be enough."
    fi
    
    info "Pre-flight checks completed"
}

# Function to get user input
get_config() {
    if is_completed "config_saved"; then
        log "Loading saved configuration..."
        source "$CONFIG_FILE"
        return
    fi
    
    echo "=== OpenStack All-in-One Configuration ==="
    echo ""
    info "Network Requirements:"
    echo "1. Management interface: Should have a static IP configured"
    echo "2. Provider interface: Should have NO IP address configured"
    echo ""
    
    # Show current network configuration
    echo "Current network interfaces:"
    ip -br addr show | grep -v lo
    echo ""
    
    # Get management IP
    while true; do
        read -p "Enter the management IP address (e.g., 10.0.0.11): " CONTROLLER_IP
        if [[ $CONTROLLER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # Verify the IP exists on the system
            if ip addr show | grep -q "$CONTROLLER_IP"; then
                break
            else
                error "IP address $CONTROLLER_IP not found on any interface"
            fi
        else
            error "Invalid IP address format"
        fi
    done
    
    # Get provider interface
    echo ""
    echo "Available network interfaces:"
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
    echo ""
    
    while true; do
        read -p "Enter the provider network interface name (e.g., eth1, ens34): " PROVIDER_INTERFACE
        if ip link show "$PROVIDER_INTERFACE" >/dev/null 2>&1; then
            # Check if interface has an IP
            if ip addr show "$PROVIDER_INTERFACE" | grep -q "inet "; then
                warning "Interface $PROVIDER_INTERFACE has an IP address configured."
                echo "The provider interface should NOT have an IP address."
                read -p "Continue anyway? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            error "Interface $PROVIDER_INTERFACE not found"
        fi
    done
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
CONTROLLER_IP="$CONTROLLER_IP"
PROVIDER_INTERFACE="$PROVIDER_INTERFACE"
ADMIN_PASS="$ADMIN_PASS"
DEMO_PASS="$DEMO_PASS"
DB_PASS="$DB_PASS"
RABBIT_PASS="$RABBIT_PASS"
SERVICE_PASS="$SERVICE_PASS"
METADATA_SECRET="$METADATA_SECRET"
EOF
    
    chmod 600 "$CONFIG_FILE"
    mark_completed "config_saved"
    
    # Confirm settings
    echo ""
    echo "=== Configuration Summary ==="
    echo "Management IP: $CONTROLLER_IP"
    echo "Provider Interface: $PROVIDER_INTERFACE"
    echo "Admin Password: $ADMIN_PASS"
    echo "============================"
    echo ""
    
    read -p "Continue with these settings? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        rm -f "$STATE_FILE"
        exit 1
    fi
}

# Update system
update_system() {
    if is_completed "system_updated"; then
        log "System already updated, skipping..."
        return
    fi
    
    log "Updating system packages..."
    apt update
    apt upgrade -y
    apt dist-upgrade -y
    
    mark_completed "system_updated"
}

# Install basic utilities
install_utilities() {
    if is_completed "utilities_installed"; then
        log "Utilities already installed, skipping..."
        return
    fi
    
    log "Installing basic utilities..."
    apt install -y software-properties-common curl wget git vim htop net-tools lsof
    apt install -y python3-pip python3-dev build-essential
    apt install -y crudini jq
    
    mark_completed "utilities_installed"
}

# MySQL command wrapper with error handling
mysql_cmd() {
    if mysql -u root -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
        mysql -u root -p"$DB_PASS" -e "$1" 2>/dev/null || true
    else
        mysql -e "$1" 2>/dev/null || true
    fi
}

# Configure networking
configure_networking() {
    if is_completed "networking_configured"; then
        log "Networking already configured, skipping..."
        return
    fi
    
    log "Configuring networking..."
    
    # Set hostname
    hostnamectl set-hostname controller
    
    # Configure /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1   localhost
$CONTROLLER_IP   controller

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # IMPORTANT: Do NOT modify network configuration here
    # The provider interface should already be configured by the user
    info "Using existing network configuration"
    info "Management interface IP: $CONTROLLER_IP"
    info "Provider interface: $PROVIDER_INTERFACE (should have no IP)"
    
    mark_completed "networking_configured"
}

# Install and configure NTP
configure_ntp() {
    if is_completed "ntp_configured"; then
        log "NTP already configured, skipping..."
        return
    fi
    
    log "Installing and configuring NTP (chrony)..."
    apt install -y chrony
    
    # Configure chrony
    cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup
    
    # Use Google's time servers
    sed -i '/^pool/d' /etc/chrony/chrony.conf
    sed -i '/^server/d' /etc/chrony/chrony.conf
    
    cat >> /etc/chrony/chrony.conf << EOF

# Google Public NTP
server time.google.com iburst
server time2.google.com iburst
server time3.google.com iburst
server time4.google.com iburst

# Allow NTP client access from local network
allow 10.0.0.0/8
allow 192.168.0.0/16
allow 172.16.0.0/12
EOF
    
    systemctl restart chrony
    systemctl enable chrony
    
    # Wait for time sync
    sleep 5
    chronyc sources
    
    mark_completed "ntp_configured"
}

# Install and configure MariaDB
configure_mariadb() {
    if is_completed "mariadb_configured"; then
        log "MariaDB already configured, skipping..."
        return
    fi
    
    log "Installing and configuring MariaDB..."
    apt install -y mariadb-server python3-pymysql
    
    # Create OpenStack database configuration
    cat > /etc/mysql/mariadb.conf.d/99-openstack.cnf << EOF
[mysqld]
bind-address = $CONTROLLER_IP
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

    systemctl restart mysql
    
    # Secure MariaDB installation
    if ! mysql -u root -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';"
    fi
    
    mysql_cmd "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql_cmd "DELETE FROM mysql.user WHERE User='';"
    mysql_cmd "DROP DATABASE IF EXISTS test;"
    mysql_cmd "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    mark_completed "mariadb_configured"
}

# Install and configure RabbitMQ
configure_rabbitmq() {
    if is_completed "rabbitmq_configured"; then
        log "RabbitMQ already configured, skipping..."
        return
    fi
    
    log "Installing and configuring RabbitMQ..."
    apt install -y rabbitmq-server
    
    systemctl enable rabbitmq-server
    systemctl start rabbitmq-server
    
    # Check if user already exists
    if ! rabbitmqctl list_users | grep -q openstack; then
        rabbitmqctl add_user openstack "$RABBIT_PASS"
        rabbitmqctl set_permissions openstack ".*" ".*" ".*"
    fi
    
    mark_completed "rabbitmq_configured"
}

# Install and configure Memcached
configure_memcached() {
    if is_completed "memcached_configured"; then
        log "Memcached already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Memcached..."
    apt install -y memcached python3-memcache
    
    # Configure memcached to listen on controller IP
    cp /etc/memcached.conf /etc/memcached.conf.backup
    sed -i "s/^-l.*/-l 127.0.0.1,$CONTROLLER_IP/g" /etc/memcached.conf
    
    systemctl restart memcached
    systemctl enable memcached
    
    mark_completed "memcached_configured"
}

# Install and configure Etcd
configure_etcd() {
    if is_completed "etcd_configured"; then
        log "Etcd already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Etcd..."
    apt install -y etcd-server etcd-client
    
    cat > /etc/default/etcd << EOF
ETCD_NAME="controller"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"
ETCD_INITIAL_CLUSTER="controller=http://$CONTROLLER_IP:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$CONTROLLER_IP:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://$CONTROLLER_IP:2379"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://$CONTROLLER_IP:2379,http://127.0.0.1:2379"
EOF

    systemctl enable etcd
    systemctl restart etcd
    
    mark_completed "etcd_configured"
}

# Enable OpenStack repository
enable_openstack_repo() {
    if is_completed "openstack_repo_enabled"; then
        log "OpenStack repository already enabled, skipping..."
        return
    fi
    
    log "Enabling OpenStack repository..."
    add-apt-repository -y cloud-archive:dalmatian
    apt update
    
    mark_completed "openstack_repo_enabled"
}

# Install OpenStack client
install_openstack_client() {
    if is_completed "openstack_client_installed"; then
        log "OpenStack client already installed, skipping..."
        return
    fi
    
    log "Installing OpenStack client..."
    apt install -y python3-openstackclient
    
    mark_completed "openstack_client_installed"
}

# Install and configure Keystone
configure_keystone() {
    if is_completed "keystone_configured"; then
        log "Keystone already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Keystone (Identity service)..."
    
    # Create database
    mysql_cmd "CREATE DATABASE IF NOT EXISTS keystone;"
    mysql_cmd "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Install packages
    apt install -y keystone apache2 libapache2-mod-wsgi-py3
    
    # Configure Keystone
    cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.backup
    
    crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:$SERVICE_PASS@controller/keystone"
    crudini --set /etc/keystone/keystone.conf token provider fernet
    
    # Populate database
    su -s /bin/sh -c "keystone-manage db_sync" keystone
    
    # Initialize Fernet key repositories
    keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
    keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
    
    # Bootstrap the Identity service
    keystone-manage bootstrap --bootstrap-password "$ADMIN_PASS" \
      --bootstrap-admin-url "http://controller:5000/v3/" \
      --bootstrap-internal-url "http://controller:5000/v3/" \
      --bootstrap-public-url "http://controller:5000/v3/" \
      --bootstrap-region-id RegionOne
    
    # Configure Apache
    if ! grep -q "ServerName controller" /etc/apache2/apache2.conf; then
        echo "ServerName controller" >> /etc/apache2/apache2.conf
    fi
    
    systemctl restart apache2
    systemctl enable apache2
    
    mark_completed "keystone_configured"
}

# Create OpenStack environment scripts
create_env_scripts() {
    if is_completed "env_scripts_created"; then
        log "Environment scripts already created, skipping..."
        return
    fi
    
    log "Creating environment scripts..."
    
    # Admin credentials
    cat > /root/admin-openrc << EOF
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

    # Demo credentials
    cat > /root/demo-openrc << EOF
export OS_USERNAME=demo
export OS_PASSWORD=$DEMO_PASS
export OS_PROJECT_NAME=myproject
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

    chmod 600 /root/admin-openrc
    chmod 600 /root/demo-openrc
    
    mark_completed "env_scripts_created"
}

# Create initial projects and users
create_projects_users() {
    if is_completed "projects_users_created"; then
        log "Projects and users already created, skipping..."
        return
    fi
    
    log "Creating initial projects and users..."
    
    source /root/admin-openrc
    
    # Create service project
    if ! openstack project show service >/dev/null 2>&1; then
        openstack project create --domain default --description "Service Project" service
    fi
    
    # Create demo project
    if ! openstack project show myproject >/dev/null 2>&1; then
        openstack project create --domain default --description "Demo Project" myproject
    fi
    
    # Create demo user
    if ! openstack user show demo >/dev/null 2>&1; then
        openstack user create --domain default --password "$DEMO_PASS" demo
    fi
    
    # Create user role
    if ! openstack role show user >/dev/null 2>&1; then
        openstack role create user
    fi
    
    # Add user role to demo user
    openstack role add --project myproject --user demo user 2>/dev/null || true
    
    mark_completed "projects_users_created"
}

# Install and configure Glance
configure_glance() {
    if is_completed "glance_configured"; then
        log "Glance already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Glance (Image service)..."
    
    source /root/admin-openrc
    
    # Create database
    mysql_cmd "CREATE DATABASE IF NOT EXISTS glance;"
    mysql_cmd "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Create user and service
    if ! openstack user show glance >/dev/null 2>&1; then
        openstack user create --domain default --password "$SERVICE_PASS" glance
        openstack role add --project service --user glance admin
    fi
    
    if ! openstack service show glance >/dev/null 2>&1; then
        openstack service create --name glance --description "OpenStack Image" image
    fi
    
    # Create endpoints
    if ! openstack endpoint list --service image | grep -q public; then
        openstack endpoint create --region RegionOne image public http://controller:9292
        openstack endpoint create --region RegionOne image internal http://controller:9292
        openstack endpoint create --region RegionOne image admin http://controller:9292
    fi
    
    # Install packages
    apt install -y glance
    
    # Configure Glance
    cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.backup
    
    crudini --set /etc/glance/glance-api.conf database connection "mysql+pymysql://glance:$SERVICE_PASS@controller/glance"
    
    crudini --set /etc/glance/glance-api.conf keystone_authtoken www_authenticate_uri http://controller:5000
    crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://controller:5000
    crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers controller:11211
    crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type password
    crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name Default
    crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name Default
    crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name service
    crudini --set /etc/glance/glance-api.conf keystone_authtoken username glance
    crudini --set /etc/glance/glance-api.conf keystone_authtoken password "$SERVICE_PASS"
    
    crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone
    
    crudini --set /etc/glance/glance-api.conf glance_store stores file,http
    crudini --set /etc/glance/glance-api.conf glance_store default_store file
    crudini --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/
    
    # Populate database
    su -s /bin/sh -c "glance-manage db_sync" glance
    
    # Start services
    systemctl restart glance-api
    systemctl enable glance-api
    
    mark_completed "glance_configured"
}

# Install and configure Placement
configure_placement() {
    if is_completed "placement_configured"; then
        log "Placement already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Placement service..."
    
    source /root/admin-openrc
    
    # Create database
    mysql_cmd "CREATE DATABASE IF NOT EXISTS placement;"
    mysql_cmd "GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Create user and service
    if ! openstack user show placement >/dev/null 2>&1; then
        openstack user create --domain default --password "$SERVICE_PASS" placement
        openstack role add --project service --user placement admin
    fi
    
    if ! openstack service show placement >/dev/null 2>&1; then
        openstack service create --name placement --description "Placement API" placement
    fi
    
    # Create endpoints
    if ! openstack endpoint list --service placement | grep -q public; then
        openstack endpoint create --region RegionOne placement public http://controller:8778
        openstack endpoint create --region RegionOne placement internal http://controller:8778
        openstack endpoint create --region RegionOne placement admin http://controller:8778
    fi
    
    # Install packages
    apt install -y placement-api
    
    # Configure Placement
    cp /etc/placement/placement.conf /etc/placement/placement.conf.backup
    
    crudini --set /etc/placement/placement.conf placement_database connection "mysql+pymysql://placement:$SERVICE_PASS@controller/placement"
    crudini --set /etc/placement/placement.conf api auth_strategy keystone
    
    crudini --set /etc/placement/placement.conf keystone_authtoken auth_url http://controller:5000/v3
    crudini --set /etc/placement/placement.conf keystone_authtoken memcached_servers controller:11211
    crudini --set /etc/placement/placement.conf keystone_authtoken auth_type password
    crudini --set /etc/placement/placement.conf keystone_authtoken project_domain_name Default
    crudini --set /etc/placement/placement.conf keystone_authtoken user_domain_name Default
    crudini --set /etc/placement/placement.conf keystone_authtoken project_name service
    crudini --set /etc/placement/placement.conf keystone_authtoken username placement
    crudini --set /etc/placement/placement.conf keystone_authtoken password "$SERVICE_PASS"
    
    # Populate database
    su -s /bin/sh -c "placement-manage db sync" placement
    
    # Restart Apache
    systemctl restart apache2
    
    mark_completed "placement_configured"
}

# Install and configure Nova
configure_nova() {
    if is_completed "nova_configured"; then
        log "Nova already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Nova (Compute service)..."
    
    source /root/admin-openrc
    
    # Create databases
    mysql_cmd "CREATE DATABASE IF NOT EXISTS nova_api;"
    mysql_cmd "CREATE DATABASE IF NOT EXISTS nova;"
    mysql_cmd "CREATE DATABASE IF NOT EXISTS nova_cell0;"
    
    mysql_cmd "GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Create user and service
    if ! openstack user show nova >/dev/null 2>&1; then
        openstack user create --domain default --password "$SERVICE_PASS" nova
        openstack role add --project service --user nova admin
    fi
    
    if ! openstack service show nova >/dev/null 2>&1; then
        openstack service create --name nova --description "OpenStack Compute" compute
    fi
    
    # Create endpoints
    if ! openstack endpoint list --service compute | grep -q public; then
        openstack endpoint create --region RegionOne compute public http://controller:8774/v2.1
        openstack endpoint create --region RegionOne compute internal http://controller:8774/v2.1
        openstack endpoint create --region RegionOne compute admin http://controller:8774/v2.1
    fi
    
    # Install packages
    apt install -y nova-api nova-conductor nova-novncproxy nova-scheduler nova-compute
    
    # Configure Nova
    cp /etc/nova/nova.conf /etc/nova/nova.conf.backup
    
    crudini --set /etc/nova/nova.conf api_database connection "mysql+pymysql://nova:$SERVICE_PASS@controller/nova_api"
    crudini --set /etc/nova/nova.conf database connection "mysql+pymysql://nova:$SERVICE_PASS@controller/nova"
    
    crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://openstack:$RABBIT_PASS@controller:5672/"
    crudini --set /etc/nova/nova.conf DEFAULT my_ip "$CONTROLLER_IP"
    
    crudini --set /etc/nova/nova.conf api auth_strategy keystone
    
    crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri http://controller:5000/
    crudini --set /etc/nova/nova.conf keystone_authtoken auth_url http://controller:5000/
    crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers controller:11211
    crudini --set /etc/nova/nova.conf keystone_authtoken auth_type password
    crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name Default
    crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name Default
    crudini --set /etc/nova/nova.conf keystone_authtoken project_name service
    crudini --set /etc/nova/nova.conf keystone_authtoken username nova
    crudini --set /etc/nova/nova.conf keystone_authtoken password "$SERVICE_PASS"
    
    crudini --set /etc/nova/nova.conf service_user send_service_user_token true
    crudini --set /etc/nova/nova.conf service_user auth_url http://controller:5000/
    crudini --set /etc/nova/nova.conf service_user auth_strategy keystone
    crudini --set /etc/nova/nova.conf service_user auth_type password
    crudini --set /etc/nova/nova.conf service_user project_domain_name Default
    crudini --set /etc/nova/nova.conf service_user user_domain_name Default
    crudini --set /etc/nova/nova.conf service_user project_name service
    crudini --set /etc/nova/nova.conf service_user username nova
    crudini --set /etc/nova/nova.conf service_user password "$SERVICE_PASS"
    
    crudini --set /etc/nova/nova.conf vnc enabled true
    crudini --set /etc/nova/nova.conf vnc server_listen '$my_ip'
    crudini --set /etc/nova/nova.conf vnc server_proxyclient_address '$my_ip'
    
    crudini --set /etc/nova/nova.conf glance api_servers http://controller:9292
    
    crudini --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
    
    crudini --set /etc/nova/nova.conf placement region_name RegionOne
    crudini --set /etc/nova/nova.conf placement project_domain_name Default
    crudini --set /etc/nova/nova.conf placement project_name service
    crudini --set /etc/nova/nova.conf placement auth_type password
    crudini --set /etc/nova/nova.conf placement user_domain_name Default
    crudini --set /etc/nova/nova.conf placement auth_url http://controller:5000/v3
    crudini --set /etc/nova/nova.conf placement username placement
    crudini --set /etc/nova/nova.conf placement password "$SERVICE_PASS"
    
    # Configure compute for QEMU/KVM
    crudini --set /etc/nova/nova-compute.conf libvirt virt_type qemu
    
    # Populate databases
    su -s /bin/sh -c "nova-manage api_db sync" nova
    su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova 2>/dev/null || true
    su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova 2>/dev/null || true
    su -s /bin/sh -c "nova-manage db sync" nova
    
    # Verify cell registration
    su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova
    
    # Start services
    systemctl restart nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
    systemctl enable nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
    
    mark_completed "nova_configured"
}

# Install and configure Neutron
configure_neutron() {
    if is_completed "neutron_configured"; then
        log "Neutron already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Neutron (Networking service)..."
    
    source /root/admin-openrc
    
    # Create database
    mysql_cmd "CREATE DATABASE IF NOT EXISTS neutron;"
    mysql_cmd "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Create user and service
    if ! openstack user show neutron >/dev/null 2>&1; then
        openstack user create --domain default --password "$SERVICE_PASS" neutron
        openstack role add --project service --user neutron admin
    fi
    
    if ! openstack service show neutron >/dev/null 2>&1; then
        openstack service create --name neutron --description "OpenStack Networking" network
    fi
    
    # Create endpoints
    if ! openstack endpoint list --service network | grep -q public; then
        openstack endpoint create --region RegionOne network public http://controller:9696
        openstack endpoint create --region RegionOne network internal http://controller:9696
        openstack endpoint create --region RegionOne network admin http://controller:9696
    fi
    
    # Install packages
    apt install -y neutron-server neutron-plugin-ml2 \
        neutron-openvswitch-agent neutron-l3-agent neutron-dhcp-agent \
        neutron-metadata-agent
    
    # Configure Neutron
    cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.backup
    
    crudini --set /etc/neutron/neutron.conf database connection "mysql+pymysql://neutron:$SERVICE_PASS@controller/neutron"
    
    crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
    crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins router
    crudini --set /etc/neutron/neutron.conf DEFAULT transport_url "rabbit://openstack:$RABBIT_PASS@controller"
    crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
    crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes true
    crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes true
    
    crudini --set /etc/neutron/neutron.conf keystone_authtoken www_authenticate_uri http://controller:5000
    crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://controller:5000
    crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers controller:11211
    crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
    crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name Default
    crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name Default
    crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name service
    crudini --set /etc/neutron/neutron.conf keystone_authtoken username neutron
    crudini --set /etc/neutron/neutron.conf keystone_authtoken password "$SERVICE_PASS"
    
    crudini --set /etc/neutron/neutron.conf nova auth_url http://controller:5000
    crudini --set /etc/neutron/neutron.conf nova auth_type password
    crudini --set /etc/neutron/neutron.conf nova project_domain_name Default
    crudini --set /etc/neutron/neutron.conf nova user_domain_name Default
    crudini --set /etc/neutron/neutron.conf nova region_name RegionOne
    crudini --set /etc/neutron/neutron.conf nova project_name service
    crudini --set /etc/neutron/neutron.conf nova username nova
    crudini --set /etc/neutron/neutron.conf nova password "$SERVICE_PASS"
    
    crudini --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp
    
    # Configure ML2 plugin
    cp /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugins/ml2/ml2_conf.ini.backup
    
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers flat,vlan,vxlan
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vxlan
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch,l2population
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security
    
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks provider
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan vni_ranges 1:1000
    
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset true
    
    # Configure Open vSwitch agent
    cp /etc/neutron/plugins/ml2/openvswitch_agent.ini /etc/neutron/plugins/ml2/openvswitch_agent.ini.backup
    
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings provider:br-provider
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs local_ip "$CONTROLLER_IP"
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent tunnel_types vxlan
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent l2_population true
    
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup firewall_driver openvswitch
    
    # Configure L3 agent
    cp /etc/neutron/l3_agent.ini /etc/neutron/l3_agent.ini.backup
    crudini --set /etc/neutron/l3_agent.ini DEFAULT interface_driver openvswitch
    
    # Configure DHCP agent
    cp /etc/neutron/dhcp_agent.ini /etc/neutron/dhcp_agent.ini.backup
    crudini --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver openvswitch
    crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
    crudini --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true
    
    # Configure metadata agent
    cp /etc/neutron/metadata_agent.ini /etc/neutron/metadata_agent.ini.backup
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_host controller
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret "$METADATA_SECRET"
    
    # Configure Nova to use Neutron
    crudini --set /etc/nova/nova.conf neutron auth_url http://controller:5000
    crudini --set /etc/nova/nova.conf neutron auth_type password
    crudini --set /etc/nova/nova.conf neutron project_domain_name Default
    crudini --set /etc/nova/nova.conf neutron user_domain_name Default
    crudini --set /etc/nova/nova.conf neutron region_name RegionOne
    crudini --set /etc/nova/nova.conf neutron project_name service
    crudini --set /etc/nova/nova.conf neutron username neutron
    crudini --set /etc/nova/nova.conf neutron password "$SERVICE_PASS"
    crudini --set /etc/nova/nova.conf neutron service_metadata_proxy true
    crudini --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret "$METADATA_SECRET"
    
    # Create OVS bridge
    systemctl start openvswitch-switch
    systemctl enable openvswitch-switch
    
    if ! ovs-vsctl br-exists br-provider; then
        ovs-vsctl add-br br-provider
        ovs-vsctl add-port br-provider "$PROVIDER_INTERFACE"
    fi
    
    # Create symbolic link
    ln -sf /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    
    # Populate database
    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
        --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
    
    # Restart services
    systemctl restart nova-api
    systemctl restart neutron-server neutron-openvswitch-agent neutron-dhcp-agent \
        neutron-metadata-agent neutron-l3-agent
    systemctl enable neutron-server neutron-openvswitch-agent neutron-dhcp-agent \
        neutron-metadata-agent neutron-l3-agent
    
    mark_completed "neutron_configured"
}

# Install and configure Horizon
configure_horizon() {
    if is_completed "horizon_configured"; then
        log "Horizon already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Horizon (Dashboard)..."
    
    # Install packages
    apt install -y openstack-dashboard
    
    # Fix the configuration file issue first
    PROBLEM_FILE="/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.py"
    if [ -f "$PROBLEM_FILE" ]; then
        # Remove the problematic TEMPLATES line if it exists
        sed -i '/TEMPLATES\[0\]/d' "$PROBLEM_FILE" 2>/dev/null || true
    fi
    
    # Create proper configuration
    cat > /etc/openstack-dashboard/local_settings.py << EOF
# -*- coding: utf-8 -*-

import os
from django.utils.translation import gettext_lazy as _

DEBUG = False

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = '$(openssl rand -hex 32)'

WEBROOT = '/horizon/'
ALLOWED_HOSTS = ['*']

LOCAL_PATH = os.path.dirname(os.path.abspath(__file__))

# Session configuration
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
SESSION_COOKIE_HTTPONLY = True
SESSION_EXPIRE_AT_BROWSER_CLOSE = True
SESSION_COOKIE_SECURE = False

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '$CONTROLLER_IP:11211',
    }
}

# Email configuration
EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'

# OpenStack configuration
OPENSTACK_HOST = "$CONTROLLER_IP"
OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"

# SSL configuration
OPENSTACK_SSL_NO_VERIFY = True
OPENSTACK_SSL_CACERT = None

# API versions
OPENSTACK_API_VERSIONS = {
    "data-processing": 1.1,
    "identity": 3,
    "image": 2,
    "volume": 3,
    "compute": 2,
}

# Keystone configuration
OPENSTACK_KEYSTONE_BACKEND = {
    'name': 'native',
    'can_edit_user': True,
    'can_edit_group': True,
    'can_edit_project': True,
    'can_edit_domain': True,
    'can_edit_role': True,
}

OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'Default'

# Feature configuration
OPENSTACK_HYPERVISOR_FEATURES = {
    'can_set_mount_point': False,
    'can_set_password': False,
}

OPENSTACK_CINDER_FEATURES = {
    'enable_backup': False,
}

OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': True,
    'enable_distributed_router': False,
    'enable_ha_router': False,
    'enable_fip_topology_check': True,
    'supported_vnic_types': ['*'],
    'physical_networks': [],
    'enable_auto_allocated_network': False,
}

# Image configuration
OPENSTACK_IMAGE_BACKEND = {
    'image_formats': [
        ('', _('Select format')),
        ('aki', _('AKI - Amazon Kernel Image')),
        ('ami', _('AMI - Amazon Machine Image')),
        ('ari', _('ARI - Amazon Ramdisk Image')),
        ('iso', _('ISO - Optical Disk Image')),
        ('ova', _('OVA - Open Virtual Appliance')),
        ('qcow2', _('QCOW2 - QEMU Emulator')),
        ('raw', _('Raw')),
        ('vdi', _('VDI - Virtual Disk Image')),
        ('vhd', _('VHD - Virtual Hard Disk')),
        ('vmdk', _('VMDK - Virtual Machine Disk')),
    ],
}

# Theme configuration
DEFAULT_THEME = 'default'

# Session timeout
SESSION_TIMEOUT = 1800

# Pagination
API_RESULT_LIMIT = 1000
API_RESULT_PAGE_SIZE = 20
DROPDOWN_MAX_ITEMS = 30

# Timezone
TIME_ZONE = "UTC"

# Logging configuration
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'null': {
            'level': 'DEBUG',
            'class': 'logging.NullHandler',
        },
        'console': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
        },
    },
    'loggers': {
        'django.db.backends': {
            'handlers': ['null'],
            'propagate': False,
        },
        'requests': {
            'handlers': ['null'],
            'propagate': False,
        },
        'horizon': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'openstack_dashboard': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'novaclient': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'cinderclient': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'keystoneclient': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'glanceclient': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'neutronclient': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
    },
}

# Security configuration
USE_X_FORWARDED_HOST = True
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
CSRF_COOKIE_HTTPONLY = True
EOF

    # Fix permissions
    chmod 644 /etc/openstack-dashboard/local_settings.py
    chown root:www-data /etc/openstack-dashboard/local_settings.py
    
    # Fix symbolic link
    if [ -L "$PROBLEM_FILE" ]; then
        rm -f "$PROBLEM_FILE"
    fi
    ln -sf /etc/openstack-dashboard/local_settings.py "$PROBLEM_FILE"
    
    # Fix permissions on all directories
    chown -R root:www-data /usr/lib/python3/dist-packages/openstack_dashboard/
    chmod -R 755 /usr/lib/python3/dist-packages/openstack_dashboard/
    find /usr/lib/python3/dist-packages/openstack_dashboard/local/ -type f -exec chmod 644 {} \;
    
    # Create and fix static files directory
    mkdir -p /var/lib/openstack-dashboard
    chown -R www-data:www-data /var/lib/openstack-dashboard/
    
    # Create log directory
    mkdir -p /var/log/horizon
    touch /var/log/horizon/horizon.log
    chown -R www-data:www-data /var/log/horizon/
    
    # Complete package configuration if needed
    dpkg --configure -a 2>/dev/null || true
    
    # Restart Apache
    systemctl restart apache2
    
    mark_completed "horizon_configured"
}

# Create Cinder LVM volume group
create_cinder_lvm() {
    log "Creating LVM volume group for Cinder..."
    
    # Check if volume group already exists
    if vgdisplay cinder-volumes >/dev/null 2>&1; then
        log "cinder-volumes volume group already exists"
        return
    fi
    
    # Check if we have a spare disk
    if [ -b /dev/sdb ] && ! pvdisplay /dev/sdb >/dev/null 2>&1; then
        pvcreate /dev/sdb
        vgcreate cinder-volumes /dev/sdb
    else
        # Create a loopback device for testing
        if [ ! -f /var/lib/cinder/cinder-volumes ]; then
            mkdir -p /var/lib/cinder
            dd if=/dev/zero of=/var/lib/cinder/cinder-volumes bs=1G count=20
        fi
        
        # Find a free loop device
        LOOP_DEV=$(losetup -f)
        losetup "$LOOP_DEV" /var/lib/cinder/cinder-volumes
        pvcreate "$LOOP_DEV"
        vgcreate cinder-volumes "$LOOP_DEV"
        
        # Make it persistent
        echo "loop" >> /etc/modules-load.d/loop.conf
        
        # Add to rc.local for persistence across reboots
        cat > /etc/systemd/system/cinder-loop.service << EOF
[Unit]
Description=Setup loop device for Cinder
Before=cinder-volume.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/losetup $LOOP_DEV /var/lib/cinder/cinder-volumes
ExecStop=/sbin/losetup -d $LOOP_DEV
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable cinder-loop.service
        systemctl start cinder-loop.service
    fi
    
    # Configure LVM filtering
    if ! grep -q "filter" /etc/lvm/lvm.conf; then
        sed -i '/devices {/a \ \ \ \ filter = [ "a|/dev/sda|", "a|/dev/sdb|", "a|/dev/loop.*|", "r|.*|" ]' /etc/lvm/lvm.conf
    fi
}

# Install and configure Cinder
configure_cinder() {
    if is_completed "cinder_configured"; then
        log "Cinder already configured, skipping..."
        return
    fi
    
    log "Installing and configuring Cinder (Block Storage service)..."
    
    source /root/admin-openrc
    
    # Create database
    mysql_cmd "CREATE DATABASE IF NOT EXISTS cinder;"
    mysql_cmd "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$SERVICE_PASS';"
    mysql_cmd "FLUSH PRIVILEGES;"
    
    # Create user and services
    if ! openstack user show cinder >/dev/null 2>&1; then
        openstack user create --domain default --password "$SERVICE_PASS" cinder
        openstack role add --project service --user cinder admin
    fi
    
    if ! openstack service show cinderv3 >/dev/null 2>&1; then
        openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
    fi
    
    # Create endpoints
    if ! openstack endpoint list --service volumev3 | grep -q public; then
        openstack endpoint create --region RegionOne volumev3 public 'http://controller:8776/v3/%(project_id)s'
        openstack endpoint create --region RegionOne volumev3 internal 'http://controller:8776/v3/%(project_id)s'
        openstack endpoint create --region RegionOne volumev3 admin 'http://controller:8776/v3/%(project_id)s'
    fi
    
    # Install packages
    apt install -y cinder-api cinder-scheduler cinder-volume tgt lvm2
    
    # Check if cinder-api runs under Apache WSGI
    if [ ! -f /etc/apache2/sites-available/cinder-wsgi.conf ]; then
        apt install -y libapache2-mod-wsgi-py3
    fi
    
    # Configure Cinder
    cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.backup
    
    crudini --set /etc/cinder/cinder.conf database connection "mysql+pymysql://cinder:$SERVICE_PASS@controller/cinder"
    crudini --set /etc/cinder/cinder.conf DEFAULT transport_url "rabbit://openstack:$RABBIT_PASS@controller"
    crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
    crudini --set /etc/cinder/cinder.conf DEFAULT my_ip "$CONTROLLER_IP"
    crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends lvm
    crudini --set /etc/cinder/cinder.conf DEFAULT glance_api_servers http://controller:9292
    
    crudini --set /etc/cinder/cinder.conf keystone_authtoken www_authenticate_uri http://controller:5000
    crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://controller:5000
    crudini --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers controller:11211
    crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
    crudini --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name Default
    crudini --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name Default
    crudini --set /etc/cinder/cinder.conf keystone_authtoken project_name service
    crudini --set /etc/cinder/cinder.conf keystone_authtoken username cinder
    crudini --set /etc/cinder/cinder.conf keystone_authtoken password "$SERVICE_PASS"
    
    crudini --set /etc/cinder/cinder.conf lvm volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
    crudini --set /etc/cinder/cinder.conf lvm volume_group cinder-volumes
    crudini --set /etc/cinder/cinder.conf lvm target_protocol iscsi
    crudini --set /etc/cinder/cinder.conf lvm target_helper tgtadm
    
    crudini --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp
    
    # Create LVM volume group
    create_cinder_lvm
    
    # Populate database
    su -s /bin/sh -c "cinder-manage db sync" cinder
    
    # Configure Nova to use Cinder
    crudini --set /etc/nova/nova.conf cinder os_region_name RegionOne
    
    # Restart Nova API
    systemctl restart nova-api
    
    # Check if cinder-api runs under Apache (WSGI) or standalone
    if [ -f /etc/apache2/sites-available/cinder-wsgi.conf ]; then
        a2ensite cinder-wsgi >/dev/null 2>&1 || true
        systemctl restart apache2
        
        # Only start scheduler and volume services
        systemctl enable cinder-scheduler cinder-volume tgt >/dev/null 2>&1 || true
        systemctl restart cinder-scheduler cinder-volume tgt
    else
        # Try standalone services
        systemctl enable cinder-scheduler cinder-volume tgt >/dev/null 2>&1 || true
        systemctl restart cinder-scheduler cinder-volume tgt
        
        # Try to start cinder-api if it exists
        if systemctl list-unit-files | grep -q cinder-api.service; then
            systemctl enable cinder-api
            systemctl restart cinder-api
        fi
    fi
    
    mark_completed "cinder_configured"
}

# Download test image
download_test_image() {
    if is_completed "test_image_downloaded"; then
        log "Test image already downloaded, skipping..."
        return
    fi
    
    log "Downloading CirrOS test image..."
    
    source /root/admin-openrc
    
    # Check if image already exists
    if ! openstack image show cirros >/dev/null 2>&1; then
        wget -P /tmp http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
        
        openstack image create "cirros" \
          --file /tmp/cirros-0.6.2-x86_64-disk.img \
          --disk-format qcow2 --container-format bare \
          --public
        
        rm -f /tmp/cirros-0.6.2-x86_64-disk.img
    fi
    
    mark_completed "test_image_downloaded"
}

# Create test networks
create_test_networks() {
    if is_completed "test_networks_created"; then
        log "Test networks already created, skipping..."
        return
    fi
    
    log "Creating test networks..."
    
    source /root/admin-openrc
    
    # Create provider network
    if ! openstack network show provider >/dev/null 2>&1; then
        openstack network create --share --external \
          --provider-physical-network provider \
          --provider-network-type flat provider
        
        # Create provider subnet
        openstack subnet create --network provider \
          --allocation-pool start=203.0.113.101,end=203.0.113.250 \
          --dns-nameserver 8.8.8.8 --gateway 203.0.113.1 \
          --subnet-range 203.0.113.0/24 provider-subnet
    fi
    
    source /root/demo-openrc
    
    # Create private network
    if ! openstack network show private >/dev/null 2>&1; then
        openstack network create private
        
        # Create private subnet
        openstack subnet create --network private \
          --dns-nameserver 8.8.8.8 --gateway 172.16.1.1 \
          --subnet-range 172.16.1.0/24 private-subnet
        
        # Create router
        openstack router create router
        openstack router add subnet router private-subnet
        openstack router set router --external-gateway provider
    fi
    
    mark_completed "test_networks_created"
}

# Create test flavor
create_test_flavor() {
    if is_completed "test_flavor_created"; then
        log "Test flavor already created, skipping..."
        return
    fi
    
    log "Creating test flavor..."
    
    source /root/admin-openrc
    
    # Check if flavor already exists
    if ! openstack flavor show m1.nano >/dev/null 2>&1; then
        openstack flavor create --id 0 --vcpus 1 --ram 64 --disk 1 m1.nano
    fi
    
    mark_completed "test_flavor_created"
}

# Configure security groups
configure_security_groups() {
    if is_completed "security_groups_configured"; then
        log "Security groups already configured, skipping..."
        return
    fi
    
    log "Configuring security groups..."
    
    source /root/admin-openrc
    
    # Allow ICMP
    openstack security group rule create --proto icmp default 2>/dev/null || true
    
    # Allow SSH
    openstack security group rule create --proto tcp --dst-port 22 default 2>/dev/null || true
    
    mark_completed "security_groups_configured"
}

# Final verification
verify_installation() {
    log "Verifying installation..."
    
    source /root/admin-openrc
    
    echo ""
    echo "=== Service Status ==="
    openstack service list
    
    echo ""
    echo "=== Compute Service Status ==="
    openstack compute service list
    
    echo ""
    echo "=== Network Agent Status ==="
    openstack network agent list
    
    echo ""
    echo "=== Volume Service Status ==="
    openstack volume service list || echo "Note: Cinder API may be running under Apache WSGI"
    
    echo ""
    echo "=== Images ==="
    openstack image list
    
    echo ""
    echo "=== Networks ==="
    openstack network list
    
    echo ""
    echo "=== Flavors ==="
    openstack flavor list
    
    echo ""
    echo "=== Security Groups ==="
    openstack security group list
}

# Display final information
display_final_info() {
    echo ""
    echo "=========================================="
    echo "=== OpenStack Installation Complete! ==="
    echo "=========================================="
    echo ""
    echo "Dashboard Access:"
    echo "  URL: http://$CONTROLLER_IP/horizon"
    echo "  Domain: Default"
    echo "  Username: admin"
    echo "  Password: $ADMIN_PASS"
    echo ""
    echo "Demo User:"
    echo "  Username: demo"
    echo "  Password: $DEMO_PASS"
    echo ""
    echo "CLI Access:"
    echo "  source /root/admin-openrc   # For admin access"
    echo "  source /root/demo-openrc    # For demo user access"
    echo ""
    echo "Network Configuration:"
    echo "  Provider Network Type: flat"
    echo "  Physical Network Name: provider"
    echo "  Provider Bridge: br-provider"
    echo "  Provider Interface: $PROVIDER_INTERFACE"
    echo ""
    echo "Test Resources Created:"
    echo "  - CirrOS image"
    echo "  - m1.nano flavor"
    echo "  - Provider network (203.0.113.0/24)"
    echo "  - Private network (172.16.1.0/24)"
    echo "  - Security group rules (ICMP, SSH)"
    echo ""
    echo "Next Steps:"
    echo "1. Access the Horizon dashboard"
    echo "2. Create a key pair for SSH access to instances"
    echo "3. Launch a test instance"
    echo ""
    echo "Troubleshooting:"
    echo "  - Logs: /var/log/apache2/error.log"
    echo "  - Service status: systemctl status <service-name>"
    echo "  - OpenStack logs: /var/log/<service-name>/"
    echo ""
    echo "Documentation:"
    echo "  https://docs.openstack.org/2024.2/"
    echo ""
}

# Main installation function
main() {
    log "Starting OpenStack All-in-One installation (Final Version)..."
    echo "This script will install OpenStack 2024.2 (Dalmatian) on Ubuntu 24.04 LTS"
    echo ""
    
    # Pre-flight checks
    pre_flight_checks
    
    # Get configuration
    get_config
    
    # System preparation
    update_system
    install_utilities
    configure_networking
    configure_ntp
    
    # Install supporting services
    configure_mariadb
    configure_rabbitmq
    configure_memcached
    configure_etcd
    
    # Enable OpenStack repository and install client
    enable_openstack_repo
    install_openstack_client
    
    # Install OpenStack services
    configure_keystone
    create_env_scripts
    create_projects_users
    configure_glance
    configure_placement
    configure_nova
    configure_neutron
    configure_horizon
    configure_cinder
    
    # Post-installation setup
    download_test_image
    create_test_networks
    create_test_flavor
    configure_security_groups
    
    # Verification
    verify_installation
    
    # Display final information
    display_final_info
}

# Error handler
trap 'error "Installation failed at line $LINENO"' ERR

# Run main function
main "$@"
