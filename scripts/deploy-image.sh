#!/bin/bash
# =============================================================================
# deploy-image.sh - Deploy daytrader-ee7-ejb to Azure AKS
# Prerequisites: azure-cli, kubectl
# Usage: ./scripts/deploy-image.sh
# =============================================================================
set -e
set -o pipefail

APP_NAME="daytrader-ee7-ejb"
NAMESPACE="daytrader-ee7-ejb"
MANIFESTS_DIR="kubernetes"

echo "=============================================="
echo " DayTrader EE7 EJB - Deploy to Azure AKS"
echo "=============================================="
echo ""

# ---- Collect Azure / AKS details ----
read -rp "Enter Azure Resource Group name: " RESOURCE_GROUP
if [ -z "$RESOURCE_GROUP" ]; then
  echo "ERROR: Resource group cannot be empty." >&2
  exit 1
fi

read -rp "Enter AKS Cluster name: " CLUSTER_NAME
if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: AKS cluster name cannot be empty." >&2
  exit 1
fi

read -rp "Enter full Docker image URI (e.g. myregistry.azurecr.io/daytrader-ee7-ejb:latest): " IMAGE_URI
if [ -z "$IMAGE_URI" ]; then
  echo "ERROR: Image URI cannot be empty." >&2
  exit 1
fi

echo ""
echo "--- Application Environment Variables ---"
echo "Press Enter to skip any variable (placeholder will remain in manifest)."
echo ""

read -rp "Enter DB_URL (e.g. jdbc:db2://db-host:50000/daytrader): " DB_URL_VAL
read -rp "Enter DB_USER (e.g. daytrader): " DB_USER_VAL
read -rp "Enter DB_DRIVER (e.g. com.ibm.db2.jcc.DB2Driver): " DB_DRIVER_VAL
read -rp "Enter JMS_QUEUE_CONNECTION_FACTORY_CLASS (or Enter to skip): " JMS_QCF_CLASS_VAL
read -rp "Enter JMS_QUEUE_CONNECTION_FACTORY_URL (or Enter to skip): " JMS_QCF_URL_VAL
read -rp "Enter JMS_BROKER_QUEUE_CLASS (or Enter to skip): " JMS_BQ_CLASS_VAL
read -rp "Enter JMS_BROKER_QUEUE_NAME [TradeBrokerQueue]: " JMS_BQ_NAME_VAL
read -rp "Enter JMS_TOPIC_CONNECTION_FACTORY_CLASS (or Enter to skip): " JMS_TCF_CLASS_VAL
read -rp "Enter JMS_TOPIC_CONNECTION_FACTORY_URL (or Enter to skip): " JMS_TCF_URL_VAL
read -rp "Enter JMS_STREAMER_TOPIC_CLASS (or Enter to skip): " JMS_ST_CLASS_VAL
read -rp "Enter JMS_STREAMER_TOPIC_NAME [TradeStreamerTopic]: " JMS_ST_NAME_VAL
read -rp "Enter REDIS_HOST (e.g. myredis.redis.cache.windows.net): " REDIS_HOST_VAL
read -rp "Enter REDIS_PORT [6379]: " REDIS_PORT_VAL

# Apply defaults
[ -z "$JMS_BQ_NAME_VAL" ]   && JMS_BQ_NAME_VAL="TradeBrokerQueue"
[ -z "$JMS_ST_NAME_VAL" ]   && JMS_ST_NAME_VAL="TradeStreamerTopic"
[ -z "$REDIS_PORT_VAL" ]    && REDIS_PORT_VAL="6379"

echo ""
echo "--- Configuring kubectl for AKS cluster: $CLUSTER_NAME ---"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
echo "kubectl configured successfully."
echo ""

echo "--- Verifying cluster connectivity ---"
kubectl cluster-info || { echo "ERROR: Cannot connect to AKS cluster." >&2; exit 1; }
echo ""

# ---- Substitute placeholders in manifests ----
echo "--- Updating Kubernetes manifests with provided values ---"

