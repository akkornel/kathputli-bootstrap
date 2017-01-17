#!/bin/bash

# Send output to a log file
exec 1>/var/log/bootstrap.log 2>&1

# Install packages
# * awscli is for lots of stuff
# * dnsutils is for dig
# * jq is for processing awscli output
# * mailutils is for sending email before SES is working (install later)
# * nfs-common is to mount EFS
# * unzip is to extract Terraform
echo 'Installing packages for bootstrap'
DEBIAN_FRONTEND=noninteractive apt-get install -y awscli dnsutils jq nfs-common unzip

# Get basic instance ID and location
INSTANCE_ID=$(curl -s http://169.254.169.254/2014-02-25/meta-data/instance-id)
AWS_AZ=$(curl -s http://169.254.169.254/2014-02-25/meta-data/placement/availability-zone)
AWS_REGION=$(echo $AWS_AZ | sed 's/[a-z]$//')
PRIVATE_FQDN=$(curl -s http://169.254.169.254/2016-09-02/meta-data/local-hostname)
PUBLIC_FQDN=$(curl -s http://169.254.169.254/2016-09-02/meta-data/public-hostname)
echo ; echo "Identified that we are $PRIVATE_FQDN / $PUBLIC_FQDN, instance ID $INSTANCE_ID, in AZ $AWS_AZ (region $AWS_REGION)"

# Install mailutils, including some Postfix configuration
echo ; echo 'Installing and configuring Postfix'
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${PUBLIC_FQDN}" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils
sed -i "s/ = ${PRIVATE_FQDN}/ = ${PUBLIC_FQDN}/" /etc/postfix/main.cf
service postfix restart


# Get other info from the config file written by user-data
echo ; echo 'Getting bootstrap data from shell config file'
. /etc/kathputli-bootstrap.sh
DNS_ZONE_NAME_NO_END_DOT=$(echo ${DNS_ZONE_NAME} | sed 's/\.$//')

#
# MOUNT NFS
#

mkdir /mnt/efs

# Check if we already have the mount defined
grep -q /mnt/efs /etc/fstab || echo "${EFS_ID}.efs.${AWS_REGION}.amazonaws.com:/ /mnt/efs nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 1" >> /etc/fstab
echo ; echo "Mounting EFS..."
mount /mnt/efs

# If we don't have one already, make a directory to hold config status
[ -d /mnt/efs/config_status ] || mkdir /mnt/efs/config_status

#
# DNS DELEGATION
#

# This is a really simple check: Query for a SOA record for the domain.  If
# delegation isn't already done, then nothing will be returned, or we will get
# a timeout message.
DNS_NAMESERVERS=$(aws route53 get-hosted-zone --id ${DNS_ZONE_ID} | jq .DelegationSet.NameServers)
echo "DNS domain $DNS_ZONE_NAME has zone ID $DNS_ZONE_ID"
DNS_DELEGATION_DONE=$(dig +recurse +short ${DNS_ZONE_NAME} soa | grep amazon | wc -l | sed 's/ //g')
if [ ${DNS_DELEGATION_DONE} -eq '0' ]; then
    echo ; echo 'DNS Delegation incomplete!'
    cat <<EOF > /tmp/dns_mail.txt
Hello!

This is the bootstrap system at ${PUBLIC_FQDN} (${PRIVATE_FQDN}).

We have detected that delegation for the zone ${DNS_ZONE_NAME} is NOT complete.

Please go to your upstream DNS or registrar, and set the following as name
servers for your zone:

${DNS_NAMESERVERS}

Until you do this, you will not be able to use your Puppet services.

You can confirm things are working by SSHing to the server
"bootstrap.${DNS_ZONE_NAME}", which (if delegation is working) will connect you
to the system which sent this email.

Thanks very much!
EOF
    mailx --return-address="root@${PUBLIC_FQDN}" --subject='DNS Delegation Required' "${ADMIN_EMAIL}" < /tmp/dns_mail.txt
    rm /tmp/dns_mail.txt
else
    echo ; echo 'DNS delegation looks good'
fi

#
# BOOTSTRAP CNAME RECORD CONFIGURATION
#

if [ $(aws route53 list-resource-record-sets --hosted-zone-id ${DNS_ZONE_ID} --no-paginate --query "ResourceRecordSets[?Name == 'bootstrap.${DNS_ZONE_NAME}']" | wc -l | sed 's/ //') -ne '1' ]; then
    echo ; echo 'We need to clean up old bootstrap CNAME entries'
# TODO: Remove any existing DNS entries
    cat > /tmp/bootstrap_cleanup.json <<EOS
{
"Comment": "Add SES verification token to domain",
"Changes": [
{
  "Action": "DELETE",
  "ResourceRecordSet": {
    "Name": "bootstrap.${DNS_ZONE_NAME}",
    "Type": "CNAME",
    "TTL": 60,
    "ResourceRecords": [{
      "Value": "${PUBLIC_FQDN}"
    }
    ]
  }
}
]
}
EOS
#aws route53 change-resource-record-sets --hosted-zone-id ${DNS_ZONE_ID} --change-batch file:///tmp/bootstrap_cleanup.json
rm /tmp/bootstrap_clenaup.json
fi
echo ; echo "Adding CNAME for bootstrap.${DNS_ZONE_NAME} --> ${PUBLIC_FQDN}"
cat > /tmp/bootstrap_cname_route53.json <<EOS
{
"Comment": "Add SES verification token to domain",
"Changes": [
{
  "Action": "CREATE",
  "ResourceRecordSet": {
    "Name": "bootstrap.${DNS_ZONE_NAME}",
    "Type": "CNAME",
    "TTL": 60,
    "ResourceRecords": [{
      "Value": "${PUBLIC_FQDN}"
    }
    ]
  }
}
]
}
EOS
aws route53 change-resource-record-sets --hosted-zone-id ${DNS_ZONE_ID} --change-batch file:///tmp/bootstrap_cname_route53.json
rm /tmp/bootstrap_cname_route53.json

#
# SES CONFIGURATION
#

# SES configuration involves getting a verification token for the domain, and
# then adding it to Route53.
configure_ses () {
    SES_TOKEN=$(aws ses verify-domain-identity --region ${AWS_REGION} --domain ${DNS_ZONE_NAME_NO_END_DOT} | jq .VerificationToken)
    SES_TOKEN_QUOTED_QUOTES=$(echo ${SES_TOKEN} | sed 's/"/\\"/g')
    echo ; echo "Adding TXT record ${SES_TOKEN} to ${DNS_ZONE_NAME} for SES"
    cat > /tmp/ses_route53.json <<EOS
{
"Comment": "Add SES verification token to domain",
"Changes": [
{
  "Action": "CREATE",
  "ResourceRecordSet": {
    "Name": "${DNS_ZONE_NAME}",
    "Type": "TXT",
    "TTL": 1800,
    "ResourceRecords": [{
      "Value": "${SES_TOKEN_QUOTED_QUOTES}"
    }
    ]
  }
}
]
}
EOS
    return aws route53 change-resource-record-sets --hosted-zone-id ${DNS_ZONE_ID} --change-batch file:///tmp/ses_route53.json
}

SES_VALIDATION_DONE=$(dig +recurse +short ${DNS_ZONE_NAME} txt | grep -i -v timeout | wc -l | sed 's/ //g')
if [ ${SES_VALIDATION_DONE} -eq '0' ]; then
    echo 'Doing SES configuration...'
    configure_ses
    sleep 30
    echo ; echo 'SES configuration complete!'
else
    echo ; echo 'SES configuration already active'
fi

#
# TERRAFORM
#

# Terraform's bootstrap is in a separate script.
echo 'Running Terraform bootstrap script'
./terraform.sh

# All done!
echo ; echo 'Bootstrap complete!  System will now reboot to start services.'
touch /var/log/bootstrap-complete
shutdown -r now
exit 0
