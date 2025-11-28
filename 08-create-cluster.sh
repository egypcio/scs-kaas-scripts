#!/bin/bash
set -e
# We need settings
# unset KUBECONFIG
if test -n "$1"; then
	SET="$1"
else
	if test -e cluster-settings.env; then SET=cluster-settings.env;
	else echo "You need to pass a cluster-settings.env file as parameter"; exit 1
	fi
fi
# Read settings -- make sure you can trust it
source "$SET"
# Sanity checks 
if test -z "$CS_MAINVER"; then echo "Configure CS_MAINVER"; exit 2; fi
if test -z "$CS_VERSION"; then echo "Configure CS_VERSION"; exit 3; fi
if test -z "$CS_SERIES"; then echo "Configure CS_SERIES, default to scs2"; CS_SERIES=scs2; fi
if test -z "$CL_PATCHVER"; then echo "Configure CL_PATCHVER"; exit 4; fi
if test -z "$CL_NAME"; then echo "Configure CL_NAME"; exit 5; fi
if test -z "$CL_PODCIDR"; then echo "Configure CL_PODCIDR"; exit 6; fi
if test -z "$CL_SVCCIDR"; then echo "Configure CL_SVCCIDR"; exit 7; fi
if test -z "$CL_CTRLNODES"; then echo "Configure CL_CTRLNODES"; exit 8; fi
if test -z "$CL_WRKRNODES"; then echo "Configure CL_WRKRNODES"; exit 9; fi
# Create Cluster yaml
# If we have an array, match what CS_VERSION we want to wait for
if test "${CS_VERSION:0:1}" = "["; then
	VERSIONS=$(kubectl get clusterstackreleases -n $CS_NAMESPACE -o "custom-columns=NAME:.metadata.name,K8SVER:.status.kubernetesVersion")
	while read csnm k8sver; do
		if test "$csnm" = "NAME"; then continue; fi
		if test "$k8sver" = "v$CL_PATCHVER"; then
			CS_VERSION="v${csnm#openstack-${CS_SERIES}-?-??-v}"
			CS_VERSION="${CS_VERSION//-/.}"
			CS_VERSION="${CS_VERSION/./-}"
			break
		fi
	done < <(echo "$VERSIONS")
	if test "${CS_VERSION:0:1}" = "["; then echo "No clusterstackrelease with v$CL_PATCHVER found"; exit 10; fi
fi
# TODO: There are a number of variables that allow us to set things like
#  flavors, disk sizes, loadbalancer types, etc.
if test -n "$CL_APPCRED_LIFETIME" -a "$CL_APPCRED_LIFETIME" != "0"; then
	SECRETSUFFIX=-$CL_NAME
else
	unset SECRETSUFFIX
fi
# Distinguish between old (cloud.config) and new style (clouds.yaml) secrets
# This depends on the clusterstackrelease, not on whether or not we have a newsecret
#if kubectl get -n $CS_NAMESPACE clusterstackreleases.clusterstack.x-k8s.io openstack-${CS_SERIES}-${CS_MAINVER/./-}-${CS_VERSION/./-} -o jsonpath='{.status.resources}' | grep openstack-${CS_SERIES}-${CS_MAINVER/./-}-${CS_VERSION}-clouds-yaml >/dev/null 2>&1; then
if test "$CS_SERIES" = "scs2"; then
	CFGSTYLE="clouds-yaml"
else
	CFGSTYLE=$(kubectl get clusterclasses.cluster.x-k8s.io -n $CS_NAMESPACE openstack-${CS_SERIES}-${CS_MAINVER/./-}-$CS_VERSION -o jsonpath='{.metadata.annotations.configStyle}' || true)
fi
if test "$CFGSTYLE" = "clouds-yaml"; then
	MGD_SEC="managed-secret: clouds-yaml$SECRETSUFFIX"
else
	MGD_SEC="managed-secret: cloud-config$SECRETSUFFIX"
fi
# Additional variables
#  Compatibility with old defaults
if ! grep CL_VARIABLES "$SET" >/dev/null 2>&1; then
	if test "$CS_SERIES" = "scs2"; then
		CL_VARIABLES="apiServerLoadBalancer=octavia-ovn"
	else
		CL_VARIABLES="apiserver_loadbalancer=octavia-ovn"
	fi
fi
#  Turn them into YAML
if test -n "$CL_VARIABLES"; then
	CL_VARS="    variables:
"
	while read KVPAIR; do
		KEY="${KVPAIR%%=*}"
		KEY="${KEY## *}"
		VAL="${KVPAIR#*=}"
		CL_VARS="$CL_VARS      - name: $KEY
        value: $VAL
"
	done < <(echo "$CL_VARIABLES" | sed 's/;/\n/g')
	# echo "$CL_VARS"
fi
#  We need to make them visible!
cat > ~/tmp/cluster-$CL_NAME.yaml <<EOF
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: "$CL_NAME"
  namespace: "$CS_NAMESPACE"
  labels:
    $MGD_SEC
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - "$CL_PODCIDR"
    serviceDomain: cluster.local
    services:
      cidrBlocks:
      - "$CL_SVCCIDR"
  topology:
    class: openstack-${CS_SERIES}-${CS_MAINVER/./-}-$CS_VERSION
    controlPlane:
      replicas: $CL_CTRLNODES
    version: v$CL_PATCHVER
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: $CL_WRKRNODES
$CL_VARS
EOF
kubectl apply -f ~/tmp/cluster-$CL_NAME.yaml
