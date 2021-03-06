#!/bin/bash

# This script installs the Prometheus' Bind Exporter in a Linux-AMD64 machine.
#
# The script creates a new user for the Bind Exporter, and it's installed as a
# service in the systemd.
set -e

# --- Constants ---
REPO="https://api.github.com/repos/prometheus-community/bind_exporter/releases/latest"
INSTALL_DIR="/opt"
USERNAME="bind_exporter"

# --- Progress functions ---
function begin {
	echo -n "$1... "
}
function end {
	echo "done."
}

# --- Validate User ---
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root"
	exit 1
fi

# --- Download dependencies ---
begin "Downloading dependencies"
apt-get -qq update
apt-get -qq install -y curl tar > /dev/null
end

# --- Download latest Node Exporter Release ---
begin "Downlading Bind Exporter"
json=$(curl -s $REPO | grep bind_exporter-*.*.linux-amd64.tar.gz)
name=$(echo $json | grep -Po '"name": "\K.*?(?=")')
url=$(echo $json | grep -Po '"browser_download_url": "\K.*?(?=")')
dir=${name::-7}
pushd /tmp > /dev/null
curl -sL $url --output $name
end

# --- Install Node Expoter ---
begin "Installing Bind Exporter"
useradd --system --no-create-home --shell=/sbin/nologin $USERNAME
mkdir -p $INSTALL_DIR/bind_exporter
tar -xf $name
rm $name
chown -R root:root $dir
chmod -R 755 $dir
mv $dir bind_exporter
mv bind_exporter $INSTALL_DIR
popd > /dev/null
end

# --- Configure Service ---
begin "Configuring the Service"
echo '[Unit]
Description=Bind Exporter
Documentation=https://github.com/prometheus-community/bind_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=bind_exporter
EnvironmentFile=/etc/bind_exporter/bind_exporter.conf
ExecStart=/opt/bind_exporter/bind_exporter $OPTIONS
Restart=always

[Install]
WantedBy=multi-user.target' >  /etc/systemd/system/bind_exporter.service

mkdir -p /etc/bind_exporter
echo 'OPTIONS=""' >> /etc/bind_exporter/bind_exporter.conf
end

# --- Start the Service ---
begin "Starting the Service"
systemctl daemon-reload
systemctl start bind_exporter
systemctl enable bind_exporter > /dev/null 2>&1
end
echo "Installed: $name"
