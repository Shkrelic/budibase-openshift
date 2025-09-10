# Budibase OpenShift Configuration

This repository contains minimal configuration files needed to run Budibase on OpenShift environments.

## Overview

The standard Budibase Helm chart requires some modifications to work properly in OpenShift due to its stricter security model. This repository provides only the essential changes needed for OpenShift compatibility without deviating from the standard deployment.

## Quick Installation

1. Clone this repository:
```bash
git clone https://github.com/Shkrelic/budibase-openshift.git
cd budibase-openshift
```

2. Make the installation script executable:
```bash
chmod +x openshift-install.sh
```

3. Run the installation script:
```bash
./openshift-install.sh
```

The script will:
- Detect your OpenShift cluster domain
- Create a minimal values.yaml file with OpenShift compatibility settings
- Add the Budibase Helm repository
- Create the budibase namespace if it doesn't exist
- Install Budibase with the OpenShift-compatible values

## What's Modified?

This configuration makes only the minimal changes required for OpenShift compatibility:

1. Security context settings for containers that would otherwise try to run as root
2. OpenShift Route configuration instead of Kubernetes Ingress
3. Storage class configuration for persistent volumes

## Manual Installation

If you prefer to install manually:

1. Edit the values.yaml file to update:
   - Storage classes based on your environment (`nfs`, `thin`, or `thin-csi`)
   - Route hostname to match your cluster's domain

2. Install using Helm:
```bash
helm repo add budibase https://budibase.github.io/budibase/
helm repo update
helm install budibase budibase/budibase -f values.yaml -n budibase --create-namespace
```

## Troubleshooting

If you encounter issues:

1. Check pod status:
```bash
oc get pods -n budibase
```

2. View pod logs:
```bash
oc logs <pod-name> -n budibase
```

3. Describe pods for detailed error information:
```bash
oc describe pod <pod-name> -n budibase
```