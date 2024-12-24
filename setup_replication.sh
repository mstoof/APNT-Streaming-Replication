#!/bin/bash

# PostgreSQL Streaming Replication Setup Script
# Primary: 192.168.168.80 (PostgreSQL 13.2)
# Standby: 192.168.168.14 (PostgreSQL 13.18.1)

# Function to run PostgreSQL commands safely
psql_command() {
    # Set proper locale and move to postgres home directory
    export LC_ALL=C
    cd /var/lib/postgresql
    sudo -u postgres psql -c "$1"
}

# =================== PRIMARY SERVER CONFIGURATION ===================

primary_setup() {
    echo "Configuring primary server..."

    # Set locale to avoid warnings
    export LC_ALL=C

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)"
        exit 1
    fi

    # Backup postgresql.conf if it hasn't been backed up
    if [ ! -f /etc/postgresql/13/main/postgresql.conf.backup ]; then
        cp /etc/postgresql/13/main/postgresql.conf /etc/postgresql/13/main/postgresql.conf.backup
    fi

    # Configure postgresql.conf
    echo "Checking and updating postgresql.conf..."
    if ! grep -q "wal_level = replica" /etc/postgresql/13/main/postgresql.conf; then
        cat >> /etc/postgresql/13/main/postgresql.conf << EOF
# Replication Configuration
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
EOF
        echo "Added replication settings to postgresql.conf"
    else
        echo "Replication settings already exist in postgresql.conf"
    fi

    # Configure pg_hba.conf to allow replication
    echo "Checking and updating pg_hba.conf..."
    if ! grep -q "host.*replication.*replicator" /etc/postgresql/13/main/pg_hba.conf; then
        cat >> /etc/postgresql/13/main/pg_hba.conf << EOF
# Replication configuration
host    replication     replicator      192.168.168.14/32        md5
EOF
        echo "Added replication access to pg_hba.conf"
    else
        echo "Replication access already configured in pg_hba.conf"
    fi

    # Create replication user if it doesn't exist
    echo "Checking replication user..."
    if ! cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='replicator'" | grep -q 1; then
        cd /tmp && sudo -u postgres psql -c "CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator';"
        echo "Created replication user"
    else
        echo "Replication user already exists"
    fi

    echo "Restarting PostgreSQL..."
    systemctl restart postgresql

    echo "Primary server configuration completed"
}

# =================== STANDBY SERVER CONFIGURATION ===================

standby_setup() {
    echo "Configuring standby server..."

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)"
        exit 1
    fi

    # Stop PostgreSQL on standby
    systemctl stop postgresql

    # Backup existing data directory
    if [ -d /var/lib/postgresql/13/main ]; then
        echo "Backing up existing data directory..."
        mv /var/lib/postgresql/13/main "/var/lib/postgresql/13/main_backup_$(date +%Y%m%d_%H%M%S)"
    fi

    # Create new data directory
    mkdir -p /var/lib/postgresql/13/main
    chown postgres:postgres /var/lib/postgresql/13/main

    echo "Taking base backup from primary..."
    # Take base backup from primary
    sudo -u postgres PGPASSWORD="your_secure_password" pg_basebackup -h 192.168.168.80 -U replicator \
        -D /var/lib/postgresql/13/main -P -v -R \
        -C -S pgstandby1 -X stream

    if [ $? -ne 0 ]; then
        echo "Error: pg_basebackup failed"
        exit 1
    fi

    echo "Configuring recovery settings..."
    # Configure recovery settings
    cat >> /var/lib/postgresql/13/main/postgresql.conf << EOF
# Recovery Configuration
primary_conninfo = 'host=192.168.168.80 port=5432 user=replicator password=your_secure_password application_name=standby1'
promote_trigger_file = '/tmp/promote_trigger'
hot_standby = on
EOF

    # Set proper permissions
    chown postgres:postgres /var/lib/postgresql/13/main/postgresql.conf

    echo "Starting PostgreSQL..."
    systemctl start postgresql

    echo "Standby server configuration completed"
}

# =================== VERIFICATION ===================

check_replication_status() {
    echo "Checking replication status..."

    if [ "$1" = "primary" ]; then
        sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
    else
        sudo -u postgres psql -x -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_delay;"
    fi
}

# =================== USAGE ===================

case "$1" in
    "primary")
        primary_setup
        [ "$2" = "check" ] && check_replication_status "primary"
        ;;
    "standby")
        standby_setup
        [ "$2" = "check" ] && check_replication_status "standby"
        ;;
    *)
        echo "Usage: $0 {primary|standby} [check]"
        exit 1
        ;;
esac

exit 0