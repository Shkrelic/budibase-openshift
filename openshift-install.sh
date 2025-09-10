#!/bin/bash
# Comprehensive Budibase deployment script for OpenShift
# With nginx permission fix and resource limits

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
    # Replace the 'api' prefix with 'apps'
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

# Create nginx-init ConfigMap for initialization script
echo -e "${YELLOW}Creating nginx initialization ConfigMap...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-init-script
  namespace: $PROJECT_NAME
data:
  init.sh: |
    #!/bin/sh
    # Script to create and set permissions for nginx temp directories
    mkdir -p /tmp/nginx/client_temp
    mkdir -p /tmp/nginx/proxy_temp
    mkdir -p /tmp/nginx/fastcgi_temp
    mkdir -p /tmp/nginx/uwsgi_temp
    mkdir -p /tmp/nginx/scgi_temp
    chmod 777 /tmp/nginx /tmp/nginx/*
    # Symlink the default nginx cache directories to our writable ones
    mkdir -p /var/cache/nginx
    ln -sf /tmp/nginx/client_temp /var/cache/nginx/client_temp
    ln -sf /tmp/nginx/proxy_temp /var/cache/nginx/proxy_temp
    ln -sf /tmp/nginx/fastcgi_temp /var/cache/nginx/fastcgi_temp
    ln -sf /tmp/nginx/uwsgi_temp /var/cache/nginx/uwsgi_temp
    ln -sf /tmp/nginx/scgi_temp /var/cache/nginx/scgi_temp
    # Set permissions again to be safe
    chmod 777 /var/cache/nginx /var/cache/nginx/*
    echo "Nginx temp directories prepared"
EOF

# Create LimitRange to ensure all pods have default limits
echo -e "${YELLOW}Creating LimitRange for default resource limits...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: v1
kind: LimitRange
metadata:
  name: budibase-limits
  namespace: $PROJECT_NAME
spec:
  limits:
  - default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 256Mi
    type: Container
EOF

# Create OpenShift-compatible values.yaml with nginx fix
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"

cat > values.yaml << EOF
# OpenShift-compatible Budibase configuration

global:
  openshift: true

# App service
app:
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

# Worker service
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

# Proxy settings with complete nginx fix
proxy:
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
  containerSecurityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    runAsUser: null
    fsGroup: null
  extraVolumes:
    - name: nginx-temp
      emptyDir: {}
    - name: nginx-init
      configMap:
        name: nginx-init-script
        defaultMode: 0777
  extraVolumeMounts:
    - name: nginx-temp
      mountPath: /tmp/nginx
  initContainers:
    - name: nginx-init
      image: busybox
      command: ["/bin/sh", "/nginx-init/init.sh"]
      securityContext:
        runAsNonRoot: false
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: nginx-init
          mountPath: /nginx-init
        - name: nginx-temp
          mountPath: /tmp/nginx

# CouchDB configuration
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
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
  containerSecurityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false

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
  slave:
    resources:
      limits:
        cpu: 100m
        memory: 128Mi
      requests:
        cpu: 50m
        memory: 64Mi
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false

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

# Routes instead of Ingress
ingress:
  enabled: false

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

echo -e "${GREEN}Installation command completed. Waiting for pods to start...${NC}"
echo -e "${YELLOW}This may take a few minutes...${NC}"
sleep 15

# Check pod status
echo -e "${YELLOW}Initial pod status:${NC}"
oc get pods -n $PROJECT_NAME

# Direct patch for proxy deployment in case the initContainer approach doesn't work
echo -e "${YELLOW}Applying direct fix for proxy deployment...${NC}"
# Wait for proxy deployment to be created
PROXY_DEPLOY=""
TIMEOUT=60
COUNTER=0
while [ -z "$PROXY_DEPLOY" ] && [ $COUNTER -lt $TIMEOUT ]; do
  PROXY_DEPLOY=$(oc get deployment -n $PROJECT_NAME | grep proxy | awk '{print $1}')
  if [ -z "$PROXY_DEPLOY" ]; then
    echo -n "."
    sleep 5
    COUNTER=$((COUNTER+5))
  fi
done
echo ""

if [ ! -z "$PROXY_DEPLOY" ]; then
  # Create patch file
  cat > proxy-patch.yaml << EOF
spec:
  template:
    spec:
      volumes:
      - name: nginx-temp
        emptyDir: {}
      - name: nginx-init
        configMap:
          name: nginx-init-script
          defaultMode: 511
      initContainers:
      - name: nginx-init
        image: busybox
        command: 
        - /bin/sh
        - /nginx-init/init.sh
        securityContext:
          runAsNonRoot: false
          privileged: false
        volumeMounts:
        - name: nginx-init
          mountPath: /nginx-init
        - name: nginx-temp
          mountPath: /tmp/nginx
      containers:
      - name: proxy
        resources:
          limits:
            cpu: 200m
            memory: 256Mi
          requests:
            cpu: 50m
            memory: 128Mi
        volumeMounts:
        - name: nginx-temp
          mountPath: /tmp/nginx
        securityContext:
          privileged: false
EOF

  # Apply the patch
  oc patch deployment $PROXY_DEPLOY --patch "$(cat proxy-patch.yaml)" -n $PROJECT_NAME
  echo -e "${GREEN}Proxy deployment patched. It may take a moment to restart.${NC}"
fi

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Access your Budibase instance at: ${NC}https://budibase.${CLUSTER_DOMAIN}"
echo -e "${YELLOW}Note: It may take several minutes for all pods to start and the route to become available.${NC}"