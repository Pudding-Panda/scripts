#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] && [ "$#" -ne 2 ]; then
    echo "Usage: $0 <resource_type> [kubeconfig_path]"
    exit 1
fi

RESOURCE_TYPE="$1"
KUBECONFIG=""

if [ "$#" -eq 2 ]; then
    KUBECONFIG="$2"
    if [ ! -f "$KUBECONFIG" ]; then
        echo "Error: Kubeconfig file '$KUBECONFIG' not found"
        exit 1
    fi
    KUBECTL_CMD="kubectl --kubeconfig=$KUBECONFIG"
else
    KUBECTL_CMD="kubectl"
fi

CLUSTER_NAME=$($KUBECTL_CMD config current-context)

$KUBECTL_CMD get namespaces -o name | cut -d'/' -f2 | while read -r namespace; do
    OUTPUT_DIR="${CLUSTER_NAME}/${namespace}/${RESOURCE_TYPE}"
    mkdir -p "$OUTPUT_DIR"

    echo "Dumping ${RESOURCE_TYPE} from namespace '$namespace' in cluster '$CLUSTER_NAME'"
    $KUBECTL_CMD get ${RESOURCE_TYPE} -n "$namespace" -o name 2>/dev/null | while read -r resource; do
        RESOURCE_NAME=$(echo "$resource" | cut -d'/' -f2)
        
        if [[ "$RESOURCE_NAME" == *"token"* ]]; then
            continue
        fi
        
        echo "Processing ${RESOURCE_TYPE}: $RESOURCE_NAME"
        
        $KUBECTL_CMD get ${RESOURCE_TYPE} "$RESOURCE_NAME" -n "$namespace" -o yaml | \
        yq 'del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") | 
            del(.metadata.creationTimestamp) |
            del(.metadata.uid) |
            del(.metadata.resourceVersion) |
            del(.metadata.generation)' > "$OUTPUT_DIR/$RESOURCE_NAME.yaml"
    done

    # Check if directory is empty and remove if it is
    if [ -z "$(ls -A $OUTPUT_DIR)" ]; then
        rmdir "$OUTPUT_DIR"
        rmdir "$CLUSTER_NAME/$namespace"
        echo "No ${RESOURCE_TYPE} found in namespace '$namespace', removing empty directory"
    else
        echo "${RESOURCE_TYPE} have been dumped to: $OUTPUT_DIR"
    fi
done
