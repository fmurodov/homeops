#!/usr/bin/env bash

# Master validation script for homeops repository
# Validates both Talos configurations and Flux/Kubernetes manifests

set -e

# Move to repository root
cd "$(git rev-parse --show-toplevel)" || exit 1

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

    # Check if talosctl is installed
    if ! command -v talosctl &> /dev/null; then
        echo "⚠️  talosctl is not installed - skipping Talos validation"
        echo ""
    else
        echo "📦 talosctl version:"
        talosctl version --client
        echo ""

        # Find all Talos config files
        echo "🔎 Finding Talos configuration files..."
        CONFIG_FILES=$(find talos -name "controlplane-*.yaml" -o -name "worker-*.yaml" 2>/dev/null | sort)

        if [ -z "$CONFIG_FILES" ]; then
            echo "⚠️  No Talos configuration files found in talos/"
        else
            echo "Found files:"
            echo "$CONFIG_FILES" | sed 's/^/  - /'
            echo ""

            # Validate each configuration file
            while IFS= read -r config_file; do
                if [ -z "$config_file" ]; then
                    continue
                fi

                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "Validating: $config_file"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                if talosctl validate --mode metal --strict --config "$config_file"; then
                    echo "✅ $config_file is valid"
                else
                    echo "❌ $config_file validation failed"
                    VALIDATION_FAILED=1
                fi
                echo ""
            done <<< "$CONFIG_FILES"

            if [ $VALIDATION_FAILED -eq 0 ]; then
                echo "✅ All Talos configurations are valid!"
            fi
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
