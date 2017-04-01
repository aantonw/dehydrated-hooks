#!/usr/bin/env bash

###
# Requirements: curl, dig
##

set -e
set -u
set -o pipefail

_exiterr () {
  echo >&2 "  - CLOUDFLARE: $@"
  exit 1
}

_printmsg () {
  echo "  + CLOUDFLARE: $@"
}

CURL=$(which curl)
DIG=$(which dig)

if [[ $(uname) = 'Darwin' ]]; then 
  GREP=$(which ggrep)
else
  GREP=$(which grep)
fi

ACME="_acme-challenge"
if [[ -z "${ELB_HOOK:-}" ]]; then
  DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  ELB_HOOK="${DIR}/elb-hook.sh"
fi

get_zone_id() {
  local DOMAIN="${1}"

  # if zone is set in config use that
  if [[ -n "${CLOUDFLARE_ZONE}" ]]; then
    DOMAIN=${CLOUDFLARE_ZONE}
  fi

  ZONE_ID=$(${CURL} -s -X \
    GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
    -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
    -H "X-Auth-Key: $CLOUDFLARE_TOKEN" \
    -H "Content-Type: application/json")

  if [[ ${ZONE_ID} == *"\"success\":true"* ]]; then
    echo "$ZONE_ID" | ${GREP} -Po '(?<="id":")[^"]+' | head -1
  else
    _exiterr "$ZONE_ID" | ${GREP} -Po '(?<="message":")[^"]+'
  fi
}

get_record_id() {
  local DOMAIN="${1}"

  if [[ ! -z $2 ]]; then
    ZONE_ID="${2}"
  else
    ZONE_ID=$(get_zone_id "$DOMAIN")
    if [[ $? != 0 ]]; then
      _exiterr "$ZONE_ID"
    fi
  fi

  RECORD_NAME="${ACME}.${DOMAIN}"
  RECORD_ID=$(${CURL} -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${RECORD_NAME}" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json")
  
  if [[ ${RECORD_ID} == *"\"success\":true"* && ${RECORD_ID} == *"\"id\":\""* ]]; then
    echo "$RECORD_ID" | ${GREP} -P -o '(?<="id":")[^"]+' | head -1
  else
    _exiterr "$RECORD_ID" | ${GREP} -P -o '(?<="message":")[^"]+'
  fi
}


deploy_challenge() {
  DOMAINS=() # support HOOK_CHAIN=true
  while [[ $# -ge 3 ]]; do
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    DOMAINS+=("${DOMAIN}")
    ##
    # add dns record
    ##
    ZONE_ID=$(get_zone_id "${DOMAIN}")
    RECORD_NAME="${ACME}.${DOMAIN}"
    _printmsg "Adding new record ${RECORD_NAME} ..."
    echo $ZONE_ID
    NEW_RECORD=$(${CURL} -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
      -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"id\":\"${ZONE_ID}\",\"type\":\"TXT\",\"name\":\"${RECORD_NAME}\",\"content\":\"${TOKEN_VALUE}\"}")
    
    if [[ $? == 0 ]]; then
      _printmsg "Added record ${RECORD_NAME}"
    else
      _exiterr "Failed to add: $addres"
    fi

    shift 3
  done
  
  # check propagation with dig
  for DOMAIN in "${DOMAINS[@]}"; do
    _printmsg " Checking for propagation of record ${ACME}.${DOMAIN}..."
    TRIES=0
    MAX_TRIES=25
    while [[ ${TRIES} -lt ${MAX_TRIES} ]];do
      DIGRESULT=$(
        ${DIG} txt +trace +noall +answer "${ACME}.${DOMAIN}" | \
        ${GREP} -P "^${ACME}\.${DOMAIN}"
      )
      if [[ $? = 0 ]]; then
        _printmsg "Successfully propagated."
        break
      fi
      TRIES=$((TRIES + 1))
      if [[ ${TRIES} -ge ${MAX_TRIES} ]]; then
        _exiterr "Failed to propagate record."
        break
      fi
      
      _printmsg "Retrying in 5s..."
      sleep 5
    done
  done
}

clean_challenge() {
  while [[ $# -ge 3 ]]; do
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    ##
    # Delete Record
    ##
    ZONE_ID=$(get_zone_id ${DOMAIN})
    RECORD_ID=$(get_record_id ${DOMAIN} ${ZONE_ID})
    RECORD_NAME="${ACME}.${DOMAIN}"
    _printmsg "Deleting new record ${RECORD_NAME} ..."
    DELETED_RECORD=$(${CURL} -s -X DELETE \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_TOKEN}" \
      -H "Content-Type: application/json")
    
    _printmsg "Deleted record ${RECORD_NAME}"

    shift 3
  done
}

deploy_cert() {
  local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"
  _printmsg "deploy_cert called: ${DOMAIN}, ${KEYFILE}, ${CERTFILE}, ${FULLCHAINFILE}, ${CHAINFILE}"

  if [[ ${ELB:-} = 'yes' ]]; then
    _printmsg "ELB set to 'yes', running ELB Hook..."
    ${ELB_HOOK} deploy_cert "$@"
  fi
}

unchanged_cert() {
  local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}"
  
  _printmsg "unchanged_cert called: ${DOMAIN}, ${KEYFILE}, ${CERTFILE}, ${FULLCHAINFILE}, ${CHAINFILE}"
}

invalid_challenge() {
  local DOMAIN="${1}" RESPONSE="${2}"

  _printmsg "Invalid challenge for ${Domain} with response ${RESPONSE}"
}

request_failure() {
  local STATUSCODE="${1}" REASON="${2}" REQTYPE="${3}"

  _printmsg "Request Failure: ${REQTYPE} ${STATUSCODE}, Reason: ${REASON}"
}

exit_hook() {
  # This hook is called at the end of a dehydrated command and can be used
  # to do some final (cleanup or other) tasks.

  :
}

check_dependencies() {
  [[ -x ${CURL} ]] || _exiterr "Cloudflare hook require curl installed."
  [[ -x ${DIG} ]] || _exiterr "Cloudflare hook require dig installed."
  [[ -x ${GREP} ]] || _exiterr "Cloudflare hook require grep (ggrep in OSX) installed."
  [[ -n "${CLOUDFLARE_EMAIL:-}" ]] || _exiterr "Cloudflare hook require CLOUDFLARE_EMAIL set."
  [[ -n "${CLOUDFLARE_TOKEN:-}" ]] || _exiterr "Cloudflare hook require CLOUDFLARE_TOKEN set."

  if [[ "${ELB:-}" = "yes" ]]; then
    ${ELB_HOOK} check_dependencies
  fi
}
check_dependencies

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert|unchanged_cert|invalid_challenge|request_failure|exit_hook)$ ]]; then
  "$HANDLER" "$@"
fi

