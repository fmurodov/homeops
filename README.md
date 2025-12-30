# HomeOps

Infrastructure as Code repository for home infrastructure management.

![Cluster Photo](docs/images/cluster-photo.jpeg)

## Repository Structure

```
homeops/
├── talos/              # Talos Kubernetes cluster configurations
│   └── talos1018/      # talos1018 cluster configuration
├── kubernetes/         # Flux CD GitOps manifests for cluster management
│   ├── apps/           # Application deployments
│   │   └── talos1018/  # Applications for talos1018 cluster
│   │       ├── adsb/                  # ADS-B flight tracking
│   │       ├── bricktracker/          # Brick collection tracker
│   │       ├── changedetection/       # Website change detection
│   │       ├── esphome/               # ESP device management
│   │       ├── home-assistant/        # Home automation hub
│   │       ├── homebox/               # Home inventory
│   │       ├── homepage/              # Dashboard
│   │       ├── kube-prometheus-stack/ # Monitoring & alerting
│   │       ├── mealie/                # Recipe manager
│   │       ├── minecraft-bedrock/     # Game server
│   │       ├── mosquitto/             # MQTT broker
│   │       ├── paperless/             # Document management
│   │       └── ...                    # More applications
│   ├── infrastructure/ # Infrastructure components
│   │   └── talos1018/
│   │       ├── core/       # Core cluster components (depend first)
│   │       │   ├── cilium/        # CNI networking + L2 config
│   │       │   ├── cert-manager/  # TLS cert management + issuers
│   │       │   └── ingress-nginx/ # Ingress controller
│   │       └── storage/    # Storage layer (optional dependency)
│   │           └── longhorn/      # Distributed block storage + backups
│   └── clusters/       # Cluster-specific Flux configurations
│       └── talos1018/
│           ├── flux-system/       # Flux controllers
│           ├── infrastructure.yaml # Infrastructure Kustomizations
│           └── apps.yaml          # Apps Kustomization
├── scripts/        # Automation and validation scripts
│   ├── validate.sh       # Master validation script
│   └── validate-flux.sh  # Flux-specific validation
├── docs/           # Documentation and assets
└── .github/        # CI/CD workflows
    └── workflows/
        ├── validate-flux.yaml  # Kubernetes manifest validation
        └── validate-talos.yaml # Talos config validation
```

## Projects

### Talos1018 Cluster

A 3-node Kubernetes cluster running on Talos Linux. For detailed setup and configuration, see [talos/talos1018/README.md](talos/talos1018/README.md).

- Control plane: 3 nodes
- Network: Cilium CNI with L2 announcements
- IP Range: 10.18.6.90-93

### Infrastructure Architecture

The infrastructure is organized into layers with minimal dependencies for better resilience:

**Core Components** (`infra-core` - no dependencies):
- **Cilium**: CNI networking with L2 announcements for LoadBalancer support
- **cert-manager**: Automated TLS certificate management via Let's Encrypt
- **ingress-nginx**: HTTP/HTTPS ingress controller

**Storage Layer** (`infra-storage` - depends on core):
- **Longhorn**: Distributed block storage with S3 backups to Cloudflare R2

**Applications** (`apps` - depends on core):
- All applications deploy in parallel
- Apps with PVCs automatically wait for Longhorn (via Kubernetes)
- Apps without PVCs start immediately once core is ready

This architecture ensures:
- ✅ Core networking/ingress always deploys first
- ✅ Storage failures don't block stateless applications
- ✅ Each component includes both controller and configuration together
- ✅ Internal ordering within components (controller → config)

### Kubernetes GitOps

GitOps-based cluster management using Flux CD. For detailed information, see [kubernetes/README.md](kubernetes/README.md).

- Flux CD for continuous deployment
- SOPS with age for secret management
- Automated validation via GitHub Actions
- Parallel reconciliation with smart dependency handling

## Prerequisites

- `talosctl`
- `kubectl`
- `helm`
- `flux` CLI
- `sops` (for secret management)

## Getting Started

1. Clone the repository:
```bash
git clone https://github.com/fmurodov/homeops.git
cd homeops
```

2. Navigate to the desired project directory and follow the project-specific README instructions.
