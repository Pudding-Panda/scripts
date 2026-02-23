#!/bin/bash

# Kubernetes I/O Timeout Troubleshooting Script
# This script helps diagnose common causes of I/O timeouts in Kubernetes clusters

set -e

echo "=== Kubernetes I/O Timeout Troubleshooting ==="
echo "Timestamp: $(date)"
echo

# Check cluster status
echo "1. Checking cluster status..."
kubectl get nodes -o wide
echo

# Check ingress-nginx status
echo "2. Checking ingress-nginx status..."
kubectl get pods -n ingress-nginx
echo

# Check for any pods in error state
echo "3. Checking for pods with errors..."
kubectl get pods --all-namespaces | grep -E "(Error|CrashLoopBackOff|Pending|Unknown)"
echo

# Check ingress-nginx logs for timeout errors
echo "4. Checking ingress-nginx logs for timeout errors..."
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50 | grep -i timeout || echo "No timeout errors found in recent logs"
echo

# Check network connectivity
echo "5. Testing DNS resolution..."
kubectl run test-dns --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local
echo

# Check resource usage
echo "6. Checking resource usage..."
kubectl top nodes
echo
kubectl top pods -n ingress-nginx
echo

# Check for network policies that might be blocking traffic
echo "7. Checking network policies..."
kubectl get networkpolicies --all-namespaces
echo

# Check for any events related to timeouts
echo "8. Checking recent events for timeout-related issues..."
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | grep -i timeout || echo "No timeout-related events found"
echo

# Check kubelet status on nodes
echo "9. Checking kubelet status on nodes..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "Node: $node"
    kubectl describe node $node | grep -A 5 -B 5 "kubelet" || echo "No kubelet issues found"
    echo
done

# Check for any certificate issues
echo "10. Checking for certificate issues..."
kubectl get secrets --all-namespaces | grep -E "(tls|cert)" | head -10
echo

echo "=== Troubleshooting Complete ==="
echo "If you're still experiencing timeouts, consider:"
echo "1. Checking your cloud provider's network configuration"
echo "2. Verifying DNS server settings"
echo "3. Checking for any firewall rules blocking traffic"
echo "4. Monitoring system resources (CPU, memory, disk I/O)"
echo "5. Reviewing application-specific timeout settings" 