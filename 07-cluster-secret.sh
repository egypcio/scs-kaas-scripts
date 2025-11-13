#!/bin/bash
# Create cloud secret -- alternative. Not yet complete.
set -e
# We need settings
unset KUBECONFIG
if test "$1" = "-f"; then shift; FORCE=1; fi
if test -n "$1"; then
	SET="$1"
else
	if test -e cluster-settings.env; then SET=cluster-settings.env;
	else echo "You need to pass a cluster-settings.env file as parameter"; exit 1
	fi
fi
# Read settings -- make sure you can trust it
source "$SET"
if test -z "$CS_SERIES"; then echo "Configure CS_SERIES, default to scs2"; CS_SERIES=scs2; fi
# Read helper
THISDIR=$(dirname $0)
source "$THISDIR/_yaml_parse.sh"

# Create namespace
# Our global clouds.yaml
CL_YAML=~/tmp/clouds-$OS_CLOUD.yaml
#export OS_CLOUD=openstack
CLOUDS_YAML=${CLOUDS_YAML:-~/.config/openstack/clouds.yaml}
CA=$(RMVTREE=1 extract_yaml clouds.$OS_CLOUD.cacert <$CLOUDS_YAML | sed 's/^\s*cacert: //' || true)
OS_CACERT="${OS_CACERT:-$CA}"
if test -n "$OS_CACERT"; then
	OS_CACERT=${OS_CACERT/\~/$HOME}
	CACERT_B64="$(base64 -w0 < $OS_CACERT)"
	CAINSERT="
  cacert: $CACERT_B64"
	CAFILE="
ca-file=/etc/config/cacert"
else
	unset CAINSERT
	unset CAFILE
fi

OLD_UMASK=$(umask)
CL_NAME_B64=$(echo -n openstack | base64 -w0)

# Deal with per-cluster secrets
# A few cases:
# 1. CL_APPCRED_LIFETIME=0 or empty: No AppCreds wanted
#   We then share one workload-cluster-secret (and newsecret) with all clusters with that setting
#   Make sure it exists and is up-to-date and create CRS to manage it
# 2. CL_APPCRED_LIFETIME=non-zero: We want per-cluster AppCreds (need openstacktools installed)
#   A. We still have one that's valid for at least a third of its lifetime: Do nothing
#   B. We have one, but it is about to expire or has expired: Renew it
#   C. We have none: Create one

# Store it securely in ~/tmp/clouds-$OS_CLOUD.yaml
echo "# Parsing ~/tmp/clouds-$OS_CLOUD.yaml ..."
YAMLASSIGN=1 extract_yaml clouds.openstack < ~/tmp/clouds-$OS_CLOUD.yaml >/dev/null
if test -z "$PREFER_AMPHORA"; then
	LB_OVN="lb-provider=ovn
lb-method=SOURCE_IP_PORT"
fi