# Work on copies to avoid modifying originals
cp "${MANIFESTS_DIR}/deployment.yaml" /tmp/deployment.yaml

sed -i "s|{{IMAGE_URI}}|${IMAGE_URI}|g"                                   /tmp/deployment.yaml
sed -i "s|{{DB_URL}}|${DB_URL_VAL}|g"                                     /tmp/deployment.yaml
sed -i "s|{{DB_USER}}|${DB_USER_VAL}|g"                                   /tmp/deployment.yaml
sed -i "s|{{DB_DRIVER}}|${DB_DRIVER_VAL}|g"                               /tmp/deployment.yaml
sed -i "s|{{JMS_QUEUE_CONNECTION_FACTORY_CLASS}}|${JMS_QCF_CLASS_VAL}|g"  /tmp/deployment.yaml
sed -i "s|{{JMS_QUEUE_CONNECTION_FACTORY_URL}}|${JMS_QCF_URL_VAL}|g"      /tmp/deployment.yaml
sed -i "s|{{JMS_BROKER_QUEUE_CLASS}}|${JMS_BQ_CLASS_VAL}|g"               /tmp/deployment.yaml
sed -i "s|{{JMS_BROKER_QUEUE_NAME}}|${JMS_BQ_NAME_VAL}|g"                 /tmp/deployment.yaml
sed -i "s|{{JMS_TOPIC_CONNECTION_FACTORY_CLASS}}|${JMS_TCF_CLASS_VAL}|g"  /tmp/deployment.yaml
sed -i "s|{{JMS_TOPIC_CONNECTION_FACTORY_URL}}|${JMS_TCF_URL_VAL}|g"      /tmp/deployment.yaml
sed -i "s|{{JMS_STREAMER_TOPIC_CLASS}}|${JMS_ST_CLASS_VAL}|g"             /tmp/deployment.yaml
sed -i "s|{{JMS_STREAMER_TOPIC_NAME}}|${JMS_ST_NAME_VAL}|g"               /tmp/deployment.yaml
sed -i "s|{{REDIS_HOST}}|${REDIS_HOST_VAL}|g"                             /tmp/deployment.yaml
sed -i "s|{{REDIS_PORT}}|${REDIS_PORT_VAL}|g"                             /tmp/deployment.yaml

echo "Manifests updated."
echo ""

# ---- Apply manifests in order ----
echo "--- Applying Kubernetes manifests ---"

echo "1/4 Applying namespace ..."
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

echo "2/4 Applying deployment ..."
kubectl apply -f /tmp/deployment.yaml

echo "3/4 Applying service ..."
kubectl apply -f "${MANIFESTS_DIR}/service.yaml"

echo "4/4 Applying ingress ..."
kubectl apply -f "${MANIFESTS_DIR}/ingress.yaml"

echo ""
echo "--- Waiting for deployment rollout ---"
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=300s
echo "Deployment rollout complete."
echo ""

echo "--- Verifying deployed resources ---"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
echo ""

# Display ingress URL
INGRESS_IP=$(kubectl get ingress "${APP_NAME}-ingress" -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
INGRESS_HOST=$(kubectl get ingress "${APP_NAME}-ingress" -n "${NAMESPACE}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")

echo "=============================================="
echo " Deployment Complete!"
echo " Application: ${APP_NAME}"
echo " Namespace:   ${NAMESPACE}"
if [ -n "$INGRESS_IP" ]; then
  echo " Ingress IP:  http://${INGRESS_IP}"
fi
if [ -n "$INGRESS_HOST" ]; then
  echo " Ingress Host: http://${INGRESS_HOST}"
fi
echo ""
echo " Health endpoint: /api/health"
echo ""
echo " Rollback command (if needed):"
echo "   kubectl rollout undo deployment/${APP_NAME} -n ${NAMESPACE}"
echo "=============================================="

# Cleanup temp file
rm -f /tmp/deployment.yaml
