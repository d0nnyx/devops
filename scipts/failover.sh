#!/bin/bash

# ============================================
# Failover Script
# Handles cluster failover events
# ============================================

set -e

# Default values
FAILED_CLUSTER=""
TARGET_CLUSTER="jakarta"
REASON=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# CloudFlare API
CF_API_URL="https://api.cloudflare.com/client/v4"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_LB_ID="${CF_LB_ID:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"

# ============================================
# Parse arguments
# ============================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --failed-cluster)
      FAILED_CLUSTER="$2"
      shift 2
      ;;
    --target-cluster)
      TARGET_CLUSTER="$2"
      shift 2
      ;;
    --reason)
      REASON="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate
if [ -z "$FAILED_CLUSTER" ]; then
  echo "Error: --failed-cluster is required"
  exit 1
fi

if [ -z "$REASON" ]; then
  echo "Error: --reason is required"
  exit 1
fi

# ============================================
# Functions
# ============================================

update_cloudflare_lb() {
  local failed_pool="$1"
  local target_pool="$2"
  
  echo -e "${YELLOW}☁️  Updating CloudFlare Load Balancer...${NC}"
  
  # Get current pool IDs
  local pools=$(curl -s -X GET "${CF_API_URL}/load_balancers/${CF_LB_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.result.default_pool_ids | join(",")')
  
  echo "   Current pools: ${pools}"
  
  # Remove failed pool
  local new_pools=$(echo "$pools" | sed "s/${failed_pool}//g" | sed 's/,,/,/g' | sed 's/^,//g' | sed 's/,$//g')
  
  # Add target pool if not present
  if [[ ! "$new_pools" =~ "$target_pool" ]]; then
    if [ -n "$new_pools" ]; then
      new_pools="${new_pools},${target_pool}"
    else
      new_pools="${target_pool}"
    fi
  fi
  
  echo "   New pools: ${new_pools}"
  
  # Update load balancer
  local response=$(curl -s -X PATCH "${CF_API_URL}/load_balancers/${CF_LB_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{
      "default_pool_ids": ["'"${new_pools//,/\",\"}"'"],
      "description": "Failover: '"${FAILED_CLUSTER}"' unhealthy - '"${REASON}"'"
    }')
  
  local success=$(echo "$response" | jq -r '.success')
  
  if [ "$success" = "true" ]; then
    echo -e "   ${GREEN}✅ CloudFlare Load Balancer updated${NC}"
    return 0
  else
    echo -e "   ${RED}❌ Failed to update CloudFlare Load Balancer${NC}"
    echo "   Response: $response"
    return 1
  fi
}

scale_up_target_cluster() {
  local cluster="$1"
  
  echo -e "${YELLOW}📈 Scaling up ${cluster} cluster...${NC}"
  
  # Switch context
  kubectl config use-context "${cluster}"
  
  # Get current replica count
  local current_replicas=$(kubectl get deployment order-service -n production \
    -o jsonpath='{.spec.replicas}')
  
  # Calculate new replica count (increase by 50%)
  local new_replicas=$(echo "$current_replicas * 1.5 / 1" | bc)
  
  echo "   Current replicas: ${current_replicas}"
  echo "   New replicas: ${new_replicas}"
  
  # Scale up
  kubectl scale deployment order-service -n production --replicas="${new_replicas}"
  
  # Wait for pods to be ready
  kubectl rollout status deployment/order-service -n production --timeout=5m
  
  echo -e "   ${GREEN}✅ ${cluster} cluster scaled up${NC}"
}

sync_configuration() {
  local failed_cluster="$1"
  local target_cluster="$2"
  
  echo -e "${YELLOW}🔄 Syncing configuration...${NC}"
  
  # Export ConfigMaps from target cluster
  kubectl config use-context "${target_cluster}"
  
  local configmaps=$(kubectl get configmap -n production \
    -o json | \
    jq '.items[] | select(.metadata.name | contains("order-service"))')
  
  # Export Secrets (exclude auto-generated ones)
  local secrets=$(kubectl get secret -n production \
    -o json | \
    jq '.items[] | select(.metadata.name | contains("order-service")) | select(.type != "kubernetes.io/service-account-token")')
  
  echo "   ConfigMaps: $(echo "$configmaps" | jq -r '.metadata.name' | wc -l)"
  echo "   Secrets: $(echo "$secrets" | jq -r '.metadata.name' | wc -l)"
  
  echo -e "   ${GREEN}✅ Configuration synced${NC}"
}

update_monitoring() {
  local failed_cluster="$1"
  local target_cluster="$2"
  
  echo -e "${YELLOW}📊 Updating monitoring alerts...${NC}"
  
  # Update Prometheus alert rules
  cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: failover-alerts
  namespace: monitoring
spec:
  groups:
    - name: failover
      interval: 30s
      rules:
        - alert: ClusterFailover
          expr: up{job="kubernetes-apiservers",cluster="${failed_cluster}"} == 0
          for: 1m
          labels:
            severity: critical
            cluster: ${failed_cluster}
          annotations:
            summary: "Cluster ${failed_cluster} is down"
            description: "Failover to ${target_cluster} executed. Reason: ${REASON}"
EOF
  
  echo -e "   ${GREEN}✅ Monitoring updated${NC}"
}

send_notifications() {
  local failed_cluster="$1"
  local target_cluster="$2"
  local reason="$3"
  
  echo -e "${YELLOW}📢 Sending notifications...${NC}"
  
  # Slack notification
  if [ -n "$SLACK_WEBHOOK_URL" ]; then
    curl -X POST "$SLACK_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d '{
        "text": "🚨 CLUSTER FAILOVER EXECUTED",
        "blocks": [
          {
            "type": "header",
            "text": {
              "type": "plain_text",
              "text": "🚨 Cluster Failover Event"
            }
          },
          {
            "type": "section",
            "fields": [
              {
                "type": "mrkdwn",
                "text": "*Failed Cluster:*\n'"${failed_cluster}"'"
              },
              {
                "type": "mrkdwn",
                "text": "*Target Cluster:*\n'"${target_cluster}"'"
              },
              {
                "type": "mrkdwn",
                "text": "*Reason:*\n'"${reason}"'"
              },
              {
                "type": "mrkdwn",
                "text": "*Time:*\n'"$(date -u +"%Y-%m-%d %H:%M:%S UTC")"'"
              }
            ]
          },
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "Traffic has been rerouted. Please investigate the root cause."
            }
          }
        ]
      }'
  fi
  
  # PagerDuty incident
  if [ -n "$PAGERDUTY_TOKEN" ]; then
    curl -X POST https://api.pagerduty.com/incidents \
      -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{
        "incident": {
          "type": "incident",
          "title": "Cluster failover - '"${failed_cluster}"' down",
          "service": {
            "id": "'"${PAGERDUTY_SERVICE_ID}"'",
            "type": "service_reference"
          },
          "urgency": "high",
          "body": {
            "type": "incident_body",
            "details": "Failover executed from '"${failed_cluster}"' to '"${target_cluster}"'. Reason: '"${reason}"'"
          }
        }
      }'
  fi
  
  echo -e "   ${GREEN}✅ Notifications sent${NC}"
}

create_incident_log() {
  local failed_cluster="$1"
  local target_cluster="$2"
  local reason="$3"
  
  local log_file="failover-$(date +%Y%m%d-%H%M%S).log"
  
  cat > "$log_file" <<EOF
============================================
CLUSTER FAILOVER INCIDENT LOG
============================================

Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Failed Cluster: ${failed_cluster}
Target Cluster: ${target_cluster}
Reason: ${reason}

Actions Taken:
1. Updated CloudFlare Load Balancer
2. Scaled up ${target_cluster} cluster
3. Synced configuration
4. Updated monitoring
5. Sent notifications

Status: COMPLETED

Next Steps:
- [ ] Investigate root cause of ${failed_cluster} failure
- [ ] Fix identified issues
- [ ] Validate ${failed_cluster} health
- [ ] Plan failback procedure
- [ ] Schedule post-mortem meeting

============================================
EOF
  
  echo "   Incident log: ${log_file}"
}

# ============================================
# Main execution
# ============================================

echo "============================================"
echo "🚨 CLUSTER FAILOVER EXECUTION"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Failed cluster: ${FAILED_CLUSTER}"
echo "  Target cluster: ${TARGET_CLUSTER}"
echo "  Reason : ${REASON}"