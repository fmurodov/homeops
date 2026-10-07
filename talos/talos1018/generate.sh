#!/usr/bin/env bash
# Renders the Talos machine configs into clusterconfig/.
# validate.sh sets SECRETS (a throwaway plaintext bundle) and OUTPUT.
set -euo pipefail
cd "$(dirname "$0")"

# renovate: datasource=github-releases depName=siderolabs/talos
TALOS_VERSION=v1.14.2
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
KUBERNETES_VERSION=v1.37.1
# Image Factory schematic: intel-ucode, iscsi-tools, util-linux-tools
INSTALL_IMAGE="factory.talos.dev/metal-installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:$TALOS_VERSION"

NODE_IPS=(fd00:1018:0:5:10:18:6:91 fd00:1018:0:5:10:18:6:92 fd00:1018:0:5:10:18:6:93)
OUTPUT="${OUTPUT:-clusterconfig}"

if [[ -z "${SECRETS:-}" ]]; then
    SECRETS="$(mktemp)"
    trap 'rm -f "$SECRETS"' EXIT
    sops --decrypt secrets.sops.yaml > "$SECRETS"
fi

# v1.13 contract: the 1.14 one rejects the v1alpha1 fields these patches still use
talosctl gen config talos1018 "https://[fd00:1018:0:5:10:18:6:90]:6443" \
    --with-secrets "$SECRETS" \
    --talos-version v1.13 \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-image "$INSTALL_IMAGE" \
    --config-patch-control-plane @patches/controlplane.yaml \
    --output-types controlplane,talosconfig \
    --with-docs=false \
    --with-examples=false \
    --output "$OUTPUT" \
    --force

for patch in patches/talos-1018-*.yaml; do
    node="$(basename "$patch" .yaml)"
    talosctl machineconfig patch "$OUTPUT/controlplane.yaml" \
        --patch "@$patch" \
        --output "$OUTPUT/talos1018-$node.yaml"
done

talosctl --talosconfig "$OUTPUT/talosconfig" config endpoint "${NODE_IPS[@]}"
talosctl --talosconfig "$OUTPUT/talosconfig" config node "${NODE_IPS[@]}"
