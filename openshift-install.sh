#!/bin/bash
# Simplified Budibase OpenShift Installer
# Focus on service account and minimal changes

# Setup project
PROJECT_NAME="budibase"
echo "Setting up project $PROJECT_NAME..."

# Get cluster domain
CLUSTER_DOMAIN=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console\.//')
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "Couldn't auto-discover cluster domain"
  read -p "Enter your cluster domain (e.g., apps.openshift.example.com): " CLUSTER_DOMAIN
fi
echo "Using cluster domain: $CLUSTER_DOMAIN"

# Delete existing project if it exists
if oc get project $PROJECT_NAME &>/dev/null; then
  echo "Deleting existing project $PROJECT_NAME..."
  oc delete project $PROJECT_NAME
  
  echo "Waiting for project deletion to complete..."
  while oc get project $PROJECT_NAME &>/dev/null; do
    sleep 5
  done
  sleep 10
fi

# Create project
echo "Creating project $PROJECT_NAME..."
oc new-project $PROJECT_NAME

# Auto-select storage class
DEFAULT_SC=$(oc get storageclass -o name | head -n1)
DEFAULT_SC=${DEFAULT_SC#storageclass.storage.k8s.io/}
echo "Using storage class: $DEFAULT_SC"

# Create values.yaml using the proper chart structure
cat > values.yaml << EOF
# OpenShift-compatible Budibase configuration

# Service account configuration for proxy (addressing issue #8229)
serviceAccount:
  create: true
  name: "budibase-proxy"

# Proxy configuration
services:
  proxy:
    image:
      repository: nginx
      tag: unprivileged
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 128Mi
    # Volume for nginx temp directories
    extraVolumes:
      - name: nginx-temp
        emptyDir: {}
    extraVolumeMounts:
      - name: nginx-temp
        mountPath: /tmp
  
  couchdb:
    enabled: true
  
  objectStore:
    storageClass: "${DEFAULT_SC}"
    storage: 5Gi
  
  redis:
    storageClass: "${DEFAULT_SC}"

# CouchDB configuration
couchdb:
  persistence:
    storageClass: "${DEFAULT_SC}"
    size: 5Gi

# Use OpenShift Route instead of Ingress
ingress:
  enabled: false

# Create Route
route:
  enabled: true
  host: budibase.${CLUSTER_DOMAIN}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Install Budibase
echo "Adding Budibase Helm repository..."
helm repo add budibase https://budibase.github.io/budibase/
helm repo update

echo "Installing Budibase..."
helm install budibase budibase/budibase -f values.yaml -n $PROJECT_NAME

echo "Budibase installation started."
echo "Access your Budibase instance at: https://budibase.${CLUSTER_DOMAIN}"
echo "Note: It may take several minutes for all pods to start."