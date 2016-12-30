#!/usr/bin/env bash

###########
#
# - dependencies: curl xmlstarlet (debian: apt-get install curl xmlstarlet)
# - GleSYS API credentials (DOMAIN and LOADBALANCER permissions)
#   syntax:
#   echo "export USER=CL12345" > /etc/ssl/private/.glesys-credentials
#   echo "export KEY=KEY_GOES_HERE" >> /etc/ssl/private/.glesys-credentials
#   echo "export export LOADBALANSERID=lb1234567" >> /etc/ssl/private/.glesys-credentials
#
###########

DEPS=`whereis xmlstarlet | awk {'print $2'}`
if [ -z $DEPS ]; then
        echo "install xmlstarlet"
        exit 1
fi

DEPS=`whereis curl | awk {'print $2'}`
if [ -z $DEPS ]; then
        echo "install curl"
        exit 1
fi

set -e
set -u
set -o pipefail
umask 077

#Load GleSYS Credentials
. /etc/ssl/private/.glesys-credentials

#split domain
FQDN=$2
DOMAIN=`echo $2 |rev |cut -d '.' -f1-2 |rev`
SUBDOMAIN=`echo $2 |rev |cut -d '.' -f3- |rev`
DONE="no"
#Functions
function validate_xml {
#Check if API call got status 200 (OK)
STATUSCODE=`xmlstarlet sel -t -v "/response/status/code" /tmp/api-log.xml`
if [ "$STATUSCODE" -ne 200 ]; then
        ERRORCODE=`xmlstarlet sel -t -v "/response/status/text" /tmp/api-log.xml`
        echo "Error: $ERRORCODE"
        exit 1
fi
}

if [[ "$1" = "deploy_challenge" ]]; then
        ##Create TXT-Record for LetsEncrypt
        curl -sS -X POST --data-urlencode domainname="$DOMAIN" --data-urlencode host="_acme-challenge.$FQDN." --data-urlencode type="TXT" --data-urlencode data="$4" --data-urlencode ttl="300" -k --basic -u $USER:$KEY https://api.glesys.com/domain/addrecord/ > /tmp/api-log.xml
        ##Run function to validate the response
        validate_xml
        DONE="yes"
fi

if [[ "$1" = "clean_challenge" ]]; then
        #API call to retrieve list of records for the domain.
        curl -sS -X POST --data-urlencode domainname="$DOMAIN" -k --basic -u $USER:$KEY https://api.glesys.com/domain/listrecords/ > /tmp/api-log.xml
        #Run function to validate the response
        validate_xml
                #remove TXT records created by this script
                for i in `xmlstarlet sel -t -c /response/records/item[host="'"_acme-challenge.$FQDN".'"] -f /tmp/api-log.xml |grep "<recordid>" |grep -o '[0-9]\+'`
                do
                        curl -sS -X POST --data-urlencode recordid="$i" -k --basic -u $USER:$KEY https://api.glesys.com/domain/deleterecord/ > /tmp/api-log.xml
                        validate_xml
                done
        DONE="yes"
fi

if [[ "$1" = "deploy_cert" ]]; then
        #Create single PEM
        cat /etc/ssl/private/certs/$DOMAIN/fullchain.pem > /etc/ssl/private/certs/$DOMAIN/$DOMAIN.pem
        cat /etc/ssl/private/certs/$DOMAIN/privkey.pem >> /etc/ssl/private/certs/$DOMAIN/$DOMAIN.pem
        chmod 600 /etc/ssl/private/certs/$DOMAIN/$DOMAIN.pem
        date=`date +"%F"`

        #upload cert
        cert="/etc/ssl/private/certs/$DOMAIN/$DOMAIN.pem"
        curl -s -X POST --data-urlencode loadbalancerid="$LOADBALANSERID" --data-urlencode certificatename="letsencrypt-$date" --data-urlencode certificate="`base64 -i $cert |tr -d '\012'`" -k --basic -u $USER:$KEY https://api.glesys.com/loadbalancer/addcertificate/ > /tmp/api-log.xml
        validate_xml

        #Get name of frontend which is listening on 443
        curl -s -X POST --data-urlencode loadbalancerid="$LOADBALANSERID" -k --basic -u $USER:$KEY https://api.glesys.com/loadbalancer/details/ > /tmp/api-log.xml
        validate_xml
        frontend=`xmlstarlet sel -t -v "/response/loadbalancer/frontends/item[port=443]/name" /tmp/api-log.xml`

        #change cert on frontend
        curl -s -X POST --data-urlencode loadbalancerid="$LOADBALANSERID" --data-urlencode frontendname="$frontend" --data-urlencode sslcertificate="letsencrypt-$date" -k --basic -u $USER:$KEY https://api.glesys.com/loadbalancer/editfrontend/ > /tmp/api-log.xml
        validate_xml
        DONE="yes"
fi

if [[ "$1" = "unchanged_cert" ]]; then
    echo "Certificate for domain $DOMAIN is still valid - no action taken"
    DONE="yes"
fi

#Remove tmp logfile
if [ -f /tmp/api-log.xml ] ; then
    rm /tmp/api-log.xml
fi

if [[ ! "$DONE" = "yes" ]]; then
    echo Unkown hook "$1"
    exit 1
fi

exit 0

