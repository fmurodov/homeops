# Kubernetes Flux CD Configuration

This directory contains the GitOps manifests for the home Kubernetes cluster managed by Flux CD.

## Prerequisites

- A Kubernetes cluster (Talos Linux)
- Flux CLI installed
- SOPS and age for secret management
- GitHub account and Personal Access Token

## Repository Structure

```
kubernetes/
├── clusters/           # Cluster-specific manifests
│   └── talos1018/     # Configuration for talos1018 cluster
├── infrastructure/     # Core infrastructure components
│   ├── controllers/   # Infrastructure controllers (cert-manager, ingress-nginx, etc.)
│   └── configs/       # Infrastructure configurations
├── apps/              # Application deployments
│   ├── base/         # Base app configurations
│   └── talos1018/    # Cluster-specific app deployments
└── .sops.yaml        # SOPS configuration for secret management
```

Note: Validation scripts are located in the repository root at `scripts/` and are shared with Talos configurations.

## Bootstrap Process

### 1. GitHub Authentication
Create a GitHub Personal Access Token (PAT) with the following permissions:
- **Read access** to metadata
- **Read/Write access** to administration and code

Use [fine-grained personal access tokens](https://github.com/settings/personal-access-tokens) for better security.

### 2. Bootstrap Flux

```bash
export GITHUB_TOKEN="github_pat_xxxxxxxxxxxxxxx"
flux bootstrap github \
  --owner=fmurodov \
  --repository=homeops \
  --branch=master \
  --personal=true \
  --path=kubernetes/clusters/talos1018
```

## Secret Management with SOPS

This directory uses Mozilla SOPS with age encryption for managing secrets.

### Setting up SOPS:
1. Retrieve the age key from your password manager ("SOPS flux talos1018")
2. Apply the secret to your cluster:
   ```bash
   pbpaste | kubectl apply -f -
   ```
3. All encrypted files should have a `.sops.yaml` extension and be encrypted using the age key

### Working with Secrets:
1. Encode your secret data in base64:
   ```bash
   echo -n "your-secret-data" | base64 | pbcopy
   ```
   or
   ```bash
   pbpaste | base64 | pbcopy
   ```

2. Create your secret file with the encoded data
3. Encrypt the secret file:
   ```bash
   sops --age=***REMOVED*** \
        --encrypt \
        --encrypted-regex '^(data|stringData)$' \
        --in-place path/to/your/secret.sops.yaml
   ```

4. Verify the encryption:
   ```bash
   sops -d path/to/your/secret.sops.yaml
   ```

5. Edit encrypted file:
   ```bash
   export SOPS_AGE_KEY=AGE-SECRET-KEY-xxxxxx
   sops path/to/your/secret.sops.yaml
   ```

## Development

### Git Pre-Commit Hook

To automatically validate manifests before committing:

```bash
cp scripts/pre-commit .git/hooks/pre-commit
```

This will run validation checks for both Talos and Flux configurations before each commit. To bypass: `git commit --no-verify`

### Manual Validation

Run the validation script manually from the repository root:

```bash
# Validate everything (Talos + Flux)
./scripts/validate.sh

# Validate only Flux/Kubernetes manifests
./scripts/validate.sh flux

# Validate only Talos configurations
./scripts/validate.sh talos
```

## References

- Based on: https://github.com/fluxcd/flux2-kustomize-helm-example
- [Flux Documentation](https://fluxcd.io/docs/)
- [SOPS Documentation](https://github.com/mozilla/sops)
