#!/usr/bin/env bash

###
# Requirements: awscli
# IAM Permissions:
#   elasticloadbalancing:DescribeLoadBalancers
#   elasticloadbalancing:SetLoadBalancerListenerSSLCertificate
#   iam:ListServerCertificates
#   iam:UploadServerCertificate
#   iam:DeleteServerCertificate
#   iam:GetServerCertificate
#   
#   ## if Elastic beanstalk is used
#   elasticbeanstalk:DescribeEnvironmentResources
#   autoscaling:DescribeAutoScalingGroups
##

set -e
set -u
set -o pipefail

_exiterr () {
  echo >&2 "  - ELB: $@"
  exit 1
}

_printmsg () {
  echo "  + ELB: $@"
}

set +e
AWS=$(which aws)
set -e
[[ -x ${AWS} ]] || _exiterr "This script required aws cli installed and configured."

if [[ -z "${ELB_NAME}" && -n "${EB_ENV_NAME}" ]]; then 
  ELB_NAME=$(${AWS} elasticbeanstalk describe-environment-resources \
    --environment-name "${EB_ENV_NAME}" \
    --query '*.LoadBalancers[0].Name' \
    --output text)
fi
[[ -n "${ELB_NAME:-}" ]] || _exiterr "One of ELB_NAME or EB_ENV_NAME is required."

deploy_cert() {
  local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

  _printmsg "deploy_cert called: ${DOMAIN}, ${KEYFILE}, ${CERTFILE}, ${FULLCHAINFILE}, ${CHAINFILE}"

  ELB_DELETE_OLD_CERT=${ELB_DELETE_OLD_CERT:-no}
  if [[ -z "${ELB_CERT_PREFIX:-}" ]]; then
    ELB_CERT_PREFIX=LETSENCRYPT_CERT_
  fi
  CERT_NAME="${ELB_CERT_PREFIX}$(date +%m-%d-%y_%H-%M-%S)"
  

  ##
  # upload cert to IAM
  ##
  _printmsg "Uploading $CERT_NAME to IAM"
  NEW_CERT_ARN=$(${AWS} iam upload-server-certificate \
    --server-certificate-name $CERT_NAME \
    --certificate-body file://${CERTFILE} \
    --private-key file://${KEYFILE} \
    --certificate-chain file://${CHAINFILE} \
    --path / \
    --query 'ServerCertificateMetadata.Arn' \
    --output text
  )
  sleep 10

  ##
  # change elb cert
  ##
  _printmsg "Updating ELB ${ELB_NAME} with new $NEW_CERT_ARN IAM cert..."
  ${AWS} elb set-load-balancer-listener-ssl-certificate \
    --load-balancer-name $ELB_NAME \
    --load-balancer-port 443 \
    --ssl-certificate-id $NEW_CERT_ARN

  ## 
  # delete cert
  ##
  if [[ "${ELB_DELETE_OLD_CERT}" = "yes" ]]; then
    OLD_CERTS=($(
      ${AWS} iam list-server-certificates --query \
        "ServerCertificateMetadataList[?starts_with(ServerCertificateName, \`${ELB_CERT_PREFIX}\`) == \`true\` && ServerCertificateName != \`${CERT_NAME}\`].ServerCertificateName" \
         --output text
    ))

    _printmsg "ELB_DELETE_OLD_CERT set to 'yes', deleting ALL old certs with prefix '${ELB_CERT_PREFIX}' in 30 seconds..."
    _printmsg "Certs to be deleted: ${OLD_CERTS[@]}"

    sleep 30
    for OLD_CERT in "${OLD_CERTS[@]}"; do
      _printmsg "Deleting '${OLD_CERT}'..."
      ${AWS} iam delete-server-certificate --server-certificate-name $OLD_CERT
    done
  fi

  sleep 10
}

check_dependencies() { 
:
}

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_cert)$ ]]; then
  "$HANDLER" "$@"
fi
