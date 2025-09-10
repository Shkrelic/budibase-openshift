#!/bin/bash
# Simple test with the correct nginx-unprivileged image

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Nginx Unprivileged - OpenShift Test${NC}"

# Verify that user is logged into OpenShift
if ! oc whoami &>/dev/null; then
  echo -e "${RED}You are not logged into OpenShift. Please run 'oc login' first.${NC}"
  exit 1
fi
echo -e "${GREEN}Authenticated as: $(oc whoami)${NC}"

# Project setup
PROJECT_NAME="nginx-test"
echo -e "${YELLOW}Setting up project $PROJECT_NAME...${NC}"

# Delete existing project if it exists
if oc get project $PROJECT_NAME &>/dev/null; then
  echo -e "${YELLOW}Deleting existing project $PROJECT_NAME...${NC}"
  oc delete project $PROJECT_NAME
  
  echo -e "${YELLOW}Waiting for project deletion to complete...${NC}"
  while oc get project $PROJECT_NAME &>/dev/null; do
    echo -n "."
    sleep 5
  done
  echo ""
  sleep 5
fi

# Create project
echo -e "${YELLOW}Creating project $PROJECT_NAME...${NC}"
oc new-project $PROJECT_NAME

# Create a simple hello world deployment with the correct image
echo -e "${YELLOW}Creating Deployment with nginxinc/nginx-unprivileged...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-hello
  template:
    metadata:
      labels:
        app: nginx-hello
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:latest
        ports:
        - containerPort: 8080
EOF

# Create service
echo -e "${YELLOW}Creating Service...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: v1
kind: Service
metadata:
  name: nginx-hello
spec:
  selector:
    app: nginx-hello
  ports:
  - port: 8080
    targetPort: 8080
EOF

# Create route
echo -e "${YELLOW}Creating Route...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nginx-hello
spec:
  to:
    kind: Service
    name: nginx-hello
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Wait for deployment
echo -e "${YELLOW}Waiting for deployment to be ready...${NC}"
oc rollout status deployment/nginx-hello -n $PROJECT_NAME

# Check pod status
echo -e "${YELLOW}Pod status:${NC}"
oc get pods -n $PROJECT_NAME

# Get route URL
ROUTE_URL=$(oc get route nginx-hello -n $PROJECT_NAME -o jsonpath='{.spec.host}')
echo -e "${GREEN}Your nginx hello world is available at: ${NC}https://$ROUTE_URL"