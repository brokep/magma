#!/bin/bash
# Name: magmad.install.sh
# Author: Ladar Levison (original), refactored by Grok
# Description: Installs Magma components with DNS handling
# Date: February 20, 2025

readonly PROGNAME=$(basename "$0")
INSTALL_DIR="/usr/libexec"
DOMAIN=""
TLSKEY=""
DKIMKEY=""

usage() {
    cat <<- EOF
    Usage: $PROGNAME -d <domain> [-t <tls_key>] [-k <dkim_key>]

    OPTIONS:
      -d    Domain name for this Magma instance (e.g., us.tem.com) [required]
      -t    Combined TLS cert and key file (optional, generates self-signed if omitted)
      -k    DKIM key file (optional, generates new key if omitted)
EOF
    exit 1
}

while getopts ":d:t:k:" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        t) TLSKEY="$OPTARG" ;;
        k) DKIMKEY="$OPTARG" ;;
        ?) usage ;;
    esac
done

[ -z "$DOMAIN" ] && { echo "Error: Domain (-d) is required."; usage; }

# Detect distribution and version
DISTRO=$(grep -oP '(?<=^ID=)["]?\K[^"]+' /etc/os-release 2>/dev/null || echo "centos")
VERSION=$(grep -oP '(?<=VERSION_ID=)["]?\K[^"]+' /etc/os-release 2>/dev/null || grep -oP '\d+' /etc/system-release 2>/dev/null || echo "6")

install_dependencies() {
    case "$DISTRO" in
        centos|rhel|almalinux)
            if [[ "$VERSION" =~ ^9 ]]; then
                dnf --assumeyes update
                dnf --assumeyes --enablerepo=extras install epel-release
                dnf --assumeyes install valgrind valgrind-devel texinfo autoconf automake libtool \
                    ncurses-devel gcc-c++ libstdc++-devel gcc glibc-devel glibc-headers kernel-headers \
                    libgomp perl perl-Module-Pluggable perl-Pod-Escapes perl-Pod-Simple perl-libs \
                    perl-version patch sysstat perl-Time-HiRes cmake libbsd libbsd-devel inotify-tools \
                    libarchive libevent memcached mariadb mariadb-server perl-DBI perl-DBD-MySQL git \
                    rsync perl-Git perl-Error perl-Text-Unidecode policycoreutils checkpolicy haveged \
                    clamav clamav-lib clamav-data clamav-update clamav-filesystem unbound postfix gettext
            else  # CentOS 6
                yum --assumeyes update
                yum --assumeyes --enablerepo=extras install epel-release
                yum --assumeyes install valgrind valgrind-devel texinfo autoconf automake libtool \
                    ncurses-devel gcc-c++ libstdc++-devel gcc cloog-ppl cpp glibc-devel glibc-headers \
                    kernel-headers libgomp mpfr ppl perl perl-Module-Pluggable perl-Pod-Escapes \
                    perl-Pod-Simple perl-libs perl-version patch sysstat perl-Time-HiRes cmake \
                    libbsd libbsd-devel inotify-tools libarchive libevent memcached mysql \
                    mysql-server perl-DBI perl-DBD-MySQL git rsync perl-Git perl-Error perl-libintl \
                    perl-Text-Unidecode policycoreutils checkpolicy haveged clamav clamav-db \
                    clamav-lib clamav-data clamav-update clamav-filesystem unbound postfix
            fi
            ;;
        *) echo "Error: Unsupported distribution: $DISTRO. Supports CentOS/RHEL/AlmaLinux."; exit 1 ;;
    esac
}

configure_services() {
    if [[ "$VERSION" =~ ^9 ]]; then
        systemctl enable haveged && systemctl start haveged
        systemctl enable mariadb && systemctl start mariadb
        systemctl enable memcached && systemctl start memcached
        systemctl enable unbound && systemctl start unbound
        systemctl enable postfix && systemctl start postfix
    else
        printf "# chkconfig: - 54 25\n" > /etc/chkconfig.d/haveged
        chkconfig haveged on && service haveged start
        chkconfig mysqld on && service mysqld start
        chkconfig memcached on && service memcached start
        chkconfig unbound on && service unbound start
        chkconfig postfix on && service postfix start
    fi
}

