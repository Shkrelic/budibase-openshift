#!/usr/bin/env bash
# Budibase on OpenShift installer (restricted SCC friendly)
# - Keeps Budibase Helm chart vanilla
# - Patches nginx at runtime via /docker-entrypoint.d
# - No image changes; no cluster-admin required

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

RELEASE_NAME="${RELEASE_NAME:-budibase}"
NAMESPACE="${NAMESPACE:-budibase}"

echo -e "${BLUE}Budibase OpenShift Installer${NC}"
echo -e "${YELLOW}================================${NC}"

# Prereqs
if ! command -v oc >/dev/null 2>&1; then
  echo -e "${RED}Missing 'oc' CLI. Install it first.${NC}"
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo -e "${RED}Missing 'helm' CLI. Install it first.${NC}"
  exit 1
fi
if ! oc whoami &>/dev/null; then
  echo -e "${RED}You are not logged into OpenShift. Please run 'oc login' first.${NC}"
  exit 1
fi
echo -e "${GREEN}Authenticated as: $(oc whoami)${NC}"

# Namespace
if oc get project "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${GREEN}Using existing project: ${NAMESPACE}${NC}"
else
  echo -e "${YELLOW}Creating project: ${NAMESPACE}${NC}"
  oc new-project "${NAMESPACE}" >/dev/null
  echo -e "${GREEN}Created project: ${NAMESPACE}${NC}"
fi

# Detect OpenShift apps domain (e.g., apps.cluster.example.com)
detect_apps_domain() {
  local domain=""

  # Method 1: Console route host -> extract apps.*
  local console_host
  console_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${console_host}" && "${console_host}" == *".apps."* ]]; then
    domain="apps.${console_host#*.apps.}"
  fi

  # Method 2: Scan any route and extract apps.*
  if [[ -z "${domain}" ]]; then
    while IFS= read -r ns; do
      [[ -z "${ns}" ]] && continue
      local any_host
      any_host="$(oc get routes -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
      if [[ -n "${any_host}" && "${any_host}" == *".apps."* ]]; then
        domain="apps.${any_host#*.apps.}"
        break
      fi
    done < <(oc get projects -o name 2>/dev/null | cut -d'/' -f2)
  fi

  # Method 3: From API URL (api.<base>) -> apps.<base>
  if [[ -z "${domain}" ]]; then
    local api
    api="$(oc whoami --show-server 2>/dev/null || true)"
    if [[ "${api}" =~ api\.([^/:]+) ]]; then
      domain="apps.${BASH_REMATCH[1]}"
    fi
  fi

  echo -n "${domain}"
}

APPS_DOMAIN="$(detect_apps_domain)"
if [[ -z "${APPS_DOMAIN}" ]]; then
  echo -e "${YELLOW}Could not auto-discover cluster apps domain.${NC}"
  read -rp "Enter your cluster apps domain (e.g., apps.openshift.example.com): " APPS_DOMAIN
fi
echo -e "${GREEN}Using apps domain: ${APPS_DOMAIN}${NC}"

# Detect a DNS resolver IP for NGINX (cluster DNS service IP)
detect_dns_resolver_ip() {
  local ip=""
  ip="$(oc get svc dns-default -n openshift-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(oc get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(oc get svc coredns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi
  echo -n "${ip}"
}
RESOLVER_IP="$(detect_dns_resolver_ip)"
if [[ -n "${RESOLVER_IP}" ]]; then
  echo -e "${GREEN}Detected cluster DNS resolver IP: ${RESOLVER_IP}${NC}"
else
  echo -e "${YELLOW}Could not detect a cluster DNS resolver IP. Falling back to chart default.${NC}"
fi

# Detect StorageClass (prefer default)
detect_storage_class() {
  local default_sc=""
  default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "${default_sc}" ]]; then
    echo -n "${default_sc}"
    return
  fi
  # Fallback: first available
  local any_sc=""
  any_sc="$(oc get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  echo -n "${any_sc}"
}
STORAGE_CLASS="$(detect_storage_class)"
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo -e "${YELLOW}Could not detect a StorageClass.${NC}"
  read -rp "Enter StorageClass to use: " STORAGE_CLASS
fi
echo -e "${GREEN}Using StorageClass: ${STORAGE_CLASS}${NC}"

# Create ConfigMap with /docker-entrypoint.d patch (runs after envsubst)
echo -e "${YELLOW}Creating nginx unprivileged patch ConfigMap...${NC}"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: budibase-nginx-unpriv
  namespace: budibase
