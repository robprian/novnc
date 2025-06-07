#!/bin/bash

# Script to automatically install and configure VNC Server and NoVNC as services using LXDE
# Author: Claude
# Date: May 22, 2025

set -e  # Exit on error

# Function to display messages
print_message() {
    echo "======================================================="
    echo "$1"
    echo "======================================================="
}

# Function to get public IP
get_public_ip() {
    # Try multiple methods to get public IP
    PUBLIC_IP=$(curl -s --max-time 3 https://ifconfig.me/ip || \
                curl -s --max-time 3 https://api.ipify.org || \
                curl -s --max-time 3 https://ipinfo.io/ip || \
                hostname -I | awk '{print $1}')
    
    # If we couldn't get public IP, fall back to local IP
    if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
        PUBLIC_IP=$(hostname -I | awk '{print $1}')
    fi
    
    echo "$PUBLIC_IP"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo privileges."
    exit 1
fi

# Get the username for whom to install the VNC server
if [ -z "$SUDO_USER" ]; then
    read -p "Enter the username for VNC service: " VNC_USER
else
    VNC_USER=$SUDO_USER
fi

# Verify that the user exists
if ! id "$VNC_USER" &>/dev/null; then
    echo "User $VNC_USER does not exist. Please create this user first."
    exit 1
fi

VNC_USER_HOME=$(eval echo ~$VNC_USER)
VNC_PORT=5901
NOVNC_PORT=6080
DISPLAY_NUMBER=1

# Detect package manager
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
    PACKAGES="tigervnc-standalone-server tigervnc-common novnc websockify git python3 python3-pip net-tools lxde-core lxterminal curl"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf check-update"
    PKG_INSTALL="dnf install -y"
    PACKAGES="tigervnc-server novnc websockify git python3 python3-pip lxde lxterminal curl"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum check-update"
    PKG_INSTALL="yum install -y"
    PACKAGES="tigervnc-server novnc websockify git python3 python3-pip lxde lxterminal curl"
else
    echo "Unsupported package manager. This script supports apt, dnf, and yum."
    exit 1
fi

# Update package repositories
print_message "Updating package repositories..."
$PKG_UPDATE

# Check if VNC server is already installed
if ! command -v vncserver &> /dev/null; then
    print_message "Installing VNC server packages..."
    $PKG_INSTALL $PACKAGES
else
    print_message "VNC server is already installed."
fi

# Check if NoVNC is installed
if [ ! -d "/usr/share/novnc" ] && [ ! -d "/opt/novnc" ]; then
    print_message "Installing NoVNC..."

    # If NoVNC wasn't installed through package manager, get it from GitHub
    if [ ! -d "/usr/share/novnc" ]; then
        print_message "Installing NoVNC from GitHub..."
        if [ ! -d "/opt/novnc" ]; then
            git clone https://github.com/novnc/noVNC.git /opt/novnc
        fi

        if [ ! -d "/opt/websockify" ]; then
            git clone https://github.com/novnc/websockify.git /opt/websockify
        fi
    fi
else
    print_message "NoVNC is already installed."
fi

# Set up VNC password for the user
print_message "Setting up VNC password..."
if [ ! -d "$VNC_USER_HOME/.vnc" ]; then
    mkdir -p "$VNC_USER_HOME/.vnc"
    chown $VNC_USER:$VNC_USER "$VNC_USER_HOME/.vnc"
fi

# Only create password if it doesn't exist
if [ ! -f "$VNC_USER_HOME/.vnc/passwd" ]; then
    print_message "Please enter a VNC password for $VNC_USER"
    sudo -u $VNC_USER vncpasswd
fi

# Create xstartup file for LXDE
print_message "Creating LXDE xstartup configuration..."
cat > "$VNC_USER_HOME/.vnc/xstartup" << 'EOF'
#!/bin/bash

# Clean up environment variables
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Set display manually to :1 (karena kamu pakai :1)
export DISPLAY=:1

# Start LXDE
if command -v startlxde &> /dev/null; then
    exec startlxde
else
    exec lxsession
fi

EOF
chmod +x "$VNC_USER_HOME/.vnc/xstartup"
chown $VNC_USER:$VNC_USER "$VNC_USER_HOME/.vnc/xstartup"

# Function to completely clean up X server and VNC processes
clean_x_processes() {
    print_message "Performing thorough cleanup of X and VNC processes..."

    # Kill any running VNC server or X processes
    pkill -9 -f Xtigervnc || true
    pkill -9 -f Xvnc || true
    pkill -9 -f "vnc.*:$DISPLAY_NUMBER" || true
    pkill -9 -f "X.*:$DISPLAY_NUMBER" || true
    pkill -9 -f "/usr/bin/X" || true

    # Remove lock files
    rm -f /tmp/.X$DISPLAY_NUMBER-lock || true
    rm -f /tmp/.X11-unix/X$DISPLAY_NUMBER || true

    # Clean up user's VNC files
    rm -f $VNC_USER_HOME/.vnc/*:$DISPLAY_NUMBER.pid || true
    rm -f $VNC_USER_HOME/.vnc/*.log || true

    # Give processes time to fully terminate
    sleep 2
}

# Perform thorough cleanup before starting
clean_x_processes

# Create systemd service for VNC Server
print_message "Creating VNC Server systemd service..."
cat > /etc/systemd/system/vncserver@.service << EOF
[Unit]
Description=Remote desktop service (VNC)
After=network.target

[Service]
Type=simple
User=$VNC_USER
Group=$VNC_USER
WorkingDirectory=$VNC_USER_HOME
PAMName=login

# Skip aggressive pre-start cleanup
ExecStartPre=/bin/sh -c 'rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i'
ExecStartPre=/bin/sh -c 'rm -f $VNC_USER_HOME/.vnc/*:%i.pid $VNC_USER_HOME/.vnc/*.log'
ExecStartPre=/bin/sleep 1

# Start command - running in foreground
ExecStart=/usr/bin/vncserver :%i -geometry 1366x768 -depth 24 -localhost no -fg

# Give more time for startup
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target

EOF

# Create systemd service for NoVNC
print_message "Creating NoVNC systemd service..."

# Determine NoVNC path
if [ -d "/usr/share/novnc" ]; then
    NOVNC_PATH="/usr/share/novnc"
elif [ -d "/opt/novnc" ]; then
    NOVNC_PATH="/opt/novnc"
else
    echo "NoVNC installation not found. Exiting."
    exit 1
fi

# Determine websockify path
if [ -f "/usr/bin/websockify" ]; then
    WEBSOCKIFY_PATH="/usr/bin/websockify"
elif [ -d "/opt/websockify" ]; then
    WEBSOCKIFY_PATH="/opt/websockify/run"
else
    echo "Websockify not found. Exiting."
    exit 1
fi

cat > /etc/systemd/system/novnc.service << EOF
[Unit]
Description=NoVNC Service
After=network.target vncserver@$DISPLAY_NUMBER.service
Requires=vncserver@$DISPLAY_NUMBER.service

[Service]
Type=simple
User=root
ExecStart=$WEBSOCKIFY_PATH --web=$NOVNC_PATH $NOVNC_PORT localhost:$VNC_PORT
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Add a troubleshooting script
print_message "Creating VNC troubleshooting script..."
cat > /usr/local/bin/fix-vnc.sh << 'EOF'
#!/bin/bash

# Fix script for VNC Server issues
echo "===== VNC Server Troubleshooting ====="
echo "Stopping services..."
systemctl stop novnc.service
systemctl stop vncserver@1.service

echo "Killing all X and VNC processes..."
pkill -9 -f Xtigervnc || true
pkill -9 -f Xvnc || true
pkill -9 -f "vnc.*:1" || true
pkill -9 -f "X.*:1" || true
pkill -9 -f "/usr/bin/X" || true

echo "Removing lock files..."
rm -f /tmp/.X1-lock || true
rm -f /tmp/.X11-unix/X1 || true

echo "Cleaning up VNC user files..."
VNC_USER=$(systemctl show vncserver@1.service | grep User | cut -d= -f2)
if [ -n "$VNC_USER" ]; then
  VNC_HOME=$(eval echo ~$VNC_USER)
  rm -f $VNC_HOME/.vnc/*:1.pid || true
  rm -f $VNC_HOME/.vnc/*.log || true
fi

echo "Waiting for processes to terminate..."
sleep 3

echo "Starting services again..."
systemctl start vncserver@1.service
systemctl start novnc.service

echo "Done! Check status with: systemctl status vncserver@1.service"
EOF

chmod +x /usr/local/bin/fix-vnc.sh

print_message "Enabling and starting the services..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable vncserver@$DISPLAY_NUMBER.service
systemctl enable novnc.service
systemctl start vncserver@$DISPLAY_NUMBER.service
systemctl start novnc.service

# Set up firewall rules if firewalld or ufw is present
if command -v firewall-cmd &> /dev/null; then
    print_message "Configuring firewall with firewalld..."
    firewall-cmd --permanent --add-port=$VNC_PORT/tcp
    firewall-cmd --permanent --add-port=$NOVNC_PORT/tcp
    firewall-cmd --reload
elif command -v ufw &> /dev/null; then
    print_message "Configuring firewall with ufw..."
    ufw allow $VNC_PORT/tcp
    ufw allow $NOVNC_PORT/tcp
fi

# Get server IP for information
PUBLIC_IP=$(get_public_ip)

print_message "Installation complete!"
echo "VNC Server is running on port $VNC_PORT"
echo "NoVNC is accessible at http://$PUBLIC_IP:$NOVNC_PORT/vnc.html"
echo "Connect to VNC using the password you provided"
echo ""
echo "To manage the services:"
echo "  - Start VNC: systemctl start vncserver@$DISPLAY_NUMBER.service"
echo "  - Stop VNC: systemctl stop vncserver@$DISPLAY_NUMBER.service"
echo "  - Start NoVNC: systemctl start novnc.service"
echo "  - Stop NoVNC: systemctl stop novnc.service"
echo "  - Check status: systemctl status vncserver@$DISPLAY_NUMBER.service novnc.service"