configure_clamav() {
    useradd -r -d /var/lib/clamav -s /sbin/nologin clamav || true
    passwd -l clamav
    cat > /etc/freshclam.conf <<EOF
Bytecode yes
LogSyslog yes
SafeBrowsing yes
LogFileMaxSize 8M
DatabaseOwner clamav
CompressLocalDatabase no
DatabaseDirectory /var/lib/clamav
DatabaseMirror database.clamav.net
UpdateLogFile /var/log/clamav/freshclam.log
EOF
    cp /etc/cron.daily/freshclam /etc/cron.hourly/
    /etc/cron.hourly/freshclam
}

configure_mysql() {
    mysqladmin --force=true --user=root drop test 2>/dev/null || true
    mysqladmin --force=true --user=root create Magma
    local PROOT=$(openssl rand -base64 30 | sed 's/\//@-/g; s/+/_?/g')
    mysqladmin --user=root password "$PROOT"
    cat > /root/.my.cnf <<EOF
[mysql]
user=root
password=$PROOT
database=Magma
socket=/var/lib/mysql/mysql.sock
safe-updates

[mysqldump]
user=root
password=$PROOT
socket=/var/lib/mysql/mysql.sock

[mysqladmin]
user=root
password=$PROOT
socket=/var/lib/mysql/mysql.sock
EOF
    local PMAGMA=$(openssl rand -base64 30 | sed 's/\//@-/g; s/+/_?/g')
    mysql --user=root --password="$PROOT" -e "CREATE USER 'magma'@'localhost' IDENTIFIED BY '$PMAGMA'; GRANT ALL ON *.* TO 'magma'@'localhost'"
}

configure_dns() {
    hostnamectl set-hostname "mail.$DOMAIN"
    echo "Hostname set to mail.$DOMAIN"
    grep -q "$DOMAIN" /etc/hosts || echo "127.0.0.1   mail.$DOMAIN $DOMAIN localhost" >> /etc/hosts
    echo "/etc/hosts updated with $DOMAIN"
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
local-zone: "$DOMAIN" static
local-data: "mail.$DOMAIN A 127.0.0.1"
EOF
    echo "DNS resolver configured. Set MX records at registrar: MX 10 mail.$DOMAIN"
}

configure_system() {
    local TOTALMEM=$(free -k | grep -E "^Mem:" | awk '{print $2}')
    local HALFMEM=$(($TOTALMEM / 2))
    cat > /etc/security/limits.d/50-magmad.conf <<EOF
root     soft    stack      unlimited
root     hard    stack      unlimited
root     soft    memlock    $HALFMEM
root     hard    memlock    $HALFMEM
root     soft    nofile     262144
root     hard    nofile     262144
magma    soft    stack      unlimited
magma    hard    stack      unlimited
magma    soft    memlock    $HALFMEM
magma    hard    memlock    $HALFMEM
magma    soft    nofile     262144
magma    hard    nofile     262144
EOF
    chcon system_u:object_r:etc_t:s0 /etc/security/limits.d/50-magmad.conf
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    # Additional sysctl settings can be added here if needed
}

configure_postfix() {
    local TOTALMEM=$(free -m | grep -E "^Mem:" | awk '{print $2}')
    local QUARTERMEM=$(($TOTALMEM / 4))
    sed -i "s/CACHESIZE=\"[0-9]*\"/CACHESIZE=\"$QUARTERMEM\"/g" /etc/sysconfig/memcached
    echo "/var/log/maillog { daily rotate 7 missingok }" > /etc/logrotate.d/postfix
    chcon system_u:object_r:etc_t:s0 /etc/logrotate.d/postfix
    echo "smtp_header_checks = pcre:/etc/postfix/header_checks" >> /etc/postfix/main.cf
    echo "transport_maps = hash:/etc/postfix/transport" >> /etc/postfix/main.cf
    echo "myhostname = relay.$DOMAIN" >> /etc/postfix/main.cf
    echo "mynetwork = 127.0.0.0/8" >> /etc/postfix/main.cf
    echo "myorigin = $DOMAIN" >> /etc/postfix/main.cf
    sed -i "s/^smtp\([ ]*inet\)/127.0.0.1:2525\1/" /etc/postfix/master.cf
    echo "$DOMAIN smtp:[127.0.0.1]:25" >> /etc/postfix/transport
    echo "/^Received: from .*localhost.*\(Postfix\) with ESMTP.*$/ IGNORE" >> /etc/postfix/header_checks
    postmap /etc/postfix/header_checks
    postmap /etc/postfix/transport
}