data:
  90-openshift-unprivileged.sh: |
    #!/bin/sh
    set -e

    echo "[openshift] Patching nginx config for arbitrary UID..."

    # Ensure writable temp dirs
    mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp
    chmod 0777 /tmp /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp || true

    # nginx.conf should exist after envsubst step
    if [ -f /etc/nginx/nginx.conf ]; then
      cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig || true

      # error log to /tmp (portable sed)
      if grep -qE '^[[:space:]]*error_log[[:space:]]+' /etc/nginx/nginx.conf; then
        sed -i -E 's|^[[:space:]]*error_log[[:space:]]+.*;|error_log               /tmp/error.log debug;|' /etc/nginx/nginx.conf || true
      else
        sed -i '1i error_log               /tmp/error.log debug;' /etc/nginx/nginx.conf || true
      fi

      # access log to /tmp
      sed -i -E 's|access_log[[:space:]]+/var/log/nginx/access\.log[[:space:]]+main;|access_log /tmp/access.log main;|' /etc/nginx/nginx.conf || true

      # pid to /tmp (portable sed)
      if grep -qE '^[[:space:]]*pid[[:space:]]+' /etc/nginx/nginx.conf; then
        sed -i -E 's|^[[:space:]]*pid[[:space:]]+.*;|pid                     /tmp/nginx.pid;|' /etc/nginx/nginx.conf || true
      else
        sed -i '1i pid                     /tmp/nginx.pid;' /etc/nginx/nginx.conf || true
      fi

      # inject temp paths into http block once
      if ! grep -q 'client_body_temp_path /tmp/client_temp;' /etc/nginx/nginx.conf; then
        sed -i '/http {/a \
  # Temp paths for OpenShift arbitrary UID\
  client_body_temp_path /tmp/client_temp;\
  proxy_temp_path       /tmp/proxy_temp;\
  fastcgi_temp_path     /tmp/fastcgi_temp;\
  uwsgi_temp_path       /tmp/uwsgi_temp;\
  scgi_temp_path        /tmp/scgi_temp;' /etc/nginx/nginx.conf || true
      fi

      echo "[openshift] nginx.conf patched for non-root operation."
    else
      echo "[openshift] WARNING: /etc/nginx/nginx.conf not found at patch time."
    fi

    exit 0
EOF
echo -e "${GREEN}ConfigMap created/updated.${NC}"

# Generate values override
VALUES_FILE="$(mktemp -t bb-values-XXXXXXXX.yaml)"
echo -e "${YELLOW}Generating Helm values override at ${VALUES_FILE}...${NC}"

# First part
cat > "${VALUES_FILE}" <<EOF
ingress:
  enabled: false

services:
  proxy:
    extraVolumes:
      - name: nginx-unpriv
        configMap:
          name: budibase-nginx-unpriv
          defaultMode: 0755
      - name: tmp-volume
        emptyDir: {}
    extraVolumeMounts:
      - name: nginx-unpriv
        mountPath: /docker-entrypoint.d/90-openshift-unprivileged.sh
        subPath: 90-openshift-unprivileged.sh
      - name: tmp-volume
        mountPath: /tmp
EOF

# Safe optional resolver (quoted)
if [[ -n "${RESOLVER_IP}" ]]; then
  printf "    resolver: \"%s\"\n" "${RESOLVER_IP}" >> "${VALUES_FILE}"
fi

# Rest
cat >> "${VALUES_FILE}" <<EOF

  objectStore:
    storageClass: "${STORAGE_CLASS}"

  redis:
    storageClass: "${STORAGE_CLASS}"

couchdb:
  persistentVolume:
    enabled: true
    storageClass: "${STORAGE_CLASS}"
EOF

# Add Budibase Helm repo
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/ >/dev/null
helm repo update >/dev/null

# Install/upgrade
echo -e "${YELLOW}Deploying Budibase (Helm) to namespace ${NAMESPACE}...${NC}"
helm upgrade --install "${RELEASE_NAME}" budibase/budibase -n "${NAMESPACE}" -f "${VALUES_FILE}"

echo -e "${GREEN}Helm release applied.${NC}"

# Create or update OpenShift Route to the proxy service
ROUTE_HOST="budibase.${APPS_DOMAIN}"
echo -e "${YELLOW}Creating/Updating OpenShift Route: https://${ROUTE_HOST}${NC}"
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${RELEASE_NAME}
spec:
  host: ${ROUTE_HOST}
  to:
    kind: Service
    name: proxy-service
    weight: 100
  port:
    targetPort: 10000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# Wait for proxy to be ready
echo -e "${YELLOW}Waiting for proxy pod to become Ready (timeout 10m)...${NC}"
end=$((SECONDS+600))
ready="false"
while [[ ${SECONDS} -lt ${end} ]]; do
  status="$(oc get deploy proxy-service -n "${NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ "${status}" == "1" ]]; then
    ready="true"
    break
  fi
  printf "."
  sleep 5
done
echo

if [[ "${ready}" != "true" ]]; then
  echo -e "${YELLOW}Proxy not Ready yet; deployment may still be progressing.${NC}"
else
  echo -e "${GREEN}Proxy is Ready.${NC}"
fi

echo -e "${GREEN}Budibase should be available at: https://${ROUTE_HOST}${NC}"
echo -e "${YELLOW}Note: It can take a few minutes for all pods to fully initialize.${NC}"

echo -e "${BLUE}Troubleshooting Tips:${NC}"
echo -e "  - Pods:         oc get pods -n ${NAMESPACE}"
echo -e "  - Events:       oc get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -n 50"
echo -e "  - Proxy logs:   oc logs deploy/proxy-service -n ${NAMESPACE}"
echo -e "  - Route:        oc get route ${RELEASE_NAME} -n ${NAMESPACE} -o wide"
echo -e "  - Uninstall:    helm uninstall ${RELEASE_NAME} -n ${NAMESPACE}"