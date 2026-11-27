# ocivm-1

Single-node Talos cluster on the Oracle Cloud VM (homeops-project#90), managed
by Flux from `kubernetes/clusters/ocivm-1`. The VM, network and addresses are
in fmurodov-tf.

```
ocivm-1/
├── generate.sh          # versions + talosctl gen config; writes clusterconfig/
├── secrets.sops.yaml    # talosctl gen secrets bundle (ocivm-1 key + admin key)
└── patches/             # controlplane.yaml, firewall.yaml
```

## Never touch talos1018 by mistake

Keep this cluster's configs in their own files and always pass them:

```bash
talosctl --talosconfig ~/.talos/ocivm-1 ...
kubectl --kubeconfig ~/.kube/ocivm-1 ...
```

Never merge them into `~/.talos/config` or `~/.kube/config`. The CAs differ, so
a wrong pairing fails rather than reaching the other cluster.

## Install

Oracle allows no custom images here (`custom-image-count` is 0), so the VM
boots Oracle's Ubuntu image and its cloud-init (fmurodov-tf) kexecs into the
Talos Image Factory kernel. Talos then waits in maintenance mode.

1. `./generate.sh`, with `NB_SETUP_KEY` set in cluster-secrets first.
2. `talosctl apply-config --insecure -n <node IPv6> --file clusterconfig/controlplane.yaml`.
   It installs to the boot disk and reboots from it.
3. `cp clusterconfig/talosconfig ~/.talos/ocivm-1`, then
   `talosctl --talosconfig ~/.talos/ocivm-1 bootstrap` and
   `talosctl --talosconfig ~/.talos/ocivm-1 kubeconfig ~/.kube/ocivm-1`.
4. Cilium and CoreDNS by hand once (no CNI, no DNS yet), with the `${...}`
   values from cluster-secrets filled in:
   `helm install cilium cilium/cilium -n kube-system --version <helmrelease version> -f <values.yaml>`,
   then `kubectl kustomize kubernetes/apps/ocivm-1/kube-system/coredns/app | kubectl apply --server-side --field-manager=kustomize-controller -f -`.
5. Flux: create the `sops-age` secret in `flux-system` from the ocivm-1 key,
   then `kubectl apply -k kubernetes/clusters/ocivm-1/flux-system`.

Flux then takes over Cilium and CoreDNS.
