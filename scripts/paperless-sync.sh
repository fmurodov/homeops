#!/usr/bin/env bash
set -euo pipefail

INBOX="$HOME/Documents/inbox"
CONSUMED="$INBOX/consumed"
NAMESPACE="self-hosted"
POD_LABEL="app.kubernetes.io/name=paperless"
CONSUME_DIR="/data/local/consume"

mkdir -p "$CONSUMED"

# Find the paperless pod
POD=$(kubectl get pod -n "$NAMESPACE" -l "$POD_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$POD" ]]; then
  echo "ERROR: paperless pod not found in namespace $NAMESPACE"
  exit 1
fi
echo "Using pod: $POD"

# Sync each file (skip directories and consumed/)
shopt -s nullglob
files=("$INBOX"/*)
count=0
failed=0

for file in "${files[@]}"; do
  [[ -d "$file" ]] && continue
  name=$(basename "$file")
  echo -n "  $name ... "
  if kubectl cp "$file" "$NAMESPACE/$POD:$CONSUME_DIR/$name" -c app; then
    kubectl exec -n "$NAMESPACE" "$POD" -c app -- chown paperless:paperless "$CONSUME_DIR/$name"
    mv "$file" "$CONSUMED/"
    echo "done"
    ((count++))
  else
    echo "FAILED"
    ((failed++))
  fi
done

echo ""
echo "Synced: $count | Failed: $failed"
