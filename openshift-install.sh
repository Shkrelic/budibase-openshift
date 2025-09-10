#!/bin/bash
# Enhanced Budibase deployment script for OpenShift with resource quota support
# Designed for users with limited privileges

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
for PROJECT in $(oc get projects -o name 2>/dev/null | cut -d'/' -f2); do
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
  read -p "Do you want to delete and recreate it? (y/n): " RECREATE
  if [[ $RECREATE =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deleting project '$PROJECT_NAME'...${NC}"
    oc delete project $PROJECT_NAME
    echo -e "${YELLOW}Waiting for project deletion to complete...${NC}"
    while oc get project $PROJECT_NAME &>/dev/null; do
      echo -n "."
      sleep 2
    done
    echo -e "\n${GREEN}Project deleted.${NC}"
    
    echo -e "${YELLOW}Creating new project '$PROJECT_NAME'...${NC}"
    if ! oc new-project $PROJECT_NAME; then
      echo -e "${RED}Failed to create project. You may not have permission.${NC}"
      read -p "Enter an existing project to use instead: " PROJECT_NAME
      if ! oc project $PROJECT_NAME &>/dev/null; then
        echo -e "${RED}Cannot access project '$PROJECT_NAME'. Exiting.${NC}"
        exit 1
      fi
    fi
  else
    echo -e "${GREEN}Using existing project '$PROJECT_NAME'.${NC}"
    oc project $PROJECT_NAME &>/dev/null
  fi
else
  echo -e "${YELLOW}Project '$PROJECT_NAME' does not exist. Attempting to create...${NC}"
  if ! oc new-project $PROJECT_NAME; then
    echo -e "${RED}Failed to create project. You may not have permission.${NC}"
    read -p "Enter an existing project to use instead: " PROJECT_NAME
    if ! oc project $PROJECT_NAME &>/dev/null; then
      echo -e "${RED}Cannot access project '$PROJECT_NAME'. Exiting.${NC}"
      exit 1
    fi
  fi
fi

echo -e "${GREEN}Using project: $PROJECT_NAME${NC}"

# Check project quotas
echo -e "${YELLOW}Checking project resource quotas...${NC}"
PROJECT_QUOTA=$(oc get resourcequota -n $PROJECT_NAME -o jsonpath='{.items[*].spec.hard}' 2>/dev/null)
if [ ! -z "$PROJECT_QUOTA" ]; then
  echo -e "${YELLOW}Project has resource quotas: ${PROJECT_QUOTA}${NC}"
  echo -e "${YELLOW}Adjusting Budibase resource limits to fit within quota...${NC}"
fi

# Storage class selection
echo -e "${YELLOW}Checking available storage classes...${NC}"
STORAGE_CLASSES=$(oc get storageclass -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)

if [ ! -z "$STORAGE_CLASSES" ]; then
  echo -e "${GREEN}Available storage classes:${NC}"
  echo "$STORAGE_CLASSES" | nl -w2 -s') '
  
  # Attempt to identify common OpenShift storage classes
  if echo "$STORAGE_CLASSES" | grep -q "nfs"; then
    DEFAULT_SC="nfs"
  elif echo "$STORAGE_CLASSES" | grep -q "thin"; then
    DEFAULT_SC="thin"
  elif echo "$STORAGE_CLASSES" | grep -q "thin-csi"; then
    DEFAULT_SC="thin-csi"
  else
    DEFAULT_SC=$(echo "$STORAGE_CLASSES" | head -n1)
  fi
  
  echo -e "${YELLOW}Default storage class will be: ${DEFAULT_SC}${NC}"
  read -p "Use this storage class? (y/n): " USE_DEFAULT_SC
  
  if [[ ! $USE_DEFAULT_SC =~ ^[Yy]$ ]]; then
    read -p "Enter the number of the storage class to use: " SC_NUM
    SELECTED_SC=$(echo "$STORAGE_CLASSES" | sed -n "${SC_NUM}p")
    if [ ! -z "$SELECTED_SC" ]; then
      DEFAULT_SC=$SELECTED_SC
    fi
  fi
  
  echo -e "${GREEN}Using storage class: ${DEFAULT_SC}${NC}"
else
  echo -e "${YELLOW}Could not retrieve storage classes. Using default (nfs).${NC}"
  DEFAULT_SC="nfs"
fi

# Create OpenShift-compatible values.yaml with resource limits
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"

cat > values.yaml << EOF
# OpenShift-compatible Budibase configuration

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

# Proxy settings - Modified for OpenShift compatibility
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
    capabilities:
      drop:
      - ALL
    readOnlyRootFilesystem: false

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
  # Ensure Redis slave pods have resource limits too
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

# Ensure all init containers have resource limits
initContainers:
  resources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi

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

# Global resource constraints for any containers not explicitly configured
global:
  defaultResources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi
EOF

# Add the Budibase Helm repository
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/
helm repo update

# Install Budibase
echo -e "${YELLOW}Installing Budibase in project $PROJECT_NAME...${NC}"
helm install budibase budibase/budibase -f values.yaml -n $PROJECT_NAME

# Wait for pods to start initializing
echo -e "${GREEN}Installation command completed. Checking pod status...${NC}"
echo -e "${YELLOW}Waiting for pods to start (this may take a few minutes)...${NC}"
sleep 15

# Check pod status
echo -e "${YELLOW}Initial pod status:${NC}"
oc get pods -n $PROJECT_NAME

# Check for pods in Pending state
PENDING_PODS=$(oc get pods -n $PROJECT_NAME -o jsonpath='{.items[?(@.status.phase=="Pending")].metadata.name}')
if [ ! -z "$PENDING_PODS" ]; then
  echo -e "${RED}Some pods are in Pending state. Checking reasons...${NC}"
  for POD in $PENDING_PODS; do
    echo -e "${YELLOW}Details for pod $POD:${NC}"
    oc describe pod $POD -n $PROJECT_NAME | grep -A5 "Status:" | grep -A5 "Message:"
  done
  
  echo -e "${YELLOW}If pods are pending due to resource constraints, you may need to:${NC}"
  echo -e "1. Reduce resource limits in values.yaml"
  echo -e "2. Increase project quotas (requires admin)"
  echo -e "3. Use a different namespace with higher quotas"
fi

# Check for events that might indicate quota issues
echo -e "${YELLOW}Checking for quota-related events:${NC}"
oc get events -n $PROJECT_NAME | grep -E 'quota|resources|limit|exceed'

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Access your Budibase instance at: ${NC}https://budibase.${CLUSTER_DOMAIN}"
echo -e "${YELLOW}Note: It may take a few minutes for all pods to start and the route to become available.${NC}"
echo -e "${YELLOW}If pods are not starting due to resource constraints, edit values.yaml and reinstall.${NC}"