#!/bin/bash

# This script installs the Prometheus' Node Exporter in a Linux-AMD64 machine.
#
# The script creates a new user for the Node Exporter, and it's installed as a
# service in the systemd.
set -e

# --- Constants ---
REPO="https://api.github.com/repos/prometheus/node_exporter/releases/latest"
INSTALL_DIR="/opt"
USERNAME="node_exporter"

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
begin "Downlading Node Exporter"
json=$(curl -s $REPO | grep node_exporter-*.*.linux-amd64.tar.gz)
name=$(echo $json | grep -Po '"name": "\K.*?(?=")')
url=$(echo $json | grep -Po '"browser_download_url": "\K.*?(?=")')
dir=${name::-7}
pushd /tmp
curl -sL $url --output $name
end

# --- Install Node Expoter ---
begin "Installing Node Exporter"
useradd --system --no-create-home --shell=/sbin/nologin $USERNAME
mkdir -p $INSTALL_DIR/node_exporter
tar -xf $name
rm $name
chown -R root:root $dir
chmod -R 755 $dir
mv $dir node_exporter
mv node_exporter $INSTALL_DIR
popd
end

# --- Configure Service ---
begin "Configuring the Service"
echo '[Unit]
Description=Node Exporter

[Service]
User=node_exporter
EnvironmentFile=/etc/node_exporter/node_exporter.conf
ExecStart=/opt/node_exporter/node_exporter $OPTIONS

[Install]
WantedBy=multi-user.target' >  /etc/systemd/system/node_exporter.service

mkdir -p /etc/node_exporter
echo 'OPTIONS="--log.level=error"' >> /etc/node_exporter/node_exporter.conf
end

# --- Start the Service ---
begin "Starting the Service"
systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter > /dev/null 2>&1
end
echo "Installed: $name"
