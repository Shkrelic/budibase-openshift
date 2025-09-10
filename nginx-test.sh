#!/bin/bash
# Simple Nginx Hello World for OpenShift testing

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Nginx Hello World - OpenShift Test${NC}"
echo -e "${YELLOW}===============================${NC}"

# Verify that user is logged into OpenShift
if ! oc whoami &>/dev/null; then
  echo -e "${RED}You are not logged into OpenShift. Please run 'oc login' first.${NC}"
  exit 1
fi
echo -e "${GREEN}Authenticated as: $(oc whoami)${NC}"

# Project setup
PROJECT_NAME="nginx-test"
echo -e "${YELLOW}Setting up project $PROJECT_NAME...${NC}"

# Auto-discover cluster domain - multiple methods for reliability
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

# Delete existing project if it exists
if oc get project $PROJECT_NAME &>/dev/null; then
  echo -e "${YELLOW}Deleting existing project $PROJECT_NAME...${NC}"
  oc delete project $PROJECT_NAME
  
  echo -e "${YELLOW}Waiting for project deletion to complete...${NC}"
  TIMEOUT=60
  COUNTER=0
  while oc get project $PROJECT_NAME &>/dev/null; do
    echo -n "."
    sleep 5
    COUNTER=$((COUNTER+5))
    if [ $COUNTER -ge $TIMEOUT ]; then
      echo -e "\n${RED}Timeout waiting for project deletion. Continuing anyway...${NC}"
      break
    fi
  done
  echo ""
  sleep 5
fi

# Create project
echo -e "${YELLOW}Creating project $PROJECT_NAME...${NC}"
oc new-project $PROJECT_NAME

# Create a simple ConfigMap for the hello world content
echo -e "${YELLOW}Creating ConfigMap for hello world content...${NC}"
cat << EOF | oc apply -f - -n $PROJECT_NAME
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>Hello from Nginx on OpenShift</title>
      <style>
        body {
          font-family: Arial, sans-serif;
          margin: 40px;
          line-height: 1.6;
        }
        h1 {
          color: #2a76dd;
        }
        .info {
          background-color: #f5f5f5;
          padding: 20px;
          border-radius: 5px;
        }
      </style>
    </head>
    <body>
      <h1>Hello from Nginx on OpenShift!</h1>
      <div class="info">
        <p>This is a simple test page served by nginx-unprivileged.</p>
        <p>If you can see this page, the nginx container is running correctly on OpenShift.</p>
      </div>
    </body>
    </html>
EOF

# Create deployment for nginx-unprivileged
echo -e "${YELLOW}Creating Deployment with nginx-unprivileged...${NC}"
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
        image: nginx:unprivileged
        ports:
        - containerPort: 8080
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 50m
            memory: 64Mi
        volumeMounts:
        - name: nginx-html
          mountPath: /usr/share/nginx/html
        - name: nginx-temp
          mountPath: /tmp
      volumes:
      - name: nginx-html
        configMap:
          name: nginx-html
      - name: nginx-temp
        emptyDir: {}
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
  host: nginx-hello.$CLUSTER_DOMAIN
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

# Check route
ROUTE_URL=$(oc get route nginx-hello -n $PROJECT_NAME -o jsonpath='{.spec.host}')
echo -e "${GREEN}Your nginx hello world is available at: ${NC}https://$ROUTE_URL"
echo -e "${YELLOW}Testing connection to the route...${NC}"

# Test connection
if command -v curl &> /dev/null; then
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://$ROUTE_URL)
  if [ "$STATUS" = "200" ]; then
    echo -e "${GREEN}Connection successful! (HTTP 200)${NC}"
  else
    echo -e "${YELLOW}Got HTTP status code: $STATUS${NC}"
  fi
else
  echo -e "${YELLOW}curl not available, please check the URL manually${NC}"
fi

echo -e "${BLUE}===============================${NC}"
echo -e "${GREEN}Next steps:${NC}"
echo -e "1. Visit ${YELLOW}https://$ROUTE_URL${NC} to verify the nginx hello world page works"
echo -e "2. Check logs with: ${YELLOW}oc logs -f deployment/nginx-hello -n $PROJECT_NAME${NC}"
echo -e "3. Delete this test with: ${YELLOW}oc delete project $PROJECT_NAME${NC}"