# Helper: Create workload-secrets clouds.yaml and cloud.conf
#  and clusterresourceset structures to automanage them
# $1 => clouds.yaml to use
# $2 => cloud.conf to use
# $3 => Name suffix
create_clouds_yaml_conf_crs()
{
	CL_CONF_B64="$(base64 -w0 < $2)"
	CL_YAML_ALT_B64=$(base64 -w0 < <(sed 's@/etc/certs/cacert@/etc/openstack/cacert@' $1))
	# Workload cluster clouds-yaml
	CL_YAML_WL_B64=$(base64 -w0 <<EOT
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: clouds-yaml
  namespace: kube-system
data:
  clouds.yaml: $CL_YAML_ALT_B64$CAINSERT
  cloudName: $CL_NAME_B64
EOT
)
	# Workload cluster cloud-config
	CL_CONF_WL_B64=$(base64 -w0 <<EOT
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: cloud-config
  namespace: kube-system
data:
  cloud.conf: $CL_CONF_B64$CAINSERT
  cloudprovider.conf: $CL_CONF_B64
EOT
)
	kubectl apply -f - <<EOT
apiVersion: v1
data:
  clouds-yaml-secret: $CL_YAML_WL_B64
kind: Secret
metadata:
  name: openstack-workload-cluster-newsecret$3
  namespace: $CS_NAMESPACE
  labels:
    clusterctl.cluster.x-k8s.io/move: "true"
type: addons.cluster.x-k8s.io/resource-set
---
apiVersion: addons.cluster.x-k8s.io/v1beta2
kind: ClusterResourceSet
metadata:
  name: crs-openstack-newsecret$3
  namespace: $CS_NAMESPACE
  labels:
    clusterctl.cluster.x-k8s.io/move: "true"
spec:
  strategy: "Reconcile"
  clusterSelector:
    matchLabels:
      managed-secret: clouds-yaml$3
  resources:
    - name: openstack-workload-cluster-newsecret$3
      kind: Secret
---
apiVersion: v1
data:
  cloud-config-secret: $CL_CONF_WL_B64
kind: Secret
metadata:
  name: openstack-workload-cluster-secret$3
  namespace: $CS_NAMESPACE
  labels:
    clusterctl.cluster.x-k8s.io/move: "true"
type: addons.cluster.x-k8s.io/resource-set
---
apiVersion: addons.cluster.x-k8s.io/v1beta2
kind: ClusterResourceSet
metadata:
  name: crs-openstack-secret$3
  namespace: $CS_NAMESPACE
  labels:
    clusterctl.cluster.x-k8s.io/move: "true"
spec:
  strategy: "Reconcile"
  clusterSelector:
    matchLabels:
      managed-secret: cloud-config$3
  resources:
    - name: openstack-workload-cluster-secret$3
      kind: Secret
EOT
}

# Case 1
if test -z "$CL_APPCRED_LIFETIME" -o "$CL_APPCRED_LIFETIME" = 0; then
	if test -n "$clouds__openstack__auth__application_credential_id"; then
		AUTHSECTION="application-credential-id=$clouds__openstack__application_credential_id
application-credential-secret=$clouds__openstack__aplication_credential_secret"
	else
		AUTHSECTION="username=$clouds__openstack__auth__username
password=$clouds__openstack__auth__password
user-domain-name=$clouds__openstack__auth__user_domain_name
domain-name=${clouds__openstack__auth__domain_name:-$clouds__openstack__auth__project_domain_name}
tenant-id=$clouds__openstack__auth__project_id
project-id=$clouds__openstack__auth__project_id"
	fi
	umask 0177
	cat >~/tmp/cloud-$OS_CLOUD.conf <<EOT
[Global]
auth-url=$clouds__openstack__auth__auth_url
region=$clouds__openstack__region_name$CAFILE
$AUTHSECTION

[LoadBalancer]
manage-security-groups=true
enable-ingress-hostname=true
create-monitor=true
$LB_OVN
EOT
	umask $OLD_UMASK
	create_clouds_yaml_conf_crs $CL_YAML ~/tmp/cloud-$OS_CLOUD.conf ""
