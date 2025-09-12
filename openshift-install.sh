#!/usr/bin/env bash
# Budibase on OpenShift installer (restricted SCC friendly) - v9 fixed
# - Keeps Budibase Helm chart vanilla
# - Avoids writing to /etc/nginx by redirecting envsubst output to /tmp
# - Makes nginx runtime dirs writable via volumes + fsGroup
# - Passes args so nginx uses /tmp/nginx.conf (port 10000)
# - Forces args via oc patch to avoid any fallback to port 80
# - No cluster-admin or cluster-wide reads required

set -Eeuo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
RELEASE_NAME="${RELEASE_NAME:-budibase}"
NAMESPACE="${NAMESPACE:-budibase}"

echo -e "${BLUE}Budibase OpenShift Installer (v9 fixed)${NC}"
echo -e "${YELLOW}======================================${NC}"

need() { command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Missing '$1'.${NC}"; exit 1; }; }
need oc; need helm
oc whoami &>/dev/null || { echo -e "${RED}Run 'oc login' first.${NC}"; exit 1; }
echo -e "${GREEN}Authenticated as: $(oc whoami)${NC}"

# Namespace
if oc get project "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${GREEN}Using existing project: ${NAMESPACE}${NC}"
else
  echo -e "${YELLOW}Creating project: ${NAMESPACE}${NC}"
  oc new-project "${NAMESPACE}" >/dev/null
fi

# Detect apps domain
detect_apps_domain() {
  local domain="" console_host any_host api
  console_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${console_host}" && "${console_host}" == *".apps."* ]]; then
    domain="apps.${console_host#*.apps.}"
  fi
  if [[ -z "${domain}" ]]; then
    while IFS= read -r ns; do
      [[ -z "${ns}" ]] && continue
      any_host="$(oc get routes -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
      if [[ -n "${any_host}" && "${any_host}" == *".apps."* ]]; then
        domain="apps.${any_host#*.apps.}"; break
      fi
    done < <(oc get projects -o name 2>/dev/null | cut -d'/' -f2)
  fi
  if [[ -z "${domain}" ]]; then
    api="$(oc whoami --show-server 2>/dev/null || true)"
    [[ "${api}" =~ api\.([^/:]+) ]] && domain="apps.${BASH_REMATCH[1]}"
  fi
  echo -n "${domain}"
}
APPS_DOMAIN="$(detect_apps_domain)"
if [[ -z "${APPS_DOMAIN}" ]]; then
  echo -e "${YELLOW}Could not auto-discover apps domain.${NC}"
  read -rp "Enter your cluster apps domain (e.g., apps.example.com): " APPS_DOMAIN
fi
echo -e "${GREEN}Using apps domain: ${APPS_DOMAIN}${NC}"

# Detect default StorageClass
detect_storage_class() {
  local def any
  def="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "${def}" ]] && { echo -n "${def}"; return; }
  any="$(oc get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  echo -n "${any}"
}
STORAGE_CLASS="$(detect_storage_class)"
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo -e "${YELLOW}Could not detect a StorageClass.${NC}"
  read -rp "Enter StorageClass to use: " STORAGE_CLASS
fi
echo -e "${GREEN}Using StorageClass: ${STORAGE_CLASS}${NC}"

# Detect fsGroup from namespace range (OpenShift UIDs/GIDs guidance)
detect_fsGroup() {
  local rng sup uidrng
  sup="$(oc get ns "${NAMESPACE}" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' 2>/dev/null || true)"
  uidrng="$(oc get ns "${NAMESPACE}" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || true)"
  rng="${sup:-$uidrng}"
  if [[ "${rng}" =~ ^([0-9]+)/[0-9]+$ ]]; then
    echo -n "${BASH_REMATCH[1]}"
  else
    echo -n ""
  fi
}
FSGROUP="$(detect_fsGroup)"
[[ -n "${FSGROUP}" ]] && echo -e "${GREEN}Using fsGroup: ${FSGROUP}${NC}" || echo -e "${YELLOW}fsGroup not detected; proceeding.${NC}"

# Hooks: envsubst to /tmp and resolver IP from /etc/resolv.conf; IPv6 cleanup if needed
echo -e "${YELLOW}Creating nginx OpenShift hook ConfigMap...${NC}"
cat <<'EOF' | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: budibase-nginx-unpriv
data:
  15-openshift.envsh: |
    #!/bin/sh
    # Write rendered config to /tmp (writable under restricted SCC)
    export NGINX_ENVSUBST_OUTPUT_DIR="/tmp"
    # Ensure nginx 'resolver' uses an IP, since proxy_pass uses variables.
    case "${RESOLVER:-}" in
      ''|*[!0-9.:]*)
        ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
        if [ -n "$ns" ]; then
          case "$ns" in *:*) ns="[$ns]";; esac
          export RESOLVER="$ns"
        fi
        ;;
    esac
  85-openshift-ipv6-off.sh: |
    #!/bin/sh
    set -e
    CONF="/tmp/nginx.conf"
    if [ ! -f /proc/net/if_inet6 ] && [ -f "$CONF" ]; then
      sed -i '/listen  \[::\]/d' "$CONF" || true
      echo "[openshift] IPv6 disabled; removed IPv6 listen lines from $CONF"
    fi
