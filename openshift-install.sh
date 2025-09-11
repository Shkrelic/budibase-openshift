#!/bin/bash
# Comprehensive Budibase OpenShift Installer
# Addressing all requirements with minimal config changes

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Budibase OpenShift Installer (Comprehensive)${NC}"
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

# Method 1: From console route
CONSOLE_ROUTE=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null)
if [ ! -z "$CONSOLE_ROUTE" ]; then
  CLUSTER_DOMAIN=${CONSOLE_ROUTE#console.}
  echo -e "${GREEN}Discovered domain from console route: ${CLUSTER_DOMAIN}${NC}"
fi

# Method 2: From any other route if method 1 fails
if [ -z "$CLUSTER_DOMAIN" ]; then
  for PROJECT in $(oc projects -o name 2>/dev/null | cut -d'/' -f2); do
    if [ -z "$PROJECT" ]; then continue; fi
    
    ROUTE=$(oc -n $PROJECT get routes -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
    if [ ! -z "$ROUTE" ]; then
      CLUSTER_DOMAIN=$(echo $ROUTE | grep -o '[^.]*\..*')
      if [ ! -z "$CLUSTER_DOMAIN" ]; then
        CLUSTER_DOMAIN=${CLUSTER_DOMAIN#*.}
        echo -e "${GREEN}Discovered domain from route in $PROJECT: ${CLUSTER_DOMAIN}${NC}"
        break
      fi
    fi
  done
fi

# Method 3: From API server URL if other methods fail
if [ -z "$CLUSTER_DOMAIN" ]; then
  API_URL=$(oc whoami --show-server 2>/dev/null)
  if [[ $API_URL =~ api\.([^:]+) ]]; then
    CLUSTER_DOMAIN="${BASH_REMATCH[1]}"
    # Replace the 'api' prefix with 'apps'
    CLUSTER_DOMAIN="apps.${CLUSTER_DOMAIN#api.}"
    echo -e "${GREEN}Discovered domain from API URL: ${CLUSTER_DOMAIN}${NC}"
  fi
fi

# Fallback to manual input if auto-detection fails
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo -e "${YELLOW}Could not auto-discover cluster domain.${NC}"
  read -p "Enter your cluster domain (e.g., apps.openshift.example.com): " CLUSTER_DOMAIN
fi

echo -e "${GREEN}Using cluster domain: ${CLUSTER_DOMAIN}${NC}"

# Project management
PROJECT_NAME="budibase"
echo -e "${YELLOW}Setting up project for Budibase...${NC}"

# Check if project exists
if oc get project $PROJECT_NAME &>/dev/null; then
  echo -e "${YELLOW}Project '$PROJECT_NAME' already exists.${NC}"
  read -p "Do you want to delete and recreate it? (y/n): " DELETE_PROJECT
  if [[ $DELETE_PROJECT == "y" || $DELETE_PROJECT == "Y" ]]; then
    echo -e "${YELLOW}Deleting project '$PROJECT_NAME'...${NC}"
    oc delete project $PROJECT_NAME
    
    echo -e "${YELLOW}Waiting for project deletion to complete. This may take several minutes...${NC}"
    # Extended timeout - 5 minutes
    TIMEOUT=300
    COUNTER=0
    while oc get project $PROJECT_NAME &>/dev/null; do
      echo -n "."
      sleep 10
      COUNTER=$((COUNTER+10))
      if [ $COUNTER -ge $TIMEOUT ]; then
        echo -e "\n${RED}Timeout waiting for project deletion.${NC}"
        echo -e "${YELLOW}Please wait longer and run the script again when the project is fully deleted.${NC}"
        exit 1
      fi
    done
    echo -e "\n${GREEN}Project deleted.${NC}"
    
    # Extended wait to ensure project is fully cleaned up in the API
    echo -e "${YELLOW}Ensuring project is fully removed from the system...${NC}"
    sleep 60
    
    # Create the project
    echo -e "${YELLOW}Creating project '$PROJECT_NAME'...${NC}"
    if ! oc new-project $PROJECT_NAME; then
      echo -e "${RED}Failed to create project.${NC}"
      exit 1
    fi
  fi
else
  # Create the project
  echo -e "${YELLOW}Creating project '$PROJECT_NAME'...${NC}"
  if ! oc new-project $PROJECT_NAME; then
    echo -e "${RED}Failed to create project.${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}Using project: $PROJECT_NAME${NC}"

# Storage class selection
echo -e "${YELLOW}Detecting available storage classes...${NC}"
STORAGE_CLASSES=$(oc get storageclass -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)

DEFAULT_SC=""

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
  echo -e "${YELLOW}Could not retrieve storage classes.${NC}"
  read -p "Enter storage class name to use: " DEFAULT_SC
fi

# Create a ConfigMap with our init script to patch nginx configuration
echo -e "${YELLOW}Creating ConfigMap with nginx patch script...${NC}"

cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: budibase-nginx-patch
  namespace: budibase
data:
  patch-nginx.sh: |
    #!/bin/bash
    # Script to modify nginx config for OpenShift
    
    echo "Patching nginx configuration for OpenShift compatibility..."
    
    # Create temp directories with correct permissions
    mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp
    chmod 777 /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp
    
    # Create a backup of original config
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
    
    # Modify the nginx configuration with sed
    # 1. Change error log path
    sed -i 's|error_log.*|error_log               /tmp/error.log debug;|' /etc/nginx/nginx.conf
    
    # 2. Change pid file path
    sed -i 's|pid.*|pid                     /tmp/nginx.pid;|' /etc/nginx/nginx.conf
    
    # 3. Add temp paths in http section
    sed -i '/http {/a \
      # Temp paths in writable /tmp directory\
      client_body_temp_path /tmp/client_temp;\
      proxy_temp_path       /tmp/proxy_temp;\
      fastcgi_temp_path     /tmp/fastcgi_temp;\
      uwsgi_temp_path       /tmp/uwsgi_temp;\
      scgi_temp_path        /tmp/scgi_temp;' /etc/nginx/nginx.conf
    
    # 4. Change access log path
    sed -i 's|access_log /var/log/nginx/access.log main;|access_log /tmp/access.log main;|' /etc/nginx/nginx.conf
    
    # No need to change port since 10000 is already unprivileged
    
    echo "Nginx configuration patched successfully!"
    
    # Execute the original command
    exec "$@"
EOF

# Create OpenShift-compatible values.yaml
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"

cat > values.yaml << EOF
# OpenShift-compatible Budibase configuration

# Adding resource limits for all components
services:
  # Proxy service configuration with patches for OpenShift
  proxy:
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 128Mi
    # Add volumes for our patch
    extraVolumes:
      - name: nginx-patch
        configMap:
          name: budibase-nginx-patch
          defaultMode: 0755
      - name: tmp-volume
        emptyDir: {}
    extraVolumeMounts:
      - name: nginx-patch
        mountPath: /usr/local/bin/patch-nginx.sh
        subPath: patch-nginx.sh
      - name: tmp-volume
        mountPath: /tmp
    # Override command to run our patch script first
    command:
      - /bin/sh
      - -c
      - |
        /usr/local/bin/patch-nginx.sh nginx -g 'daemon off;'
  
  # Apps service configuration
  apps:
    resources:
      limits:
        cpu: 500m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 512Mi
  
  # Worker service configuration
  worker:
    resources:
      limits:
        cpu: 300m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 256Mi
  
  # Automation workers
  automationWorkers:
    resources:
      limits:
        cpu: 200m
        memory: 512Mi
      requests:
        cpu: 50m
        memory: 128Mi
  
  # Redis configuration
  redis:
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 128Mi
    storageClass: "${DEFAULT_SC}"
    storage: 1Gi
  
  # Object storage (MinIO) configuration
  objectStore:
    resources:
      limits:
        cpu: 200m
        memory: 512Mi
      requests:
        cpu: 50m
        memory: 256Mi
    storage: 5Gi
    storageClass: "${DEFAULT_SC}"

# CouchDB configuration
couchdb:
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 512Mi
  persistence:
    enabled: true
    size: 5Gi
    storageClass: "${DEFAULT_SC}"

# Use OpenShift Route instead of Ingress
ingress:
  enabled: false

# Create Route definition
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

echo -e "${GREEN}Installation started. Waiting for pods to be created...${NC}"
sleep 30

# Check pod status
echo -e "${YELLOW}Initial pod status:${NC}"
oc get pods -n $PROJECT_NAME

# Wait for the proxy deployment to be available
echo -e "${YELLOW}Waiting for pods to come online (this may take several minutes)...${NC}"

# Wait for the app-service pod to be ready (one of the last to come up)
TIMEOUT=300
COUNTER=0
APP_POD_READY=false

while [ "$APP_POD_READY" = false ] && [ $COUNTER -lt $TIMEOUT ]; do
  APP_POD_STATUS=$(oc get pods -n $PROJECT_NAME -l app.kubernetes.io/name=budibase-apps -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  
  if [ "$APP_POD_STATUS" = "Running" ]; then
    APP_POD_READY=true
    echo -e "${GREEN}App service pod is running!${NC}"
  else
    echo -n "."
    sleep 10
    COUNTER=$((COUNTER+10))
  fi
done

if [ "$APP_POD_READY" = false ]; then
  echo -e "\n${YELLOW}Timeout waiting for app pod to be ready, but installation is still in progress.${NC}"
  echo -e "${YELLOW}This is normal - Budibase takes time to fully initialize.${NC}"
else
  echo -e "${GREEN}Budibase pods are coming online.${NC}"
fi

# Get route URL
echo -e "${YELLOW}Checking route...${NC}"
ROUTE_URL=$(oc get route -n $PROJECT_NAME -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
if [ ! -z "$ROUTE_URL" ]; then
  echo -e "${GREEN}Your Budibase instance will be available at: ${NC}https://$ROUTE_URL"
else
  echo -e "${YELLOW}Route not found or not yet created.${NC}"
  echo -e "${YELLOW}Your Budibase instance will be available at: ${NC}https://budibase.${CLUSTER_DOMAIN}"
fi

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Note: It may take several minutes for all pods to start and become ready.${NC}"

# Provide troubleshooting tips
echo -e "${BLUE}Troubleshooting Tips:${NC}"
echo -e "1. Check pod status: ${YELLOW}oc get pods -n $PROJECT_NAME${NC}"
echo -e "2. View logs for a pod: ${YELLOW}oc logs <pod-name> -n $PROJECT_NAME${NC}"
echo -e "3. Check routes: ${YELLOW}oc get routes -n $PROJECT_NAME${NC}"
echo -e "4. To uninstall: ${YELLOW}helm uninstall budibase -n $PROJECT_NAME${NC}"
echo -e "5. To check persistent volumes: ${YELLOW}oc get pvc -n $PROJECT_NAME${NC}"
echo -e "6. To check for events: ${YELLOW}oc get events -n $PROJECT_NAME${NC}"