#!/usr/bin/env bash

# Master validation script for homeops repository
# Validates both Talos configurations and Flux/Kubernetes manifests

set -e

# Derived from this script's location, not `git rev-parse`: git sets GIT_DIR
# for hooks without GIT_WORK_TREE, which makes --show-toplevel return the
# current directory instead of the repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VALIDATION_FAILED=0

# Determine what to validate based on arguments or changed files
VALIDATE_TALOS=false
VALIDATE_FLUX=false

if [ "$1" == "talos" ]; then
    VALIDATE_TALOS=true
elif [ "$1" == "flux" ] || [ "$1" == "kubernetes" ]; then
    VALIDATE_FLUX=true
else
    # If no argument provided, validate both
    VALIDATE_TALOS=true
    VALIDATE_FLUX=true
fi

# ============================================================================
# TALOS VALIDATION
# ============================================================================
if [ "$VALIDATE_TALOS" = true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔍 Validating Talos Configurations"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v talosctl &> /dev/null; then
        echo "⚠️  talosctl is not installed - skipping Talos node config validation"
        echo ""
    else
        echo "📦 talosctl version:"
        talosctl version --client
        echo ""

        # Render with a throwaway secrets bundle, so no age key is needed
        TALOS_WORK="$(mktemp -d)"
        trap 'rm -rf "$TALOS_WORK"' EXIT
        talosctl gen secrets -o "$TALOS_WORK/secrets.yaml"

        if SECRETS="$TALOS_WORK/secrets.yaml" OUTPUT="$TALOS_WORK" talos/talos1018/generate.sh; then
            for config_file in "$TALOS_WORK"/talos1018-*.yaml; do
                # Not --strict: it fails on the v1alpha1 deprecation warnings
                if talosctl validate --mode metal --config "$config_file" > /dev/null; then
                    echo "✅ $(basename "$config_file") is valid"
                else
                    echo "❌ $(basename "$config_file") validation failed"
                    VALIDATION_FAILED=1
                fi
            done
        else
            echo "❌ talos/talos1018/generate.sh failed"
            VALIDATION_FAILED=1
        fi
    fi
    echo ""
fi

# ============================================================================
# FLUX/KUBERNETES VALIDATION
# ============================================================================
if [ "$VALIDATE_FLUX" = true ]; then
    if [ -f "./scripts/validate-flux.sh" ]; then
        if ! ./scripts/validate-flux.sh; then
            VALIDATION_FAILED=1
        fi
    else
        echo "⚠️  Flux validation script not found - skipping"
    fi
fi

# ============================================================================
# FINAL RESULT
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $VALIDATION_FAILED -eq 1 ]; then
    echo "❌ Validation failed for one or more configurations"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi

echo "✅ All validations passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