EOF
echo -e "${GREEN}ConfigMap created/updated.${NC}"

# Generate Helm values override (volumes, mounts, args, storage)
VALUES_FILE="$(mktemp -t bb-values-XXXXXXXX.yaml)"
echo -e "${YELLOW}Generating Helm values override: ${VALUES_FILE}${NC}"

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
      - name: cache-volume
        emptyDir: {}
      - name: log-volume
        emptyDir: {}
      - name: run-volume
        emptyDir: {}
    extraVolumeMounts:
      - name: nginx-unpriv
        mountPath: /docker-entrypoint.d/15-openshift.envsh
        subPath: 15-openshift.envsh
      - name: nginx-unpriv
        mountPath: /docker-entrypoint.d/85-openshift-ipv6-off.sh
        subPath: 85-openshift-ipv6-off.sh
      - name: tmp-volume
        mountPath: /tmp
      - name: cache-volume
        mountPath: /var/cache/nginx
      - name: log-volume
        mountPath: /var/log/nginx
      - name: run-volume
        mountPath: /var/run
    args:
      - nginx
      - -c
      - /tmp/nginx.conf
      - -g
      - daemon off;

  objectStore:
    storageClass: "${STORAGE_CLASS}"

  redis:
    storageClass: "${STORAGE_CLASS}"

couchdb:
  persistentVolume:
    enabled: true
    storageClass: "${STORAGE_CLASS}"
EOF

# Helm repo and install/upgrade
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/ >/dev/null
helm repo update >/dev/null

echo -e "${YELLOW}Deploying Budibase (Helm) to namespace ${NAMESPACE}...${NC}"
helm upgrade --install "${RELEASE_NAME}" budibase/budibase -n "${NAMESPACE}" -f "${VALUES_FILE}"
echo -e "${GREEN}Helm release applied.${NC}"

# Best-effort: patch fsGroup so mounted dirs are writable by arbitrary UID
if [[ -n "${FSGROUP}" ]]; then
  oc patch deploy/proxy-service -n "${NAMESPACE}" --type merge -p "$(cat <<JSON
{
  "spec": { "template": { "spec": { "securityContext": { "fsGroup": ${FSGROUP}, "fsGroupChangePolicy": "OnRootMismatch" } } } }
}
JSON
)" >/dev/null || echo -e "${YELLOW}Warning: fsGroup patch failed (SCC may inject it automatically or deny).${NC}"
fi

# Force the container args to use /tmp/nginx.conf (prevents any fallback to 80)
echo -e "${YELLOW}Ensuring proxy uses /tmp/nginx.conf...${NC}"
PATCH_JSON='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["nginx","-c","/tmp/nginx.conf","-g","daemon off;"]}]'
if ! oc patch deploy/proxy-service -n "${NAMESPACE}" --type='json' -p "${PATCH_JSON}" >/dev/null 2>&1; then
  PATCH_JSON='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["nginx","-c","/tmp/nginx.conf","-g","daemon off;"]}]'
  oc patch deploy/proxy-service -n "${NAMESPACE}" --type='json' -p "${PATCH_JSON}" >/dev/null
fi

# OpenShift Route
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

# Wait for readiness
echo -e "${YELLOW}Waiting for proxy deployment to become Ready (timeout 10m)...${NC}"
end=$((SECONDS+600)); ready="false"
while [[ ${SECONDS} -lt ${end} ]]; do
  status="$(oc get deploy proxy-service -n "${NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ "${status}" == "1" ]]; then ready="true"; break; fi
  printf "."; sleep 5
done
echo
[[ "${ready}" == "true" ]] && echo -e "${GREEN}Proxy is Ready.${NC}" || echo -e "${YELLOW}Proxy not Ready yet; still progressing.${NC}"

echo -e "${GREEN}Budibase should be available at: https://${ROUTE_HOST}${NC}"
echo -e "${YELLOW}Note: It can take a few minutes for all pods to fully initialize.${NC}"

echo -e "${BLUE}Troubleshooting Tips:${NC}"
echo -e "  - Proxy logs:   oc logs deploy/proxy-service -n ${NAMESPACE}"
echo -e "  - Verify args:  oc get deploy/proxy-service -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].args}'"
echo -e "  - Inspect conf: oc rsh deploy/proxy-service -- sed -n '1,60p' /tmp/nginx.conf"
echo -e "  - Pods:         oc get pods -n ${NAMESPACE}"
echo -e "  - Events:       oc get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -n 50"
echo -e "  - Route:        oc get route ${RELEASE_NAME} -n ${NAMESPACE} -o wide"
echo -e "  - Uninstall:    helm uninstall ${RELEASE_NAME} -n ${NAMESPACE}"