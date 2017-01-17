#!/bin/bash
# vim: sw=4 ts=4 et

# Terraform Bootstrap!
#
# This script bootstraps Terraform.  What that means is...
# 1) We download the specified version of Terraform, if needed.
# 2) We create a systemd unit file for the Terraform worker, 

# Send output to a log file
echo 'Starting Terraform Bootstrap'

# Load config
echo ; echo 'Loading config'
. terraform_config.sh

GPG_VERIFICATION_NEEDED=0
SHA_VERIFICATION_NEEDED=0
SERVICE_RESTART_NEEDED=0
REBOOT_NEEDED=0

#
# GPG SETUP
#

# Fetch the GPG keys
echo ; echo "Fetching/Updating keys ${TERRAFORM_GPG_KEY} and ${SERVICE_GPG_KEY}"
gpg --keyserver keys.gnupg.net --recv-key ${TERRAFORM_GPG_KEY} ${SERVICE_GPG_KEY}

# Mark keys as trusted
grep "trusted-key ${TERRAFORM_GPG_KEY}" ~/.gnupg/gpg.conf >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo ; echo "Marking key ${TERRAFORM_GPG_KEY} as trusted"
    echo "trusted-key ${TERRAFORM_GPG_KEY}" >> ~/.gnupg/gpg.conf
    gpg --update-trustdb
fi
grep "trusted-key ${SERVICE_GPG_KEY}" ~/.gnupg/gpg.conf >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo ; echo "Marking key ${SERVICE_GPG_KEY} as trusted"
    echo "trusted-key ${SERVICE_GPG_KEY}" >> ~/.gnupg/gpg.conf
    gpg --update-trustdb
fi

#
# DIRECTORY SETUP
#

# Make directories to hold Terraform stuff
if [ ! -d /mnt/efs/terraform ]; then
    echo ; echo 'Creating /mnt/efs/terraform'
    mkdir /mnt/efs/terraform
fi
if [ ! -d /mnt/efs/terraform/app ]; then
    echo ; echo 'Creating /mnt/efs/terraform/app'
    mkdir /mnt/efs/terraform/app
fi

# Make directories to hold the worker
if [ ! -d /mnt/efs/terraform/worker ]; then
    echo ; echo 'Creating /mnt/efs/terraform/worker'
    mkdir /mnt/efs/terraform/worker
fi

#
# FETCH TERRAFORM FILES
#

# Download Terraform files, if needed.
# If we download a Terraform .zip, then we do SHA verification.
# If we download a SHA or sig file, then we do GPG and SHA verification.
cd /mnt/efs/terraform/app

if [ ! -d $TERRAFORM_VERSION ]; then
    echo ; echo "Creating /mnt/efs/terraform/app/${TERRAFORM_VERSION}"
    mkdir ${TERRAFORM_VERSION}
fi
cd ${TERRAFORM_VERSION}

if [ ! -f $TERRAFORM_SHA_FILE ]; then
    echo ; echo "Fetching ${TERRAFORM_URL_BASE}${TERRAFORM_SHA_FILE}"
    GPG_VERIFICATION_NEEDED=1
    SHA_VERIFICATION_NEEDED=1
    curl -O "${TERRAFORM_URL_BASE}${TERRAFORM_SHA_FILE}"
fi

if [ ! -f $TERRAFORM_SHA_SIG ]; then
    echo ; echo "Fetching ${TERRAFORM_URL_BASE}${TERRAFORM_SHA_SIG}"
    GPG_VERIFICATION_NEEDED=1
    SHA_VERIFICATION_NEEDED=1
    curl -O "${TERRAFORM_URL_BASE}${TERRAFORM_SHA_SIG}"
fi

if [ $GPG_VERIFICATION_NEEDED -eq 1 ]; then
    echo ; echo "Verifying ${TERRAFORM_SHA_FILE}"
    gpg ${TERRAFORM_SHA_SIG} ${TERRAFORM_SHA_FILE}
    if [ $? -ne 0 ]; then
        echo 'WARNING!  GPG signature failed verification!  Exiting now.'
        exit 1
    fi
