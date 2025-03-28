#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh




CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY=${CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY:-$1}
CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET=${CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET:-$2}

if [ -z "$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY" ]
then
     logerror "CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET" ]
then
     logerror "CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

bootstrap_ccloud_environment



# generate kafka-admin.properties config
sed -e "s|:CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY:|$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY|g" \
    -e "s|:CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET:|$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_SECRET|g" \
    ../../ccloud/rest-proxy-security-plugin/kafka-rest.jaas-template.conf > ../../ccloud/rest-proxy-security-plugin/kafka-rest.jaas.conf

mkdir -p ../../ccloud/rest-proxy-security-plugin/security
cd ../../ccloud/rest-proxy-security-plugin/security
playground tools certs-create --output-folder "$PWD" --container restproxy --container $CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY --verbose
cd -

docker compose -f "${PWD}/docker-compose.yml" up -d --quiet-pull

log "Creating topic rest-proxy-security-plugin in Confluent Cloud (auto.create.topics.enable=false)"
set +e
playground topic create --topic rest-proxy-security-plugin
set -e

sleep 15

# run as root for linux case where key is owned by root user
log "HTTP client using $CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY principal"
docker exec -e CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY=$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY --privileged --user root restproxy curl -X POST --cert /etc/kafka/secrets/$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY.certificate.pem --key /etc/kafka/secrets/$CCLOUD_REST_PROXY_SECURITY_PLUGIN_API_KEY.key --tlsv1.2 --cacert /etc/kafka/secrets/snakeoil-ca-1.crt -H "Content-Type: application/vnd.kafka.json.v2+json" -H "Accept: application/vnd.kafka.v2+json" --data '{"records":[{"value":{"foo":"bar"}}]}' "https://localhost:8082/topics/rest-proxy-security-plugin"
