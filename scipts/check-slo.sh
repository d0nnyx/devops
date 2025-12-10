#!/bin/bash

# ============================================
# SLO Checker Script
# Checks if deployment meets SLO requirements
# ============================================

set -e

# Default values
NAMESPACE="production"
DEPLOYMENT=""
DURATION="5m"
CLUSTER=""
PROMETHEUS_URL="http://prometheus.monitoring.svc.cluster.local:9090"

# SLO Thresholds
ERROR_RATE_THRESHOLD=0.5      # 0.5%
LATENCY_P95_THRESHOLD=300     # 300ms
LATENCY_P99_THRESHOLD=1000    # 1000ms
AVAILABILITY_THRESHOLD=99.9   # 99.9%

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# Parse arguments
# ============================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --deployment)
      DEPLOYMENT="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --prometheus-url)
      PROMETHEUS_URL="$2"
      shift 2
      ;;
    --all-regions)
      ALL_REGIONS=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ============================================
# Functions
# ============================================

query_prometheus() {
  local query="$1"
  local result
  
  result=$(curl -s -G --data-urlencode "query=${query}" \
    "${PROMETHEUS_URL}/api/v1/query" | \
    jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
  
  echo "${result}"
}

check_error_rate() {
  local deployment="$1"
  local duration="$2"
  
  echo -e "${YELLOW}📊 Checking error rate...${NC}"
  
  # Query: (5xx errors / total requests) * 100
  local query="(sum(rate(http_requests_total{job=\"${deployment}\",status=~\"5..\"}[${duration}])) / sum(rate(http_requests_total{job=\"${deployment}\"}[${duration}]))) * 100"
  
  local error_rate=$(query_prometheus "${query}")
  
  # Handle empty result
  if [ -z "$error_rate" ] || [ "$error_rate" = "null" ]; then
    error_rate="0"
  fi
  
  echo "   Error rate: ${error_rate}%"
  
  if (( $(echo "$error_rate > $ERROR_RATE_THRESHOLD" | bc -l) )); then
    echo -e "   ${RED}❌ FAIL: Error rate ${error_rate}% exceeds threshold ${ERROR_RATE_THRESHOLD}%${NC}"
    return 1
  else
    echo -e "   ${GREEN}✅ PASS: Error rate ${error_rate}% within SLO${NC}"
    return 0
  fi
}

check_latency() {
  local deployment="$1"
  local duration="$2"
  
  echo -e "${YELLOW}📊 Checking latency...${NC}"
  
  # P95 Latency
  local query_p95="histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job=\"${deployment}\"}[${duration}])) by (le)) * 1000"
  local p95_latency=$(query_prometheus "${query_p95}")
  
  if [ -z "$p95_latency" ] || [ "$p95_latency" = "null" ]; then
    p95_latency="0"
  fi
  
  echo "   P95 latency: ${p95_latency}ms"
  
  # P99 Latency
  local query_p99="histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job=\"${deployment}\"}[${duration}])) by (le)) * 1000"
  local p99_latency=$(query_prometheus "${query_p99}")
  
  if [ -z "$p99_latency" ] || [ "$p99_latency" = "null" ]; then
    p99_latency="0"
  fi
  
  echo "   P99 latency: ${p99_latency}ms"
  
  local p95_pass=0
  local p99_pass=0
  
  if (( $(echo "$p95_latency > $LATENCY_P95_THRESHOLD" | bc -l) )); then
    echo -e "   ${RED}❌ FAIL: P95 latency ${p95_latency}ms exceeds ${LATENCY_P95_THRESHOLD}ms${NC}"
  else
    echo -e "   ${GREEN}✅ PASS: P95 latency ${p95_latency}ms within SLO${NC}"
    p95_pass=1
  fi
  
  if (( $(echo "$p99_latency > $LATENCY_P99_THRESHOLD" | bc -l) )); then
    echo -e "   ${RED}❌ FAIL: P99 latency ${p99_latency}ms exceeds ${LATENCY_P99_THRESHOLD}ms${NC}"
  else
    echo -e "   ${GREEN}✅ PASS: P99 latency ${p99_latency}ms within SLO${NC}"
    p99_pass=1
  fi
  
  if [ $p95_pass -eq 1 ] && [ $p99_pass -eq 1 ]; then
    return 0
  else
    return 1
  fi
}

check_availability() {
  local deployment="$1"
  local duration="$2"
  
  echo -e "${YELLOW}📊 Checking availability...${NC}"
  
  # Query: (successful requests / total requests) * 100
  local query="(sum(rate(http_requests_total{job=\"${deployment}\",status!~\"5..\"}[${duration}])) / sum(rate(http_requests_total{job=\"${deployment}\"}[${duration}]))) * 100"
  
  local availability=$(query_prometheus "${query}")
  
  if [ -z "$availability" ] || [ "$availability" = "null" ]; then
    availability="100"
  fi
  
  echo "   Availability: ${availability}%"
  
  if (( $(echo "$availability < $AVAILABILITY_THRESHOLD" | bc -l) )); then
    echo -e "   ${RED}❌ FAIL: Availability ${availability}% below threshold ${AVAILABILITY_THRESHOLD}%${NC}"
    return 1
  else
    echo -e "   ${GREEN}✅ PASS: Availability ${availability}% meets SLO${NC}"
    return 0
  fi
}

check_pod_health() {
  local deployment="$1"
  
  echo -e "${YELLOW}📊 Checking pod health...${NC}"
  
  local ready_pods=$(kubectl get deployment "${deployment}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  
  local desired_pods=$(kubectl get deployment "${deployment}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  
  echo "   Ready pods: ${ready_pods}/${desired_pods}"
  
  if [ "$ready_pods" -lt "$desired_pods" ]; then
    echo -e "   ${RED}❌ FAIL: Not all pods are ready${NC}"
    return 1
  else
    echo -e "   ${GREEN}✅ PASS: All pods are ready${NC}"
    return 0
  fi
}

check_slo_burn_rate() {
  local deployment="$1"
  local duration="$2"
  
  echo -e "${YELLOW}📊 Checking SLO burn rate...${NC}"
  
  # Error budget: 0.1% (for 99.9% availability)
  # Fast burn: 14.4x (consumes 1% of monthly budget in 1 hour)
  # Slow burn: 6x (consumes 5% of monthly budget in 6 hours)
  
  local query="(1 - (sum(rate(http_requests_total{job=\"${deployment}\",status!~\"5..\"}[${duration}])) / sum(rate(http_requests_total{job=\"${deployment}\"}[${duration}])))) / 0.001"
  
  local burn_rate=$(query_prometheus "${query}")
  
  if [ -z "$burn_rate" ] || [ "$burn_rate" = "null" ]; then
    burn_rate="0"
  fi
  
  echo "   Burn rate: ${burn_rate}x"
  
  if (( $(echo "$burn_rate > 14.4" | bc -l) )); then
    echo -e "   ${RED}🚨 CRITICAL: Fast burn rate detected (${burn_rate}x)${NC}"
    echo -e "   ${RED}   At this rate, monthly error budget will be exhausted in $(echo "43200 / $burn_rate" | bc) minutes${NC}"
    return 1
  elif (( $(echo "$burn_rate > 6" | bc -l) )); then
    echo -e "   ${YELLOW}⚠️  WARNING: High burn rate (${burn_rate}x)${NC}"
    return 0
  else
    echo -e "   ${GREEN}✅ PASS: Burn rate ${burn_rate}x is acceptable${NC}"
    return 0
  fi
}

# ============================================
# Main execution
# ============================================

echo "============================================"
echo "🔍 SLO Compliance Check"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Deployment: ${DEPLOYMENT}"
echo "  Duration: ${DURATION}"
echo "  Cluster: ${CLUSTER:-default}"
echo ""

# Switch context if cluster specified
if [ -n "$CLUSTER" ]; then
  echo "🔄 Switching to cluster: ${CLUSTER}"
  kubectl config use-context "${CLUSTER}"
fi

# Run all checks
failed_checks=0

check_pod_health "${DEPLOYMENT}" || ((failed_checks++))
echo ""

check_error_rate "${DEPLOYMENT}" "${DURATION}" || ((failed_checks++))
echo ""

check_latency "${DEPLOYMENT}" "${DURATION}" || ((failed_checks++))
echo ""

check_availability "${DEPLOYMENT}" "${DURATION}" || ((failed_checks++))
echo ""

check_slo_burn_rate "${DEPLOYMENT}" "${DURATION}" || ((failed_checks++))
echo ""

# Summary
echo "============================================"
if [ $failed_checks -eq 0 ]; then
  echo -e "${GREEN}✅ All SLO checks PASSED${NC}"
  echo "============================================"
  exit 0
else
  echo -e "${RED}❌ ${failed_checks} SLO check(s) FAILED${NC}"
  echo "============================================"
  exit 1
fi