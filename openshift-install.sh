#!/bin/bash
# Simplified script for Budibase deployment on OpenShift with least privilege

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Budibase OpenShift deployment...${NC}"

# Verify that user is logged into OpenShift
if ! oc whoami &>/dev/null; then
  echo -e "${RED}You are not logged into OpenShift. Please run 'oc login' first.${NC}"
  exit 1
fi

# Ask for the namespace to use
read -p "Enter namespace to deploy Budibase (must already exist): " NAMESPACE
if ! oc project $NAMESPACE &>/dev/null; then
  echo -e "${RED}Cannot access namespace '$NAMESPACE'. Please verify it exists and you have access.${NC}"
  exit 1
fi
echo -e "${GREEN}Using namespace: $NAMESPACE${NC}"

# Ask for the cluster domain
read -p "Enter your cluster domain (e.g., apps.openshift.example.com): " DOMAIN
# Ensure domain has proper format
if [[ $DOMAIN != apps.* ]]; then
  echo -e "${YELLOW}Domain should typically start with 'apps.' - continuing with provided value.${NC}"
fi
echo -e "${GREEN}Using domain: $DOMAIN${NC}"

# Create minimal OpenShift-compatible values.yaml
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"
cat > values.yaml << EOF
# Minimal OpenShift compatibility configuration for Budibase

global:
  openshift: true

# Critical security context settings for OpenShift
proxy:
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL

# CouchDB configuration - critical for OpenShift
couchdb:
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

# Storage configuration
couchdb:
  persistence:
    storageClass: "nfs"  # Options: nfs, thin, thin-csi
redis:
  master:
    persistence:
      storageClass: "nfs"  # Options: nfs, thin, thin-csi
minio:
  persistence:
    storageClass: "nfs"  # Options: nfs, thin, thin-csi

# Use Routes instead of Ingress for OpenShift
ingress:
  enabled: false

route:
  enabled: true
  host: budibase.$DOMAIN
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Add the Budibase Helm repository
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/
helm repo update

# Install Budibase
echo -e "${YELLOW}Installing Budibase in namespace $NAMESPACE...${NC}"
helm install budibase budibase/budibase -f values.yaml -n $NAMESPACE

echo -e "${GREEN}Installation command completed. Checking pod status...${NC}"
echo -e "${YELLOW}Waiting for pods to start (this may take a few minutes)...${NC}"
sleep 10

# Check pod status
oc get pods -n $NAMESPACE

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Access your Budibase instance at: ${NC}https://budibase.$DOMAIN"