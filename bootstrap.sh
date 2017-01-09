#!/bin/bash

# Send output to a log file
exec 1>/tmp/bootstrap.log 2>&1

# Install packages
# * awscli is for lots of stuff
# * dnsutils is for dig
# * jq is for processing awscli output
# * mailutils is for sending email before SES is working (install later)
# * nfs-common is to mount EFS
DEBIAN_FRONTEND=noninteractive apt-get install -y awscli dnsutils jq nfs-common

# Get basic instance ID and location
INSTANCE_ID=$(curl -s http://169.254.169.254/2014-02-25/meta-data/instance-id)
AWS_AZ=$(curl -s http://169.254.169.254/2014-02-25/meta-data/placement/availability-zone)
AWS_REGION=$(echo $AWS_AZ | sed 's/[a-z]$//')
PRIVATE_FQDN=$(curl -s http://169.254.169.254/2016-09-02/meta-data/local-hostname)
PUBLIC_FQDN=$(curl -s http://169.254.169.254/2016-09-02/meta-data/public-hostname)
echo "Identified that $PUBLIC_FQDN instance ID $INSTANCE_ID, in AZ $AWS_AZ (region $AWS_REGION)"

# Install mailutils, including some Postfix configuration
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${PUBLIC_FQDN}" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils
sed -i "s/ = ${PRIVATE_FQDN}/ = ${PUBLIC_FQDN}/" /etc/postfix/main.cf
service postfix restart


# Get other info from the config file written by user-data
. /etc/kathputli-bootstrap.sh
DNS_ZONE_NAME_NO_END_DOT=$(echo ${DNS_ZONE_NAME} | sed 's/\.$//')

# Mount our bootstrap data EFS
mkdir /mnt/efs
EFS_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $AWS_REGION | jq '.Reservations[0].Instances[0].Tags[] | select(.Key | contains("NFS")) | .Value' | sed 's/"//g')
echo "EFS ID is $EFS_ID"
echo "${EFS_ID}.efs.${AWS_REGION}.amazonaws.com:/ /mnt/efs nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 1" >> /etc/fstab
echo "Mounting EFS..."
mount /mnt/efs

# All done!
touch /tmp/bootstrap-complete
exit 0