fi

if [ ! -f $TERRAFORM_ZIP ]; then
    echo ; echo "Fetching ${TERRAFORM_ZIP}"
    SHA_VERIFICATION_NEEDED=1
    curl -O "${TERRAFORM_URL_BASE}${TERRAFORM_ZIP}"
fi

if [ $SHA_VERIFICATION_NEEDED -eq 1 ]; then
    echo ; echo "Verifying ${TERRAFORM_ZIP}"
    sha256sum --check --ignore-missing ${TERRAFORM_SHA_FILE}
    if [ $? -ne 0 ]; then
        echo 'WARNING!  SHA check failed!  Exiting now.'
        exit 1
    fi
fi

# Check if our terraform symlink needs to change.
# If we need to change our symlink, then stop the kathputli-terraform service, 
# and update the symlink.
# NOTE: We don't restart the service, because it's assumed that the system will 
# be rebooted after running this script.
SYMLINK_PATH=$(readlink /mnt/efs/terraform/app/terraform)

if [ "${SYMLINK_PATH}" != "/mnt/efs/terraform/app/${TERRAFORM_VERSION}/terraform" ]; then
    REBOOT_NEEDED=1
    echo ; echo "Updating symlink /mnt/efs/terraform/app/terraform to point to /mnt/efs/terraform/app/${TERRAFORM_VERSION}/terraform"
    systemctl stop kathputli-terraform
    rm -f /mnt/efs/terraform/app/terraform
    ln -s /mnt/efs/terraform/app/${TERRAFORM_VERSION}/terraform /mnt/efs/terraform/app/terraform
fi

#
# FETCH WORKER FILES
#

# If the worker doesn't exist, then get it!
cd /mnt/efs/terraform/worker

if [ ! -d ${SERVICE_GIT_TAG} ]; then
    echo ; echo "Worker directory /mnt/efs/terrawork/worker/${SERVICE_GIT_TAG} missing.  Fetching and installing!"
    REBOOT_NEEDED=1

    echo ; echo "Cloning worker repo ${SERVICE_GIT_REPO}"
    git clone ${SERVICE_GIT_REPO} ${SERVICE_GIT_TAG}
    cd ${SERVICE_GIT_TAG}

    echo ; echo "Verifying and checking out tag ${SERVICE_GIT_TAG}"
    git tag -v ${SERVICE_GIT_TAG}
    if [ $? -ne 0 ]; then
        echo ; echo "WARNING!  Tag ${SERVICE_GIT_TAG} failed to verify.  Exiting now."
        exit 1
    fi
    git checkout ${SERVICE_GIT_TAG}

    echo ; echo "Building and installing worker"
    #./setup.py
fi

#
# SYSTEMD SERVICE SETUP
#

# Check if we need to create the systemd service file
if [ ! -f /lib/systemd/system/kathputli-terraform.service ]; then
    REBOOT_NEEDED=1
    echo ; echo 'Creating and enabling systemd unit file for kathputli-terraform'
    cat - >/lib/systemd/system/kathputli-terraform.service <<EOF
[Unit]
Description=Kathputli Terraform image builder
Documentation=https://github.com/akkornel/kathputli-terraform
Requires=network.target
RequiresMountsFor=/mnt/efs
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/kathputli-terraform
Restart=on-failure
WatchdogSec=30
NotifyAccess=main
EOF
    systemctl daemon-reload
    systemctl enable kathputli-terraform
fi

#
# ALL DONE!
#

# Finally, if we did something that requires a reboot, let the user know!
if [ $REBOOT_NEEDED -eq 1 ]; then
    echo
    echo 'WARNING!  We have made some changes that affect the kathputli-terraform service.'
    echo 'We have stopped the service (if it was running), but have not restarted it.'
    echo 'Please reboot this system, via `shutdown -r now` or `reboot`.'
    echo 'If this is running via bootstrap.sh, then the reboot will happen automatically.'
fi

exit 0
