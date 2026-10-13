#!/usr/bin/env bash
# Runs as root inside the Packer build VM (a clone of the seed template).
set -euo pipefail

: "${BUILD_TIMESTAMP:?BUILD_TIMESTAMP must be set}"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# The seed's cloud-init installs qemu-guest-agent; let it finish first.
cloud-init status --wait || true

apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" install curl jq ca-certificates qemu-guest-agent
systemctl enable qemu-guest-agent

# The app's service user and directories are created by Ansible at deploy time.
printf '%s\n' "${BUILD_TIMESTAMP}" > /etc/vm-demo-base
chmod 0644 /etc/vm-demo-base

# Generalize: every clone re-runs cloud-init, gets a fresh machine-id
# (and so its own DHCP client ID) and fresh SSH host keys.
apt-get "${APT_OPTS[@]}" autoremove --purge
apt-get clean
cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id
if [ -d /var/lib/dbus ]; then
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi
rm -f /etc/ssh/ssh_host_*
sync
