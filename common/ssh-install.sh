#!/bin/sh
# Build-time: install dropbear (SSH server) on Alpine- or Debian/Ubuntu-based engine images.
set -e
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache dropbear
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dropbear-bin
    rm -rf /var/lib/apt/lists/*
else
    echo "ssh-install: unsupported base image (need apk or apt-get)" >&2
    exit 1
fi
mkdir -p /etc/dropbear
