#!/bin/bash
set -Eeuo pipefail

###############################################################################
# Server Hardening Script
#
# Supported operating systems:
#   - Ubuntu
#   - Debian
#
# Tasks:
#   1. Update system packages
#   2. Install and configure automatic updates
#   3. Create and configure a system user
#   4. Add user to sudo group
#   5. Configure SSH public key authentication
#   6. Install and configure OpenSSH Server
#   7. Disable root SSH access
#   8. Disable password authentication
#   9. Configure UFW firewall (IPv4 and IPv6)
#  10. Install and configure Fail2ban
#  11. Kernel Security Hardening (sysctl)
#  12. Install and Configure AppArmor
#
# Usage:
#   sudo ./hardening.sh USERNAME "PUBLIC_SSH_KEY" [SSH_PORT]
#
###############################################################################

# --- Configuration ---
SCRIPT_NAME="Server Hardening"
LOG_FILE="/var/log/hardening.log"
SSH_PORT="${3:-22}"
USERNAME="${1:-}"
PUBLIC_KEY="${2:-}"

# --- Helper functions ---
line() {
	width="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
	printf '%*s\n' "$width" '' | tr ' ' '='
}

# --- Logging functions ---
log() {
	echo -e "\n[INFO] $1"
}

success() {
	echo "[SUCCESS] $1"
}

warning() {
	echo "[WARNING] $1"
}

error() {
	echo "[ERROR] $1"
	exit 1
}

step() {
	echo
	line
	echo "[STEP] $1"
	line
}

# --- Error handling ---
trap 'echo "[ERROR] Script failed at line $LINENO. Check $LOG_FILE"' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Initial validation ---
if [[ "$EUID" -ne 0 ]]; then
	error "This script must be executed as root."
fi
if [[ -z "$USERNAME" ]]; then
	error "Usage: $0 USERNAME \"PUBLIC_SSH_KEY\" [SSH_PORT]"
fi
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
	error "Invalid username: $USERNAME"
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
	error "Invalid SSH port: $SSH_PORT"
fi
if [[ -z "$PUBLIC_KEY" ]]; then
	read -r -p "Enter the user's SSH public key: " PUBLIC_KEY
fi
if ! [[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]]; then
	error "Invalid or unsupported SSH public key format."
fi
if ! command -v apt-get >/dev/null 2>&1; then
	error "This script requires an APT-based distribution."
fi
if [[ ! -f /etc/os-release ]]; then
	error "Cannot identify operating system."
fi

source /etc/os-release
case "$ID" in
	ubuntu|debian)
		success "Supported operating system: $PRETTY_NAME"
		;;
	*)
		error "Unsupported operating system: $ID"
		;;
esac

# --- Update system ---
step "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
	sudo \
	unattended-upgrades \
	apt-listchanges \
	systemd \
	iproute2 \
	grep \
	sed \
	coreutils \
	util-linux \
	procps \
	ncurses-bin \
	python3 python3-pip \
	ufw \
	iptables
success "System packages updated successfully."

# --- Install automatic updates ---
step "Installing automatic security updates"
apt-get install -y unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "06:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
EOF

systemctl enable apt-daily.timer
systemctl enable apt-daily-upgrade.timer
success "Automatic updates configured successfully."

# --- Validate and create user ---
step "Checking system user"
if id "$USERNAME" >/dev/null 2>&1; then
	success "User $USERNAME already exists."
else
	log "Creating user: $USERNAME"
	useradd -m -s /bin/bash "$USERNAME"
	success "User $USERNAME created successfully."
fi

# --- Configure sudo privileges ---
step "Checking sudo group membership"
if ! getent group sudo >/dev/null; then
	error "The sudo group does not exist."
fi
if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo; then
	success "User $USERNAME already belongs to sudo group."
else
	usermod -aG sudo "$USERNAME"
	success "User $USERNAME added to sudo group."
fi

# --- Configure SSH public key authentication ---
step "Configuring SSH public key authentication"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
	error "Cannot determine home directory for $USERNAME."
fi

SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown "$USERNAME:$USERNAME" "$AUTHORIZED_KEYS"
if ! grep -qxF "$PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
	echo "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
	success "Public key added to authorized_keys."
else
	success "Public key already configured."
fi

# --- Install OpenSSH Server ---
step "Installing OpenSSH Server"
apt-get install -y openssh-server
systemctl enable ssh
success "OpenSSH Server installed and enabled."

