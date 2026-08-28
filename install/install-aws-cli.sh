#!/bin/sh
# Install the AWS CLI v2.
#
# CHEESE needs it for two things: authenticating to the container registry
# (`cheese aws-auth`, `cheese update-images`) and downloading the indexed
# databases from S3 (`cheese download-dbs`). Both use the single access key
# DeepMedChem issues you — the CLI never needs its own `aws configure`.
#
# This uses AWS's official installer rather than `apt install awscli` on
# purpose: the distro package lags well behind and on some releases is still
# v1, which does not support the credential_source / assume-role configuration
# that `cheese download-dbs` relies on to refresh credentials during a
# multi-hour transfer.

set -e

if command -v aws >/dev/null 2>&1; then
  echo "AWS CLI already installed: $(aws --version 2>&1)"
  echo "Re-run with FORCE=1 to reinstall/update it."
  [ "${FORCE:-0}" = "1" ] || exit 0
fi

echo "Installing the AWS CLI v2 ..."

# unzip and curl are the installer's only prerequisites and are not guaranteed
# on a minimal server image.
if ! command -v unzip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "Installing curl and unzip first ..."
  sudo apt-get update
  sudo apt-get install -y curl unzip
fi

# The bundle is architecture-specific; uname -m gives the right one on both
# x86_64 and arm64 hosts.
arch="$(uname -m)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading the AWS CLI for ${arch} ..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscliv2.zip"
unzip -q "$tmp/awscliv2.zip" -d "$tmp"

# --update makes this idempotent: a re-run upgrades in place instead of failing
# with "found preexisting installation".
sudo "$tmp/aws/install" --update

echo
echo "Installed: $(aws --version 2>&1)"
echo "Next: run 'cheese aws-auth' to store the access key DeepMedChem issued you."
