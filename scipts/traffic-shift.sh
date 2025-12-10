#!/bin/bash

# ============================================
# Traffic Shift Script
# Gradually shifts traffic between blue/green deployments
# ============================================

set -e

# Default values
NAMESPACE="production"
SERVICE="order-service"
NEW_VERSION=""
OLD_VERSION=""
WEIGHT=100

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# Parse arguments
# ============================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --service)
      SERVICE="$2"
      shift 2
      ;;
    --new-version)
      NEW_VERSION="$2"
      shift 2
      ;;
    --old-version)
      OLD_VERSION="$2"
      shift 2
      ;;
    --weight)
      WEIGHT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate inputs
if [ -z "$NEW_VERSION" ]; then
  echo "Error: --new-version is required"
  exit 1
fi

# ============================================
# Functions
# ============================================

update_service_selector() {
  local service="$1"
  local version="$2"
  local namespace="$3"
  
  echo -e "${BLUE}🔄 Updating service selector to version: ${version}${NC}"
  
  kubectl patch service "${service}" -n "${namespace}" \
    -p "{\"spec\":{\"selector\":{\"version\":\"${version}\"}}}"
  
  echo -e "${GREEN}✅ Service selector updated${NC}"
}

create_virtualservice() {
  local service="$1"
  local new_version="$2"
  local old_version="$3"
  local weight="$4"
  local namespace="$5"
  
  local old_weight=$((100 - weight))
  
  echo -e "${YELLOW}📝 Creating/Updating Istio VirtualService...${NC}"
  
  cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${service}
  namespace: ${namespace}
spec:
  hosts:
    - ${service}
  http:
    - match:
        - headers:
            x-version:
              exact: ${new_version}
      route:
        - destination:
            host: ${service}
            subset: ${new_version}
          weight: 100
    
    - route:
        - destination:
            host: ${service}
            subset: ${new_version}
          weight: ${weight}
        - destination:
            host: ${service}
            subset: ${old_version}
          weight: ${old_weight}
EOF
  
  echo -e "${GREEN}✅ VirtualService configured: ${new_version}=${weight}%, ${old_version}=${old_weight}%${NC}"
}

create_destinationrule() {
  local service="$1"
  local namespace="$2"
  
  echo -e "${YELLOW}📝 Creating/Updating DestinationRule...${NC}"
  
  cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ${service}
  namespace: ${namespace}
spec:
  host: ${service}
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        http2MaxRequests: 100
        maxRequestsPerConnection: 2
    loadBalancer:
      simple: LEAST_REQUEST
    outlierDetection:
      consecutiveErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
      minHealthPercent: 40
  subsets:
    - name: blue
      labels:
        version: blue
    - name: green
      labels:
        version: green
EOF
  
  echo -e "${GREEN}✅ DestinationRule configured${NC}"
}

update_nginx_ingress() {
  local service="$1"
  local new_version="$2"
  local weight="$3"
  local namespace="$4"
  
  echo -e "${YELLOW}📝 Updating NGINX Ingress annotations...${NC}"
  
  # Create canary ingress
  if [ "$weight" -lt 100 ]; then
    kubectl annotate ingress "${service}" -n "${namespace}" \
      nginx.ingress.kubernetes.io/canary="true" \
      nginx.ingress.kubernetes.io/canary-weight="${weight}" \
      --overwrite
    
    echo -e "${GREEN}✅ NGINX Ingress canary weight set to ${weight}%${NC}"
  else
    # 100% traffic - remove canary annotations
    kubectl annotate ingress "${service}" -n "${namespace}" \
      nginx.ingress.kubernetes.io/canary- \
      nginx.ingress.kubernetes.io/canary-weight-
    
    echo -e "${GREEN}✅ NGINX Ingress canary disabled (100% traffic)${NC}"
  fi
}

verify_traffic_distribution() {
  local service="$1"
  local namespace="$2"
  local expected_weight="$3"
  
  echo -e "${YELLOW}🔍 Verifying traffic distribution...${NC}"
  
  sleep 10  # Wait for config to propagate
  
  # Query Prometheus for actual traffic distribution
  local query="sum(rate(http_requests_total{service=\"${service}\",version=\"${NEW_VERSION}\"}[1m])) / sum(rate(http_requests_total{service=\"${service}\"}[1m])) * 100"
  
  local actual_weight=$(curl -s -G \
    --data-urlencode "query=${query}" \
    "http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query" | \
    jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
  
  echo "   Expected: ${expected_weight}%"
  echo "   Actual: ${actual_weight}%"
  
  # Allow 10% margin of error
  local diff=$(echo "$actual_weight - $expected_weight" | bc | sed 's/-//')
  
  if (( $(echo "$diff < 10" | bc -l) )); then
    echo -e "   ${GREEN}✅ Traffic distribution verified${NC}"
    return 0
  else
    echo -e "   ${YELLOW}⚠️  Traffic distribution deviation detected${NC}"
    return 1
  fi
}

# ============================================
# Main execution
# ============================================

echo "============================================"
echo "🔄 Traffic Shift Execution"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Service: ${SERVICE}"
echo "  Namespace: ${NAMESPACE}"
echo "  New version: ${NEW_VERSION}"
echo "  Old version: ${OLD_VERSION:-auto-detect}"
echo "  Target weight: ${WEIGHT}%"
echo ""

# Auto-detect old version if not specified
if [ -z "$OLD_VERSION" ]; then
  OLD_VERSION=$(kubectl get service "${SERVICE}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.selector.version}' 2>/dev/null || echo "blue")
  echo "Auto-detected old version: ${OLD_VERSION}"
fi

# Check if using Istio or NGINX
if kubectl get virtualservice "${SERVICE}" -n "${NAMESPACE}" &>/dev/null || \
   kubectl get gateway -n istio-system &>/dev/null; then
  echo "🔍 Detected Istio service mesh"
  USE_ISTIO=true
else
  echo "🔍 Detected NGINX Ingress"
  USE_ISTIO=false
fi

# Execute traffic shift
if [ "$USE_ISTIO" = true ]; then
  # Istio-based traffic shift
  create_destinationrule "${SERVICE}" "${NAMESPACE}"
  create_virtualservice "${SERVICE}" "${NEW_VERSION}" "${OLD_VERSION}" "${WEIGHT}" "${NAMESPACE}"
  
  if [ "$WEIGHT" -eq 100 ]; then
    echo ""
    echo -e "${GREEN}🎉 100% traffic shifted to ${NEW_VERSION}${NC}"
    echo -e "${BLUE}🔄 Updating main service selector...${NC}"
    update_service_selector "${SERVICE}" "${NEW_VERSION}" "${NAMESPACE}"
  fi
else
  # NGINX Ingress-based traffic shift
  update_nginx_ingress "${SERVICE}" "${NEW_VERSION}" "${WEIGHT}" "${NAMESPACE}"
  
  if [ "$WEIGHT" -eq 100 ]; then
    echo ""
    echo -e "${GREEN}🎉 100% traffic shifted to ${NEW_VERSION}${NC}"
    update_service_selector "${SERVICE}" "${NEW_VERSION}" "${NAMESPACE}"
  fi
fi

# Verify
echo ""
verify_traffic_distribution "${SERVICE}" "${NAMESPACE}" "${WEIGHT}"

echo ""
echo "============================================"
echo -e "${GREEN}✅ Traffic shift completed successfully${NC}"
echo "============================================"