# --- Configure SSH security ---
step "Hardening SSH configuration"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_HARDENING="$SSHD_CONFIG_DIR/00-hardening.conf"
mkdir -p "$SSHD_CONFIG_DIR"

cat > "$SSHD_HARDENING" <<EOF
# Server Hardening Configuration
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
UsePAM yes
AllowAgentForwarding no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF

chmod 644 "$SSHD_HARDENING"
log "Validating SSH configuration"
sshd -t
success "SSH configuration syntax is valid."
systemctl reload ssh
success "SSH security configuration applied."

# --- Install and configure UFW ---
step "Installing UFW firewall"
apt-get install -y ufw

# --- Enable IPv6 support ---
log "Enabling IPv6 support in UFW"
if grep -q '^IPV6=' /etc/default/ufw; then
	sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
else
	echo 'IPV6=yes' >> /etc/default/ufw
fi

# --- Configure firewall policies ---
log "Configuring firewall default policies"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# --- Allow SSH access over IPv4 and IPv6 ---
log "Allowing SSH port $SSH_PORT over IPv4 and IPv6"
ufw allow "$SSH_PORT/tcp" comment 'SSH Access'

# --- Enable firewall ---
log "Enabling UFW firewall"
ufw --force enable
ufw status verbose
success "UFW configured successfully."

# --- Install and configure Fail2ban ---
step "Installing Fail2ban"
apt-get install -y fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
success "Fail2ban installed and configured successfully."

# --- Kernel Security Hardening ---
step "Starting kernel security configuration."
CONFIG_FILE="/etc/sysctl.d/99-security-hardening.conf"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
if [[ -f "$CONFIG_FILE" ]]; then
	cp -a "$CONFIG_FILE" "${CONFIG_FILE}.backup.${TIMESTAMP}"
	success "Previous sysctl configuration backed up."
fi

cat > "$CONFIG_FILE" <<EOF
# Kernel information protection
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# Process security
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1

# TCP SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# IPv6 security
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable IP forwarding
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
EOF

chmod 644 "$CONFIG_FILE"
log "Applying sysctl configuration."
if sysctl --load="$CONFIG_FILE"; then
	success "Kernel security parameters applied."
else
	error "Failed to apply sysctl configuration."
	exit 1
fi

# --- Install AppArmor ---
step "Installing AppArmor packages."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
	apparmor \
	apparmor-utils
success "AppArmor packages installed."

log "Enabling AppArmor service."
if systemctl enable apparmor.service; then
	success "AppArmor service enabled."
else
	error "Could not enable AppArmor service."
	exit 1
fi
if systemctl start apparmor.service; then
	success "AppArmor service started."
else
	error "Could not start AppArmor service."
	exit 1
fi

# --- Final validation ---
step "Performing final validation"
log "Checking user configuration"
id "$USERNAME"
log "Checking sudo membership"
id -nG "$USERNAME"

log "Checking SSH service"
systemctl is-active --quiet ssh || error "SSH service is not running."

log "Checking Fail2ban service"
systemctl is-active --quiet fail2ban || error "Fail2ban service is not running."

log "Checking firewall status"
ufw status

log "Checking SSH effective configuration"
sshd -T | grep -E \
'^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods) '

log "Checking AppArmor status."
if command -v aa-status >/dev/null 2>&1; then
	success "aa-status command found."
else
	error "aa-status command not found."
fi

log "Checking AppArmor kernel integration."
if [[ -r /sys/kernel/security/lsm ]]; then
	LSM=$(cat /sys/kernel/security/lsm)
	log "Active Linux Security Modules: $LSM"
	if [[ ",$LSM," == *",apparmor,"* ]]; then
		success "AppArmor is enabled in the kernel."
	else
		error "AppArmor is not listed in active kernel security modules."
		log "Check kernel boot parameters and reboot configuration."
	fi
else
	error "Cannot read active LSM configuration."
fi

# --- Completion ---
echo
line
echo " SERVER HARDENING COMPLETED SUCCESSFULLY"
line
echo
echo "Configured user:       $USERNAME"
echo "SSH port:              $SSH_PORT"
echo "SSH authentication:    Public Key Only"
echo "Root SSH access:       Disabled"
echo "Password SSH access:   Disabled"
echo "Firewall:              UFW Enabled"
echo "IPv4 support:          Enabled"
echo "IPv6 support:          Enabled"
echo "Automatic updates:     Enabled"
echo "Fail2ban:              Enabled"
echo "IP forwarding:         Disabled"
echo
echo "Log file: $LOG_FILE"
echo
success "All hardening tasks completed successfully."