else
	# Lifetime
	unset TZ
	declare -i LIFETIME=$((${CL_APPCRED_LIFETIME%.*}*24*3600))
	# Deal with fractions (but only up to 1/1000: 86.4s granularity)
	if test "${CL_APPCRED_LIFETIME%.*}" != "$CL_APPCRED_LIFETIME"; then
	       FRAC=${CL_APPCRED_LIFETIME#*.}000
	       LIFETIME+=$(((10#${FRAC:0:3}*24*36)/10+1))
	fi
	NOW=$(date +%s)
	EXPIRY=$((NOW+LIFETIME))
	EXPDATE=$(date -d @$EXPIRY +%FT%T)
	if ! type -p openstack >/dev/null 2>&1; then
		echo "ERROR: Need openstack client tools to manage App Creds"
		exit 10
	fi
	APPCREDS=$(openstack application credential list -f value -c ID -c Name -c "Project ID")
	# We find them by name and alternate them to avoid downtimes
	APPCRED_NAME1="CS-$CS_NAMESPACE-$CL_NAME-AppCred1"
	APPCRED_NAME2="CS-$CS_NAMESPACE-$CL_NAME-AppCred2"
	APPCRED_NAME="$APPCRED_NAME1"
	while read id nm prjid; do
		#echo "\"$nm\" \"$prjid\" \"$id\""
		if test "$nm" = "CS-$CS_NAMESPACE-$CL_NAME-AppCred1" -o "$nm" = "CS-$CS_NAMESPACE-$CL_NAME-AppCred2"; then
			echo "# Found AppCred $nm $id"
			# Chose the other name
			APPCRED_NAME=${nm:0:-1}$(((${nm:$((${#nm}-1)):1}%2)+1))
			APPCRED_ID=$id
			APPCRED_PRJ=$prjid
			break
		fi
	done < <(echo "$APPCREDS")
	if test -n "$APPCRED_ID"; then
		AC_EXPDATE=$(openstack application credential show $APPCRED_ID -c expires_at -f value)
		AC_EXPIRY=$(date -d $AC_EXPDATE +%s)
		if test -z "$FORCE" -a $(($AC_EXPIRY-$NOW)) -gt $(($LIFETIME/3)); then
			echo "# AppCred still has >1/3 validity, not renewing"
			SKIP_NEWAC=1
		else
			APPCRED_DELETE=$APPCRED_ID
		fi
	fi
	# Create *restricted* application credential
	if test -z "$SKIP_NEWAC"; then
		echo "# Creating new AppCred $APPCRED_NAME with validity until $EXPDATE"
		NEWCRED=$(openstack application credential create "$APPCRED_NAME" --expiration "$EXPDATE" --description "App Cred for K8s cluster -n $CS_NAMESPACE $CL_NAME" -f value -c id -c project_id -c secret)
		read APPCRED_ID APPCRED_PRJ APPCRED_SECRET < <(echo $NEWCRED)
		# Now create clouds.yaml using the AppCred
		if test -n "$OS_CACERT"; then
			CACERTYAML="
    cacert: /etc/openstack/cacert"
		else
			unset CACERTYAML
		fi
		umask 0177
		cat << EOT > ~/tmp/clouds-$CS_NAMESPACE-$CL_NAME.yaml
clouds:
  openstack:
    region_name: $clouds__openstack__region_name
    auth_type: v3applicationcredential
    interface: $clouds__openstack__interface
    identity_api_version: $clouds__openstack__identity_api_version$CACERTYAML
    auth:
      auth_url: $clouds__openstack__auth__auth_url
      application_credential_id: $APPCRED_ID
      application_credential_secret: $APPCRED_SECRET
EOT
		# ... and cloud.conf using the AppCred
		cat << EOT > ~/tmp/cloud-$CS_NAMESPACE-$CL_NAME.conf
[Global]
auth-url=$clouds__openstack__auth__auth_url
region=$clouds__openstack__region_name$CAFILE
application-credential-id=$APPCRED_ID
application-credential-secret=$APPCRED_SECRET
#project-id=${clouds__openstack__auth__project_id:-$APPCRED_PRJ}

[LoadBalancer]
manage-security-groups=true
enable-ingress-hostname=true
create-monitor=true
$LB_OVN
EOT
		umask $OLD_UMASK
	fi
	create_clouds_yaml_conf_crs ~/tmp/clouds-$CS_NAMESPACE-$CL_NAME.yaml ~/tmp/cloud-$CS_NAMESPACE-$CL_NAME.conf -$CL_NAME
	if test -n "$APPCRED_DELETE"; then
		# Allow 2s for the AppCred to propagate into the cluster
		sleep 2
		openstack application credential delete $APPCRED_DELETE
	fi
fi
