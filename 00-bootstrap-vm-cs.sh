#!/bin/bash
#
# Install the software needed to deploy cluster stacks from this VM
#
# (c) Kurt Garloff <s7n@garloff.de>, 2/2025
# SPDX-License-Identifier: CC-BY-SA-4.0

# TODO: Magic to switch b/w apt, zypper, dnf, pacman, ...
#
#   *** This script currently supports only Debian GNU/Linux
#

ARCH=$(uname -m)
ARCH="${ARCH/x86_64/amd64}"
OS=$(uname -s | tr A-Z a-z)
WHOAMI=$(whoami)

# Releases of the components to install
CAPI_RELEASE=1.11.3         # clusterctl
HELM_RELEASE=4.0.0          # helm
KIND_RELEASE=0.30.0         # kind
KUBERNETES_RELEASE=1.33.4   # kubectl

# Usage: install_via_pkgmgr pkgnm [pkgnm [...]]
install_via_pkgmgr()
{
	sudo $INSTCMD "$@"
}

# Verify sha256sum
test_sha256()
{
	OUT=$(sha256sum "$1")
	OUT=${OUT%% *}
	if test "$OUT" != "$2"; then return 1; else return 0; fi
}

# Usage install_via_download_bin URL sha256 [newname]
install_via_download_bin()
{
	cd ~/Download
	curl -s -LO "$1" || return
	FNM="${1##*/}"
	if ! test_sha256 "$FNM" "$2"; then echo "Checksum mismatch for ${FNM}" 1>&2; return 1; fi
	chmod +x "$FNM"
	sudo mv "$FNM" /usr/local/bin/"$3"
}

# Usage install_via_download_bin URL sha256 extrpath [newname]
install_via_download_tgz()
{
	cd ~/Download
	curl -s -LO "$1" || return
	FNM="${1##*/}"
	if ! test_sha256 "$FNM" "$2"; then echo "Checksum mismatch for ${FNM}" 1>&2; return 1; fi
	tar xvzf "$FNM"
	sudo mv "$3" /usr/local/bin/"$4"
}

# Create necessary directories hierarchy and touch the clouds credential file
mkdir -p \
    ~/.config/openstack \
    ~/Download
touch ~/.config/openstack/clouds.yaml

# List of binaries (with their respective checksums) and packages for Debian
INSTCMD="apt-get install -qq -y --no-install-recommends --no-install-suggests"
DEBIAN_PKGS=(ca-certificates curl golang jq yq git gh python3-openstackclient)
DEBIAN_TGZS=("https://get.helm.sh/helm-v${HELM_RELEASE}-${OS}-${ARCH}.tar.gz")
DEBIAN_TCHK=("c77e9e7c1cc96e066bd240d190d1beed9a6b08060b2043ef0862c4f865eca08f")
DEBIAN_TOLD=("${OS}-${ARCH}/helm")
DEBIAN_TNEW=(".")
DEBIAN_BINS=("https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_RELEASE}/kind-${OS}-${ARCH}"
	"https://dl.k8s.io/release/v${KUBERNETES_RELEASE}/bin/${OS}/${ARCH}/kubectl"
	"https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CAPI_RELEASE}/clusterctl-${OS}-${ARCH}"
	)
DEBIAN_BCHK=("517ab7fc89ddeed5fa65abf71530d90648d9638ef0c4cde22c2c11f8097b8889"
    "c2ba72c115d524b72aaee9aab8df8b876e1596889d2f3f27d68405262ce86ca1"
    "d65ec7a42c36e863847103d48216c3dad248b82c447a27b3b2325a61e26ead9a"
    )
DEBIAN_BNEW=("kind" "." "clusterctl")

sudo apt-get update
install_via_pkgmgr "${DEBIAN_PKGS[@]}" || exit 1
for i in $(seq 0 $((${#DEBIAN_TGZS[*]}-1))); do
	install_via_download_tgz "${DEBIAN_TGZS[$i]}" "${DEBIAN_TCHK[$i]}" "${DEBIAN_TOLD[$i]}" "${DEBIAN_TNEW[$i]}" || exit 2
done
for i in $(seq 0 $((${#DEBIAN_BINS[*]}-1))); do
	install_via_download_bin "${DEBIAN_BINS[$i]}" "${DEBIAN_BCHK[$i]}" "${DEBIAN_BNEW[$i]}" || exit 3
done

GOBIN=/tmp go install github.com/drone/envsubst/v2/cmd/envsubst@latest
sudo mv /tmp/envsubst /usr/local/bin/

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to apt sources
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Update apt cache and install docker packages
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Check if we have ~/.bash_aliases to set
test -e "~/.bash_aliases" || echo -e "alias ll='ls -lF'\nalias k=kubectl" > ~/.bash_aliases

# Add current user to the Docker group
sudo groupmod -a -U ${WHOAMI} docker
sudo systemctl enable --now docker.service
