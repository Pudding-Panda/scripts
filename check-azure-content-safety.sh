#!/usr/bin/env bash
# Exit on any error
set -e

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed. Please install it first."
    exit 1
fi

# Check if logged in
if ! az account show >/dev/null 2>&1; then
    echo "Error: Not logged into Azure CLI. Please run 'az login' first."
    exit 1
fi

echo "Checking Azure AI Content Safety status across all subscriptions..."
echo ""

# Get list of all subscriptions
subscriptions=$(az account list --query "[].{name:name, id:id, state:state}" -o json)

# Check if subscriptions were found
if [ -z "$subscriptions" ] || [ "$subscriptions" == "[]" ]; then
    echo "No Azure subscriptions found."
    exit 1
fi

# Create temporary file for results
results_file=$(mktemp)
trap "rm -f $results_file" EXIT

# Process each subscription
echo "$subscriptions" | jq -c '.[]' | while read -r subscription; do
    subscription_name=$(echo "$subscription" | jq -r '.name')
    subscription_id=$(echo "$subscription" | jq -r '.id')
    subscription_state=$(echo "$subscription" | jq -r '.state')
    
    # Skip disabled subscriptions
    if [ "$subscription_state" != "Enabled" ]; then
        echo "$subscription_name|$subscription_id|$subscription_state|N/A|Subscription disabled" >> "$results_file"
        continue
    fi
    
    # Set the subscription context
    az account set --subscription "$subscription_id" >/dev/null 2>&1
    
    # Check for Content Safety resources
    # Azure AI Content Safety is a Cognitive Services resource type
    # Check for Content Safety specific accounts
    content_safety_resources=$(az cognitiveservices account list \
        --query "[?kind=='ContentSafety'].{name:name, resourceGroup:resourceGroup, location:location}" \
        -o json 2>/dev/null || echo "[]")
    
    # Also check for Content Safety via resource list (alternative method)
    content_safety_via_resource=$(az resource list \
        --query "[?type=='Microsoft.CognitiveServices/accounts' && kind=='ContentSafety'].{name:name, resourceGroup:resourceGroup}" \
        -o json 2>/dev/null || echo "[]")
    
    # Check if Cognitive Services provider is registered
    provider_registered=$(az provider show --namespace "Microsoft.CognitiveServices" \
        --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    
    # Count Content Safety resources
    content_safety_count=$(echo "$content_safety_resources" | jq '. | length')
    resource_list_count=$(echo "$content_safety_via_resource" | jq '. | length')
    
    # Use the higher count (in case one method finds more)
    if [ "$content_safety_count" -gt "$resource_list_count" ]; then
        total_count=$content_safety_count
    else
        total_count=$resource_list_count
    fi
    
    if [ "$total_count" -gt 0 ]; then
        status="Active"
        # Get resource names for details
        resource_names=$(echo "$content_safety_resources" | jq -r '.[].name' | tr '\n' ',' | sed 's/,$//')
        if [ -z "$resource_names" ]; then
            resource_names=$(echo "$content_safety_via_resource" | jq -r '.[].name' | tr '\n' ',' | sed 's/,$//')
        fi
        details="$total_count resource(s): $resource_names"
    elif [ "$provider_registered" == "Registered" ]; then
        status="Provider Available"
        details="Cognitive Services provider registered but no Content Safety resources"
    else
        status="Not Active"
        details="No Content Safety resources found"
    fi
    
    echo "$subscription_name|$subscription_id|$subscription_state|$status|$details" >> "$results_file"
done

# Print table header
printf "%-50s | %-40s | %-12s | %-30s | %s\n" \
    "Subscription Name" "Subscription ID" "State" "Content Safety Status" "Details"
printf "%-50s-+-%-40s-+-%-12s-+-%-30s-+-%s\n" \
    "$(printf '%*s' 50 '' | tr ' ' '-')" \
    "$(printf '%*s' 40 '' | tr ' ' '-')" \
    "$(printf '%*s' 12 '' | tr ' ' '-')" \
    "$(printf '%*s' 30 '' | tr ' ' '-')" \
    "$(printf '%*s' 50 '' | tr ' ' '-')"

# Print results from file
if [ -f "$results_file" ]; then
    while IFS='|' read -r name id state status details; do
        printf "%-50s | %-40s | %-12s | %-30s | %s\n" \
            "$name" "$id" "$state" "$status" "$details"
    done < "$results_file"
fi

echo ""
echo "Check complete!"
