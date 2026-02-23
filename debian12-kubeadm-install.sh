#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive

function disable_swap() {
  # Disable swap partitions and comment them out in fstab
  echo "Scanning /etc/fstab for swap entries..."

  # Create backup of fstab
  cp /etc/fstab /etc/fstab.bkp

  # Find and list swap entries
  echo "Found swap entries:"
  grep -E '^[^#].+\sswap\s' /etc/fstab

  # Turn off all active swap
  echo "Turning off all swap..."
  swapoff -a

  # Comment out swap entries in fstab
  echo "Commenting out swap entries in /etc/fstab..."
  sed -i 's/\(.*\) none swap sw\(.*\)/# \1 none swap sw\2/' /etc/fstab

  echo "Swap has been disabled and entries commented in /etc/fstab"
  echo "A backup of original fstab was created at /etc/fstab.bak"
}

function fix_sysctl() {
  
  # sysctl params required by setup, params persist across reboots
  echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/k8s.conf

  # Apply sysctl params without reboot
  sysctl --system

  if test $(sysctl net.ipv4.ip_forward) -ne 1; then
    echo "Failed to set net.ipv4.ip_forward to 1"
    exit 1
  fi
}

function install_containerd() {
  apt update
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt remove $pkg; done

  # Add Docker's official GPG key:
  apt update
  apt install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update

  apt install -y containerd.io

  containerd config default |tee /etc/containerd/config.toml

  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl restart containerd
}

function install_kubeadm() {
  apt update
  apt install -y apt-transport-https ca-certificates curl
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
  apt update
  apt install -y kubelet kubeadm kubectl open-iscsi
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet
}

disable_swap
fix_sysctl
install_containerd
install_kubeadm
