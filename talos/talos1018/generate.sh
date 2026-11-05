#!/usr/bin/env bash
# Renders the Talos machine configs into clusterconfig/.
# validate.sh sets SECRETS (a throwaway plaintext bundle) and OUTPUT.
set -euo pipefail
cd "$(dirname "$0")"

# renovate: datasource=github-releases depName=siderolabs/talos
TALOS_VERSION=v1.14.5
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
KUBERNETES_VERSION=v1.36.3
# Image Factory schematic: intel-ucode, iscsi-tools, util-linux-tools
INSTALL_IMAGE="factory.talos.dev/metal-installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:$TALOS_VERSION"

NODE_IPS=(fd6d:cefe:ddc3:5:10:18:6:91 fd6d:cefe:ddc3:5:10:18:6:92 fd6d:cefe:ddc3:5:10:18:6:93)
OUTPUT="${OUTPUT:-clusterconfig}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${SECRETS:-}" ]]; then
    SECRETS="$WORK/secrets.yaml"
    sops --decrypt secrets.sops.yaml > "$SECRETS"
fi

# The pod /56 is carved from the ISP /48, which stays out of git (public repo):
# patches use ${IPV6_PREFIX_GUA} and it is filled in here from cluster-secrets.
# validate.sh passes a documentation prefix, so no age key is needed there.
if [[ -z "${IPV6_PREFIX_GUA:-}" ]]; then
    IPV6_PREFIX_GUA="$(sops --decrypt --extract '["stringData"]["IPV6_PREFIX_GUA"]' \
        ../../kubernetes/components/common/cluster-secrets.sops.yaml)"
fi
sed "s/\${IPV6_PREFIX_GUA}/$IPV6_PREFIX_GUA/g" patches/controlplane.yaml > "$WORK/controlplane.yaml"

# The endpoint is also the service-account issuer. The old fd00 issuer stays
# accepted in patches/controlplane.yaml (KubeServiceAccountConfig).
talosctl gen config talos1018 "https://[fd6d:cefe:ddc3:5:10:18:6:90]:6443" \
    --with-secrets "$SECRETS" \
    --talos-version v1.14 \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-image "$INSTALL_IMAGE" \
    --config-patch-control-plane "@$WORK/controlplane.yaml" \
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
