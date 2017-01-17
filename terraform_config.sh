#!/bin/bash
# vim: sw=4 ts=4 et

# This file contains veriables controlling which Terraform files we need to
# fetch.  These variables have been split out into a separate file because it's
# easier to track changes that way!  Ideally, the main terraform.sh script
# should not change that much between Terraform releases.

# First up, variables related to the Terraform version we're going to use.

# TERRAFORM_VERSION is the version number of Terraform that we are using right
# now.
TERRAFORM_VERSION='0.8.4'

# TERRAFORM_URL_BASE is the path to the directory where the Terraform files may
# be found.  The URL _must_ end with a forward slash (a / character).
TERRAFORM_URL_BASE="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/"

# TERRAFORM_ZIP is the name of the zip file which contains the Terraform
# executable.  This path is relative to $TERRAFORM_URL_BASE.
TERRAFORM_ZIP="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"

# TERRAFORM_SHA_FILE is the name of the file which contains the SHA-256
# checksums.  This path is relative to $TERRAFORM_URL_BASE.
TERRAFORM_SHA_FILE="terraform_${TERRAFORM_VERSION}_SHA256SUMS"

# TERRAFORM_SHA_SIG is the name of the file which contains the GPG signature of
# the checksums file.  This path is relative to $TERRAFORM_URL_BASE.
TERRAFORM_SHA_SIG="terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"

# TERRAFORM_GPG_KEY is the long key ID (that is, the last 16 hex characters)
# for the GPG key that Hachicorp uses to sign the checkum file.  This key must
# be present in the keys.gnupg.net key server.
TERRAFORM_GPG_KEY='51852D87348FFC4C'

# Next up, variables related to the Terraform worker!

# SERVICE_GIT_REPO is the Git repository where we obtain 
SERVICE_GIT_REPO='https://github.com/kathputli/worker-terraform.git'

# SERVICE_GIT_TAG is the name of the Git tag that we will be checking out and
# verifying.
SERVICE_GIT_TAG='production'

# SERVICE_GPG_KEY is the long key ID (that is, the last 16 hex characters)
# for the GPG key that we use to verify the Git tag.  This key must be present
# in the keys.gnupg.net key server.
SERVICE_GPG_KEY='A2BF8503E5E5AFC8'
