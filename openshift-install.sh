#!/bin/bash
# Minimal OpenShift-compatibility script for Budibase deployment

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Budibase OpenShift deployment...${NC}"

# Create a temporary directory for the operation
TEMP_DIR=$(mktemp -d)
cd $TEMP_DIR

# Detect OpenShift cluster domain for route configuration
echo -e "${YELLOW}Detecting OpenShift cluster domain...${NC}"
CLUSTER_DOMAIN=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console//' | sed 's/^.//')

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo -e "${RED}Could not detect cluster domain automatically.${NC}"
  read -p "Please enter your cluster domain (e.g., .apps.openshift.example.com): " CLUSTER_DOMAIN
fi

echo -e "${GREEN}Using cluster domain: ${CLUSTER_DOMAIN}${NC}"

# Create minimal OpenShift-compatible values.yaml
echo -e "${YELLOW}Creating OpenShift-compatible values.yaml...${NC}"
cat > values.yaml << EOF
# Minimal OpenShift compatibility configuration for Budibase
# Only includes essential changes required for OpenShift

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
  host: budibase${CLUSTER_DOMAIN}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Add the Budibase Helm repository
echo -e "${YELLOW}Adding Budibase Helm repository...${NC}"
helm repo add budibase https://budibase.github.io/budibase/
helm repo update

# Create namespace if it doesn't exist
echo -e "${YELLOW}Creating namespace if it doesn't exist...${NC}"
oc create namespace budibase --dry-run=client -o yaml | oc apply -f -

# Install Budibase
echo -e "${YELLOW}Installing Budibase with OpenShift compatibility...${NC}"
helm install budibase budibase/budibase -f values.yaml -n budibase

echo -e "${GREEN}Installation command completed. Checking pod status...${NC}"
echo -e "${YELLOW}Waiting for pods to start (this may take a few minutes)...${NC}"
sleep 10

# Check pod status
oc get pods -n budibase

echo -e "${GREEN}Budibase installation process completed.${NC}"
echo -e "${YELLOW}Access your Budibase instance at: ${NC}https://budibase${CLUSTER_DOMAIN}"
echo -e "${YELLOW}Values file used for installation is available at: ${NC}${TEMP_DIR}/values.yaml"