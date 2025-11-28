#!/bin/bash
# (c) Kurt Garloff <s7n@garloff.de>, 5/2025
# SPDX-License-Identifier: CC-BY-SA-4.0
set -e
THISDIR=$(dirname $0)
# We need settings
unset KUBECONFIG
if test -n "$1"; then
	SET="$1"
else
	if test -e cluster-settings.env; then SET=cluster-settings.env;
	else echo "You need to pass a cluster-settings.env file as parameter"; exit 1
	fi
fi
# Read settings -- make sure you can trust it
source "$SET"
# Use workload cluster
export KUBECONFIG=~/.kube/$CS_NAMESPACE.$CL_NAME
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
# Patch configMap for cilium -- this won't be effective after kube-proxy is running already
echo "Note: If kube-proxy is already running, we won't have kube-proxy-less mode ..."
kubectl patch -n kube-system configmap cilium-config -p '.data.kube-proxy-replacement: true'
