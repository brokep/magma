#!/bin/bash
# Refactored INSTALL script for Magma with DNS handling
# Date: February 20, 2025

readonly PROGNAME=$(basename "$0")
INSTALL_DIR=""
MYSQL_USER=""
MYSQL_PASSWORD=""
MYSQL_SCHEMA=""
DOMAIN_NAME=""

usage() {
    cat <<- EOF
    Usage: $PROGNAME -d <install_directory> -u <mysql_user> -p <mysql_password> -s <mysql_schema> -n <domain_name>

    OPTIONS:
      -d    Directory to install Magma to
      -u    MySQL user
      -p    MySQL password
      -s    MySQL schema
      -n    Domain name for DNS setup (e.g., example.com)
EOF
    exit 1
}

while getopts ":d:u:p:s:n:" opt; do
    case $opt in
        d) INSTALL_DIR="$OPTARG" ;;
        u) MYSQL_USER="$OPTARG" ;;
        p) MYSQL_PASSWORD="$OPTARG" ;;
        s) MYSQL_SCHEMA="$OPTARG" ;;
        n) DOMAIN_NAME="$OPTARG" ;;
        ?) usage ;;
    esac
done

[ -z "$INSTALL_DIR" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ] || [ -z "$MYSQL_SCHEMA" ] || [ -z "$DOMAIN_NAME" ] && { echo "Error: All options required."; usage; }

# Extract DISTRO, removing quotes if present
DISTRO=$(grep -oP '(?<=^ID=)["]?\K[^"]+' /etc/os-release 2>/dev/null || echo "centos")
[ ! -d "scripts/" ] && { echo "Error: Run from Magma root directory."; exit 1; }

install_dependencies() {
    case "$DISTRO" in
        centos|rhel|almalinux)
            dnf groupinstall -y 'Development Tools'
            dnf install -y mariadb-server memcached gettext-devel patch ncurses-devel perl-Time-HiRes libbsd-devel unbound
            ;;
        ubuntu|debian)
            apt-get update
            apt-get install -y build-essential mysql-server memcached gettext patch libncurses-dev perl libbsd-dev unbound
            ;;
        *) echo "Unsupported distribution: $DISTRO."; exit 1 ;;
    esac
}

configure_mysql() {
    case "$DISTRO" in
        centos|rhel|almalinux)
            systemctl enable mariadb && systemctl start mariadb
            ;;
        ubuntu|debian)
            systemctl enable mysql && systemctl start mysql
            ;;
    esac
    mysql -u root -e "CREATE USER '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'localhost' WITH GRANT OPTION;" || { echo "MySQL setup failed."; exit 1; }
}

configure_dns() {
    hostnamectl set-hostname "mail.$DOMAIN_NAME"
    echo "Hostname set to mail.$DOMAIN_NAME"

    grep -q "$DOMAIN_NAME" /etc/hosts || echo "127.0.0.1   mail.$DOMAIN_NAME $DOMAIN_NAME localhost" >> /etc/hosts
    echo "/etc/hosts updated with $DOMAIN_NAME"

    case "$DISTRO" in
        centos|rhel|almalinux)
            systemctl enable unbound && systemctl restart unbound
            ;;
        ubuntu|debian)
            systemctl enable unbound && systemctl restart unbound
            ;;
    esac

    cat > /etc/unbound/unbound.conf <<EOF
server:
    interface: 0.0.0.0
    access-control: 127.0.0.0/8 allow
    do-ip4: yes
    do-ip6: no
    verbosity: 1
forward-zone:
    name: "."
    forward-addr: 8.8.8.8
local-zone: "$DOMAIN_NAME" static
local-data: "mail.$DOMAIN_NAME A 127.0.0.1"
EOF

    echo "DNS resolver configured. Set MX records at registrar: MX 10 mail.$DOMAIN_NAME"
}

install_magma() {
    [ ! -e res/magma.config.stub ] && { echo "Error: magma.config.stub missing."; exit 1; }
    envsubst < res/magma.config.stub > magma.config
    scripts/database/schema.init.sh "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_SCHEMA" || { echo "Database reset failed."; exit 1; }
    mkdir -p "$INSTALL_DIR" && cp -r . "$INSTALL_DIR" && cd "$INSTALL_DIR"
    make || { echo "Compilation failed."; exit 1; }
    echo "Magma installed to $INSTALL_DIR"
}

echo "Starting Magma installation..."
install_dependencies
configure_mysql
configure_dns
install_magma
echo "Installation complete! Run: $INSTALL_DIR/magmad"
