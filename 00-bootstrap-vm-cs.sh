#!/bin/bash
#
# Install the software needed to deploy cluster stacks from this VM
#
# (c) Kurt Garloff <s7n@garloff.de>, 2/2025
# SPDX-License-Identifier: CC-BY-SA-4.0

# ToDo: Magic to switch b/w apt, zypper, dnf, pacman, ...
ARCH=$(uname -m)
ARCH="${ARCH/x86_64/amd64}"
OS=$(uname -s | tr A-Z a-z)

# Releases of the components to install
CAPI_RELEASE=1.9.4          # clusterctl
HELM_RELEASE=3.17.1         # helm
KIND_RELEASE=0.26.0         # kind
KUBERNETES_RELEASE=1.31.6   # kubectl

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
	curl -LO "$1" || return
	FNM="${1##*/}"
	if ! test_sha256 "$FNM" "$2"; then echo "Checksum mismatch for ${FNM}" 1>&2; return 1; fi
	chmod +x "$FNM"
	sudo mv "$FNM" /usr/local/bin/"$3"
}

# Usage install_via_download_bin URL sha256 extrpath [newname]
install_via_download_tgz()
{
	cd ~/Download
	curl -LO "$1" || return
	FNM="${1##*/}"
	if ! test_sha256 "$FNM" "$2"; then echo "Checksum mismatch for ${FNM}" 1>&2; return 1; fi
	tar xvzf "$FNM"
	sudo mv "$3" /usr/local/bin/"$4"
}

# Debian 12 (Bookworm)
mkdir -p ~/Download
INSTCMD="apt-get install -qq -y --no-install-recommends --no-install-suggests"
DEB12_PKGS=(docker.io golang jq yq git gh python3-openstackclient)
DEB12_TGZS=("https://get.helm.sh/helm-v${HELM_RELEASE}-${OS}-${ARCH}.tar.gz")
DEB12_TCHK=("3b66f3cd28409f29832b1b35b43d9922959a32d795003149707fea84cbcd4469")
DEB12_TOLD=("${OS}-${ARCH}/helm")
DEB12_TNEW=(".")
DEB12_BINS=("https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_RELEASE}/kind-${OS}-${ARCH}"
	    "https://dl.k8s.io/release/v${KUBERNETES_RELEASE}/bin/${OS}/${ARCH}/kubectl"
	    "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CAPI_RELEASE}/clusterctl-${OS}-${ARCH}"
	)
DEB12_BCHK=("d445b44c28297bc23fd67e51cc24bb294ae7b977712be2d4d312883d0835829b"
	    "c46b2f5b0027e919299d1eca073ebf13a4c5c0528dd854fc71a5b93396c9fa9d"
	    "0c80a58f6158cd76075fcc9a5d860978720fa88860c2608bb00944f6af1e5752"
    )
DEB12_BNEW=("kind" "." "clusterctl")

sudo apt-get update
install_via_pkgmgr "${DEB12_PKGS[@]}" || exit 1
for i in $(seq 0 $((${#DEB12_TGZS[*]}-1))); do
	install_via_download_tgz "${DEB12_TGZS[$i]}" "${DEB12_TCHK[$i]}" "${DEB12_TOLD[$i]}" "${DEB12_TNEW[$i]}" || exit 2
done
for i in $(seq 0 $((${#DEB12_BINS[*]}-1))); do
	install_via_download_bin "${DEB12_BINS[$i]}" "${DEB12_BCHK[$i]}" "${DEB12_BNEW[$i]}" || exit 3
done

GOBIN=/tmp go install github.com/drone/envsubst/v2/cmd/envsubst@latest
sudo mv /tmp/envsubst /usr/local/bin/

test -e "~/.bash_aliases" || echo -e "alias ll='ls -lF'\nalias k=kubectl" > ~/.bash_aliases
sudo groupmod -a -U `whoami` docker
sudo systemctl enable --now docker

