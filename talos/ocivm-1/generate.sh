#!/usr/bin/env bash
# Renders the ocivm-1 machine config into clusterconfig/.
# validate.sh sets SECRETS (a throwaway bundle), OUTPUT and the prefixes.
set -euo pipefail
cd "$(dirname "$0")"

# renovate: datasource=github-releases depName=siderolabs/talos
TALOS_VERSION=v1.14.6
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
KUBERNETES_VERSION=v1.36.6
# Image Factory schematic: netbird
INSTALL_IMAGE="factory.talos.dev/oracle-installer/7326f0cbca7a0e700ac1efa3f32e88df9ebe5010e6e842a8ed36fdc99ee98ead:$TALOS_VERSION"

OUTPUT="${OUTPUT:-clusterconfig}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${SECRETS:-}" ]]; then
    SECRETS="$WORK/secrets.yaml"
    sops --decrypt secrets.sops.yaml > "$SECRETS"
fi

# Prefixes and the domain stay out of git (public repo).
secret() {
    sops --decrypt --extract "[\"stringData\"][\"$2\"]" "../../kubernetes/components/$1/cluster-secrets.sops.yaml"
}
OCI_IPV6_PREFIX="${OCI_IPV6_PREFIX:-$(secret ocivm-1 OCI_IPV6_PREFIX)}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(secret ocivm-1 CLUSTER_DOMAIN)}"
HOME_IPV6_PREFIX="${HOME_IPV6_PREFIX:-$(secret common IPV6_PREFIX_GUA)}"
# Only used the first time the node joins NetBird.
NB_SETUP_KEY="${NB_SETUP_KEY:-$(secret ocivm-1 NB_SETUP_KEY)}"
for patch in controlplane firewall; do
    sed -e "s/\${OCI_IPV6_PREFIX}/$OCI_IPV6_PREFIX/g" \
        -e "s/\${CLUSTER_DOMAIN}/$CLUSTER_DOMAIN/g" \
        -e "s/\${HOME_IPV6_PREFIX}/$HOME_IPV6_PREFIX/g" \
        -e "s/\${NB_SETUP_KEY}/$NB_SETUP_KEY/g" \
        "patches/$patch.yaml" > "$WORK/$patch.yaml"
done

NODE="$OCI_IPV6_PREFIX::10"
talosctl gen config ocivm-1 "https://[$NODE]:6443" \
    --with-secrets "$SECRETS" \
    --talos-version v1.14 \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-image "$INSTALL_IMAGE" \
    --config-patch-control-plane "@$WORK/controlplane.yaml" \
    --config-patch-control-plane "@$WORK/firewall.yaml" \
    --output-types controlplane,talosconfig \
    --with-docs=false \
    --with-examples=false \
    --output "$OUTPUT" \
    --force

# Its own context, so a command meant for ocivm-1 can't reach talos1018.
talosctl --talosconfig "$OUTPUT/talosconfig" config endpoint "$NODE"
talosctl --talosconfig "$OUTPUT/talosconfig" config node "$NODE"