install_magma() {
    git clone https://github.com/lavabit/magma magma-develop || { echo "Error: Git clone failed."; exit 1; }
    cd magma-develop
    dev/scripts/builders/build.lib.sh all || { echo "Error: Building libraries failed."; exit 1; }
    make all || { echo "Error: Compilation failed."; exit 1; }
    useradd -r -d /var/lib/magma -s /sbin/nologin magma || true
    passwd -l magma
    cp magmad magmad.so "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR/magmad" "$INSTALL_DIR/magmad.so"
    chcon system_u:object_r:bin_t:s0 "$INSTALL_DIR/magmad" "$INSTALL_DIR/magmad.so"
    mkdir -p /var/spool/magma/data /var/spool/magma/scan /var/log/magma /var/lib/magma/resources
    cp -R res/fonts res/pages res/templates /var/lib/magma/resources
    mkdir -p /var/lib/magma/storage/tanks /var/lib/magma/storage/local
    chown -R magma:magma /var/spool/magma /var/log/magma /var/lib/magma
    chcon -R system_u:object_r:var_spool_t:s0 /var/spool/magma
    chcon -R system_u:object_r:var_log_t:s0 /var/log/magma
    chcon -R system_u:object_r:var_lib_t:s0 /var/lib/magma
    local SELECTOR=$(echo "$DOMAIN" | awk -F'.' '{print $(NF-1)}')
    if [ -n "$DKIMKEY" ]; then
        cp "$DKIMKEY" "/etc/pki/dkim/private/$(basename "$DKIMKEY")"
    else
        openssl genrsa -out "/etc/pki/dkim/private/dkim.$DOMAIN.pem" 2048
        DKIMKEY="/etc/pki/dkim/private/dkim.$DOMAIN.pem"
    fi
    chmod 600 "$DKIMKEY"
    chcon unconfined_u:object_r:cert_t:s0 "$DKIMKEY"
    if [ -n "$TLSKEY" ]; then
        cp "$TLSKEY" "/etc/pki/tls/private/$(basename "$TLSKEY")"
    else
        openssl req -x509 -nodes -batch -days 1826 -newkey rsa:4096 -keyout "/etc/pki/tls/private/$DOMAIN.pem" -out "/etc/pki/tls/private/$DOMAIN.pem"
        TLSKEY="/etc/pki/tls/private/$DOMAIN.pem"
    fi
    chmod 600 "$TLSKEY"
    chcon unconfined_u:object_r:cert_t:s0 "$TLSKEY"
    local PMAGMA=$(openssl rand -base64 30 | sed 's/\//@-/g; s/+/_?/g')
    mysql --execute="CREATE USER 'magma'@'localhost' IDENTIFIED BY '$PMAGMA'; GRANT ALL ON *.* TO 'magma'@'localhost'"
    dev/scripts/database/schema.init.sh magma "$PMAGMA" Magma || { echo "Error: Database initialization failed."; exit 1; }
    local CPUCORES=$(nproc --all)
    local THREADCOUNT=$(($CPUCORES * 16))
    cat > /etc/magmad.config <<EOF
magma.iface.database.user = magma
magma.iface.database.host = localhost
magma.iface.database.schema = Magma
magma.iface.database.password = $PMAGMA
magma.iface.database.socket_path = /var/lib/mysql/mysql.sock
magma.iface.database.pool.connections = $CPUCORES
magma.relay[1].port = 2525
magma.relay[1].name = localhost
magma.iface.cache.host[1].port = 11211
magma.iface.cache.host[1].name = localhost
magma.library.file = $INSTALL_DIR/magmad.so
magma.system.worker_threads = $THREADCOUNT
magma.secure.memory.length = 268435456
EOF
    cp dev/install/magmad.sysv.init.sh /etc/init.d/magmad
    chmod 755 /etc/init.d/magmad
    chcon system_u:object_r:initrc_exec_t:s0 /etc/init.d/magmad
    if [[ "$VERSION" =~ ^9 ]]; then
        systemctl enable magmad && systemctl start magmad
    else
        chkconfig --add magmad
        chkconfig magmad on
        service magmad start
    fi
}

echo "Starting Magma installation..."
install_dependencies
configure_services
configure_clamav
configure_mysql
configure_dns
configure_system
configure_postfix
install_magma
echo "Installation complete! Magma is running."
exit 0
