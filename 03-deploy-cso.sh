#!/bin/bash
# Deploy CSO
set -e
mkdir -p ~/tmp
# We need settings (not really yet)
unset KUBECONFIG
if test -n "$1"; then
	SET="$1"
else
	if test -e cluster-settings.env; then SET=cluster-settings.env;
	else echo "You need to pass a cluster-settings.env file as parameter"; exit 1
	fi
fi
# Deploy CSO
cat > ~/tmp/cso-rbac.yaml <<EOF
clusterStackVariables:
  ociRepository: registry.scs.community/kaas/cluster-stacks
controllerManager:
  rbac:
    additionalRules:
      - apiGroups:
          - "openstack.k-orc.cloud"
        resources:
          - "images"
        verbs:
          - create
          - delete
          - get
          - list
          - patch
          - update
          - watch
EOF
# Install Cluster Stack Operator (CSO) with above values
helm upgrade -i cso -n cso-system \
	--create-namespace --values ~/tmp/cso-rbac.yaml \
    --set octavia_ovn=true \
	oci://registry.scs.community/cluster-stacks/cso

kubectl -n cso-system rollout status deployment
