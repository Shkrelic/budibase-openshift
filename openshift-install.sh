#!/bin/bash
# Comprehensive Budibase deployment script for OpenShift
# Fully automated with proper nginx permissions and resource limits

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Budibase OpenShift Installer${NC}"
echo -e "${YELLOW}===============================${NC}"

# Verify that user is logged into OpenShift
if ! oc whoami &>/dev/null; then
  echo -e "${RED}You are not logged into OpenShift. Please run 'oc login' first.${NC}"
  exit 1
fi
echo -e "${GREEN}Authenticated as: $(oc whoami)${NC}"

# Auto-discover cluster domain
echo -e "${YELLOW}Auto-discovering cluster domain...${NC}"
CLUSTER_DOMAIN=""

# Try method 1: Find a route in any project the user can access
for PROJECT in $(oc projects -o name 2>/dev/null | cut -d'/' -f2); do
  # Skip if project is empty or null
  if [ -z "$PROJECT" ]; then continue; fi
  
  # Try to get a route from this project
  ROUTE=$(oc -n $PROJECT get routes -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
  if [ ! -z "$ROUTE" ]; then
    # Extract domain by removing everything up to the first dot
    CLUSTER_DOMAIN=$(echo $ROUTE | grep -o '[^.]*\..*')
    if [ ! -z "$CLUSTER_DOMAIN" ]; then
      CLUSTER_DOMAIN=${CLUSTER_DOMAIN#*.}
      echo -e "${GREEN}Discovered domain: ${CLUSTER_DOMAIN} (from route in $PROJECT)${NC}"
      break
    fi
  fi
done

# Method 2: Try to extract from API server URL if method 1 failed
if [ -z "$CLUSTER_DOMAIN" ]; then
  API_URL=$(oc whoami --show-server 2>/dev/null)
  if [[ $API_URL =~ api\.([^:]+) ]]; then
    CLUSTER_DOMAIN="${BASH_REMATCH[1]}"
    # Replace the 'api' prefix with 'apps'va
    CLUSTER_DOMAIN="apps.${CLUSTER_DOMAIN#api.}"
    echo -e "${GREEN}Discovered domain: ${CLUSTER_DOMAIN} (from API URL)${NC}"
  fi
fi

# Fallback to manual input if auto-detection fails
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo -e "${YELLOW}Could not auto-discover cluster domain.${NC}"
  read -p "Enter your cluster domain (e.g., apps.openshift.example.com): " CLUSTER_DOMAIN
fi

echo -e "${GREEN}Using cluster domain: ${CLUSTER_DOMAIN}${NC}"

# Project management
echo -e "${YELLOW}Setting up project for Budibase...${NC}"
PROJECT_NAME="budibase"

# Check if project exists
if oc get project $PROJECT_NAME &>/dev/null; then
  echo -e "${YELLOW}Project '$PROJECT_NAME' already exists.${NC}"
  echo -e "${YELLOW}Deleting project '$PROJECT_NAME'...${NC}"
  oc delete project $PROJECT_NAME
  
  echo -e "${YELLOW}Waiting for project deletion to complete...${NC}"
  # More robust waiting for project deletion
  TIMEOUT=120  # 2 minutes timeout
  COUNTER=0
  while oc get project $PROJECT_NAME &>/dev/null; do
    echo -n "."
    sleep 5
    COUNTER=$((COUNTER+5))
    if [ $COUNTER -ge $TIMEOUT ]; then
      echo -e "\n${RED}Timeout waiting for project deletion.${NC}"
      echo -e "${YELLOW}Please wait a bit longer and run the script again.${NC}"
      exit 1
    fi
  done
  echo -e "\n${GREEN}Project deleted.${NC}"
  
  # Important: Additional wait to ensure project is fully cleaned up in the API
  echo -e "${YELLOW}Ensuring project is fully removed from the system...${NC}"
  sleep 15
fi

# Try to create the project with retry logic
echo -e "${YELLOW}Creating project '$PROJECT_NAME'...${NC}"
RETRY_COUNT=0
MAX_RETRIES=5

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if oc new-project $PROJECT_NAME &>/dev/null; then
    echo -e "${GREEN}Successfully created project '$PROJECT_NAME'.${NC}"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo -e "${YELLOW}Failed to create project. Retrying in 10 seconds... (Attempt $RETRY_COUNT/$MAX_RETRIES)${NC}"
      sleep 10
    else
      echo -e "${RED}Failed to create project after $MAX_RETRIES attempts.${NC}"
      read -p "Enter an existing project to use instead: " PROJECT_NAME
      if ! oc project $PROJECT_NAME &>/dev/null; then
        echo -e "${RED}Cannot access project '$PROJECT_NAME'. Exiting.${NC}"
        exit 1
      fi
    fi
  fi
done

echo -e "${GREEN}Using project: $PROJECT_NAME${NC}"

# Storage class selection
echo -e "${YELLOW}Detecting available storage classes...${NC}"
STORAGE_CLASSES=$(oc get storageclass -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)

DEFAULT_SC="nfs"  # Default fallback

if [ ! -z "$STORAGE_CLASSES" ]; then
  echo -e "${GREEN}Available storage classes:${NC}"
  echo "$STORAGE_CLASSES"
  
  # Auto-select the storage class
  if echo "$STORAGE_CLASSES" | grep -q "nfs"; then
    DEFAULT_SC="nfs"
  elif echo "$STORAGE_CLASSES" | grep -q "thin"; then
    DEFAULT_SC="thin"
  elif echo "$STORAGE_CLASSES" | grep -q "thin-csi"; then
    DEFAULT_SC="thin-csi"
  else
    DEFAULT_SC=$(echo "$STORAGE_CLASSES" | head -n1)
  fi
  
  echo -e "${GREEN}Auto-selected storage class: ${DEFAULT_SC}${NC}"
else
  echo -e "${YELLOW}Could not retrieve storage classes. Using default (nfs).${NC}"
fi

# Create the ConfigMap for nginx OpenShift compatibility first
echo -e "${YELLOW}Creating nginx compatibility ConfigMap...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: v1
kind: ConfigMap
metadata:
  name: budibase-proxy-openshift
  namespace: $PROJECT_NAME
data:
  openshift.conf: |
    # OpenShift-compatible nginx configuration
    client_body_temp_path /tmp/nginx/client_body;
    proxy_temp_path /tmp/nginx/proxy;
    fastcgi_temp_path /tmp/nginx/fastcgi;
    uwsgi_temp_path /tmp/nginx/uwsgi;
    scgi_temp_path /tmp/nginx/scgi;
EOF

# Create OpenShift-compatible values.yaml with resource limits and nginx fixes
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"

cat > values.yaml << EOF
# OpenShift-compatible Budibase configuration with nginx fixes

global:
  openshift: true

# App service configuration
app:
  image:
    repository: budibase/budibase
    pullPolicy: IfNotPresent
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 512Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
  serviceAccount:
    create: true
    name: "budibase-budibase"

# Worker service configuration
worker:
  resources:
    limits:
      cpu: 300m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL

# Proxy settings - Critical OpenShift nginx fixes
proxy:
  serviceAccount:
    create: true
    name: "budibase-budibase"
  resources:
    limits:
      cpu: 200m
      memory: 256Mi
    requests:
      cpu: 50m
      memory: 128Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
  containerSecurityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    runAsUser: null  # Let OpenShift assign the appropriate UID
    fsGroup: null    # Let OpenShift assign the appropriate GID
    capabilities:
      drop:
      - ALL
    readOnlyRootFilesystem: false
  # Special nginx configuration for OpenShift
  extraVolumes:
    - name: nginx-temp
      emptyDir: {}
  extraVolumeMounts:
    - name: nginx-temp
      mountPath: /tmp/nginx
  extraEnvVars:
    - name: NGINX_TEMP_PATH
      value: /tmp/nginx
  extraConfigmapMounts:
    - name: nginx-openshift-conf
      mountPath: /etc/nginx/conf.d/openshift.conf
      configMap: budibase-proxy-openshift
      readOnly: true

# CouchDB configuration - Modified for OpenShift compatibility
couchdb:
  persistence:
    storageClass: "${DEFAULT_SC}"
    size: 5Gi
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 512Mi
  serviceAccount:
    create: true
    name: "budibase-couchdb"
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
  containerSecurityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
  initContainers:
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL

# Redis configuration
redis:
  master:
    persistence:
      storageClass: "${DEFAULT_SC}"
      size: 1Gi
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 128Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
  slave:
    resources:
      limits:
        cpu: 100m
        memory: 128Mi
      requests:
        cpu: 50m
        memory: 64Mi

# Minio configuration
minio:
  persistence:
    storageClass: "${DEFAULT_SC}"
    size: 5Gi
  resources:
    limits:
      cpu: 200m
      memory: 512Mi
    requests:
      cpu: 50m
      memory: 256Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL

# Use Routes instead of Ingress for OpenShift
ingress:
  enabled: false

# Enable OpenShift Routes
route:
  enabled: true
  host: budibase.${CLUSTER_DOMAIN}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Add the Budibase Helm repository
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/
helm repo update

# Install Budibase
echo -e "${YELLOW}Installing Budibase in project $PROJECT_NAME...${NC}"
helm install budibase budibase/budibase -f values.yaml -n $PROJECT_NAME

echo -e "${GREEN}Installation command completed. Checking pod status...${NC}"
echo -e "${YELLOW}Waiting for pods to start (this may take a few minutes)...${NC}"
sleep 15

# Check pod status
echo -e "${YELLOW}Initial pod status:${NC}"
oc get pods -n $PROJECT_NAME

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Access your Budibase instance at: ${NC}https://budibase.${CLUSTER_DOMAIN}"
echo -e "${YELLOW}Note: It may take several minutes for all pods to start and the route to become available.${NC}"