# Deployment Guide: daytrader-ee7-ejb on Azure AKS

## Overview

This guide covers the complete deployment of the **DayTrader EE7 EJB Module** (`daytrader-ee7-ejb`) to **Azure Kubernetes Service (AKS)**. The application is a Java 8 / Jakarta EE 9 trading benchmark application that has been modernized for cloud-native deployment.

**Technology Stack:**
- Java 8 (eclipse-temurin:8-jdk runtime)
- Maven 3.8.6 build tool
- JAR packaging
- Spring JDBC + Spring Context + Spring TX (for portable DataSource and transaction management)
- Jedis (Azure Cache for Redis state externalization)
- JAX-RS health endpoint at `/api/health`
- External DB2 database via environment variables
- Optional JMS messaging (queue/topic) via environment variables

---

## Prerequisites

### Local Development
- Docker Desktop 24.x or later
- Java 8 JDK (for local builds)
- Maven 3.8.x or later

### Azure AKS Deployment
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) 2.50+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) 1.27+
- An active Azure subscription
- An Azure Container Registry (ACR) or Docker Hub account
- An AKS cluster (see setup below)

---

## Project Structure

```
DAYTRD/
├── Dockerfile                  # Multi-stage build (Java 8 Maven → eclipse-temurin:8-jdk)
├── docker-compose.yml          # Local development (application only)
├── .dockerignore               # Excludes target/, mvnw, .mvn/, etc.
├── pom.xml                     # Maven build descriptor
├── src/
│   └── main/
│       ├── java/               # Application source code
│       └── resources/          # META-INF configs (persistence.xml, ejb-jar.xml)
├── kubernetes/
│   ├── namespace.yaml          # Kubernetes namespace
│   ├── deployment.yaml         # Deployment with 2 replicas
│   ├── service.yaml            # ClusterIP service
│   └── ingress.yaml            # Azure Application Gateway ingress
├── scripts/
│   ├── build-push.sh           # Linux/macOS: build & push to ACR or Docker Hub
│   ├── build-push.bat          # Windows: build & push to ACR or Docker Hub
│   ├── deploy-image.sh         # Linux/macOS: deploy to AKS
│   └── deploy-image.bat        # Windows: deploy to AKS
└── docs/
    └── DEPLOYMENT.md           # This file
```

---

## Local Development with Docker Compose

### 1. Build and run locally

```bash
# Build the image
docker build -t daytrader-ee7-ejb:latest .

# Run with docker-compose (application only)
# Set required environment variables first:
export DB_URL="jdbc:db2://your-db-host:50000/daytrader"
export DB_USER="daytrader"
export DB_PASSWORD="your-password"

docker-compose up --build
```

### 2. Verify the application

```bash
# Check health endpoint
curl http://localhost:8080/api/health
# Expected: {"status":"UP","application":"daytrader-ee7-ejb"}
```

### 3. Stop the application

```bash
docker-compose down
```

---

## Building and Pushing the Docker Image

### Linux/macOS

```bash
chmod +x scripts/build-push.sh
./scripts/build-push.sh
```

The script will prompt you to:
1. Choose registry type (ACR or Docker Hub)
2. Enter registry credentials/name
3. Enter an image tag (defaults to `latest`)

### Windows

```cmd
scripts\build-push.bat
```

### Manual Build (ACR example)

```bash
# Login to ACR
az acr login --name <your-acr-name>

# Build and push
docker build -t <your-acr-name>.azurecr.io/daytrader-ee7-ejb:1.0 .
docker push <your-acr-name>.azurecr.io/daytrader-ee7-ejb:1.0
```

---

## Azure AKS Setup

### 1. Create Resource Group

```bash
az group create --name daytrader-rg --location eastus
```

### 2. Create ACR (if not existing)

```bash
az acr create \
  --resource-group daytrader-rg \
  --name <your-acr-name> \
  --sku Basic
```

### 3. Create AKS Cluster

```bash
az aks create \
  --resource-group daytrader-rg \
  --name daytrader-aks \
  --node-count 2 \
  --node-vm-size Standard_DS2_v2 \
  --enable-addons monitoring \
  --attach-acr <your-acr-name> \
  --generate-ssh-keys
```

### 4. Install Application Gateway Ingress Controller (AGIC)

```bash
# Enable AGIC add-on
az aks enable-addons \
  --resource-group daytrader-rg \
  --name daytrader-aks \
  --addons ingress-appgw \
  --appgw-name daytrader-appgw \
  --appgw-subnet-cidr "10.225.0.0/16"
```

### 5. Configure kubectl

```bash
az aks get-credentials \
  --resource-group daytrader-rg \
  --name daytrader-aks

# Verify
kubectl cluster-info
kubectl get nodes
```

---

## Kubernetes Deployment

### Option A: Using the deploy script (recommended)

**Linux/macOS:**
```bash
chmod +x scripts/deploy-image.sh
./scripts/deploy-image.sh
```

**Windows:**
```cmd
scripts\deploy-image.bat
```

The script will prompt for:
- Azure Resource Group and AKS cluster name
- Full Docker image URI (e.g., `myregistry.azurecr.io/daytrader-ee7-ejb:1.0`)
- All required environment variables (DB_URL, DB_USER, JMS settings, Redis settings)

### Option B: Manual deployment

```bash
# 1. Apply namespace
kubectl apply -f kubernetes/namespace.yaml

# 2. Create secrets for sensitive values
kubectl create secret generic daytrader-secrets \
  --namespace daytrader-ee7-ejb \
  --from-literal=db-password='<your-db-password>'

# 3. Update deployment.yaml with your image URI and env values
# Replace all {{PLACEHOLDER}} values in kubernetes/deployment.yaml

# 4. Apply manifests
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/ingress.yaml

# 5. Wait for rollout
kubectl rollout status deployment/daytrader-ee7-ejb -n daytrader-ee7-ejb

# 6. Verify
kubectl get pods,svc,ingress -n daytrader-ee7-ejb
```

---

## Kubernetes Manifest Descriptions

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates the `daytrader-ee7-ejb` namespace |
| `deployment.yaml` | 2-replica deployment with liveness/readiness probes on `/api/health` |
| `service.yaml` | ClusterIP service exposing port 80 → container port 8080 |
| `ingress.yaml` | Azure Application Gateway ingress at `daytrader-ee7-ejb.example.com` |

### Resource Limits

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 250m | 500m |
| Memory | 512Mi | 1Gi |

### Health Probes

| Probe | Path | Initial Delay | Period |
|-------|------|---------------|--------|
| Liveness | `GET /api/health` | 60s | 30s |
| Readiness | `GET /api/health` | 30s | 15s |

---

## Environment Variables Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_URL` | JDBC URL for the database | `jdbc:db2://localhost:50000/daytrader` |
| `DB_USER` | Database username | `daytrader` |
| `DB_PASSWORD` | Database password | *(empty)* |
| `DB_DRIVER` | JDBC driver class | `com.ibm.db2.jcc.DB2Driver` |
| `JMS_QUEUE_CONNECTION_FACTORY_CLASS` | JMS Queue ConnectionFactory class | *(empty)* |
| `JMS_QUEUE_CONNECTION_FACTORY_URL` | JMS broker URL for queue | *(empty)* |
| `JMS_BROKER_QUEUE_CLASS` | JMS Queue implementation class | *(empty)* |
| `JMS_BROKER_QUEUE_NAME` | JMS broker queue name | `TradeBrokerQueue` |
| `JMS_TOPIC_CONNECTION_FACTORY_CLASS` | JMS Topic ConnectionFactory class | *(empty)* |
| `JMS_TOPIC_CONNECTION_FACTORY_URL` | JMS broker URL for topic | *(empty)* |
| `JMS_STREAMER_TOPIC_CLASS` | JMS Topic implementation class | *(empty)* |
| `JMS_STREAMER_TOPIC_NAME` | JMS streamer topic name | `TradeStreamerTopic` |
| `REDIS_HOST` | Azure Cache for Redis hostname | `localhost` |
| `REDIS_PORT` | Redis port | `6379` |
| `JAVA_OPTS` | JVM options | See Dockerfile |
| `TZ` | Timezone | `UTC` |

---

## Secrets Management (Azure Key Vault)

For production deployments, use Azure Key Vault CSI Driver to inject secrets:

```bash
# Install Secrets Store CSI Driver
az aks enable-addons \
  --addons azure-keyvault-secrets-provider \
  --name daytrader-aks \
  --resource-group daytrader-rg

# Create Key Vault
az keyvault create \
  --name daytrader-kv \
  --resource-group daytrader-rg \
  --location eastus

# Store secrets
az keyvault secret set --vault-name daytrader-kv --name db-password --value '<password>'
```

---

## Scaling and Management

### Horizontal Pod Autoscaler (HPA)

```bash
kubectl autoscale deployment daytrader-ee7-ejb \
  --namespace daytrader-ee7-ejb \
  --cpu-percent=70 \
  --min=2 \
  --max=10
```

### Rolling Update

```bash
# Update image
kubectl set image deployment/daytrader-ee7-ejb \
  daytrader-ee7-ejb=<new-image-uri> \
  -n daytrader-ee7-ejb

# Monitor rollout
kubectl rollout status deployment/daytrader-ee7-ejb -n daytrader-ee7-ejb
```

### Rollback

```bash
kubectl rollout undo deployment/daytrader-ee7-ejb -n daytrader-ee7-ejb
```

### Scale manually

```bash
kubectl scale deployment daytrader-ee7-ejb \
  --replicas=4 \
  -n daytrader-ee7-ejb
```

---

## Troubleshooting

### Pod not starting

```bash
# Check pod status
kubectl get pods -n daytrader-ee7-ejb

# Describe pod for events
kubectl describe pod <pod-name> -n daytrader-ee7-ejb

# Check logs
kubectl logs <pod-name> -n daytrader-ee7-ejb
kubectl logs <pod-name> -n daytrader-ee7-ejb --previous
```

### Health probe failures

```bash
# Check if health endpoint is reachable inside the pod
kubectl exec -it <pod-name> -n daytrader-ee7-ejb -- \
  java -cp /app/app.jar -version

# Port-forward to test locally
kubectl port-forward pod/<pod-name> 8080:8080 -n daytrader-ee7-ejb
# Then: curl http://localhost:8080/api/health
```

### Database connection issues

```bash
# Verify DB_URL environment variable
kubectl exec -it <pod-name> -n daytrader-ee7-ejb -- env | grep DB_

# Check if DB secret exists
kubectl get secret daytrader-secrets -n daytrader-ee7-ejb
```

### Ingress not routing traffic

```bash
# Check ingress status
kubectl describe ingress daytrader-ee7-ejb-ingress -n daytrader-ee7-ejb

# Check Application Gateway health
az network application-gateway show \
  --resource-group daytrader-rg \
  --name daytrader-appgw \
  --query "backendAddressPools"
```

### OOMKilled (Out of Memory)

Increase memory limits in `kubernetes/deployment.yaml`:
```yaml
resources:
  limits:
    memory: "2Gi"
```

Or tune JVM heap:
```yaml
- name: JAVA_OPTS
  value: "-Xms512m -Xmx1g -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
```

---

## Security Considerations

1. **Non-root container**: The application runs as user `appuser` (UID 1001)
2. **Read-only config**: Config volume is mounted read-only
3. **Secrets**: Use Kubernetes Secrets or Azure Key Vault for sensitive values (never hardcode passwords)
4. **Network policies**: Consider adding Kubernetes NetworkPolicy to restrict pod-to-pod communication
5. **Image scanning**: Scan images with `az acr check-health` or Trivy before deployment
6. **RBAC**: Use least-privilege service accounts for the application pods

---

## Java-Specific Notes

- **JVM Container Support**: `-XX:+UseContainerSupport` ensures the JVM respects container memory limits (Java 8u191+)
- **MaxRAMPercentage**: Set to 75% to leave headroom for the OS and non-heap memory
- **Startup time**: Java 8 EE applications may take 30-60 seconds to start; `initialDelaySeconds` is set accordingly
- **Graceful shutdown**: `terminationGracePeriodSeconds: 60` allows in-flight requests to complete
- **DB2 Driver**: Ensure the DB2 JDBC driver JAR is available on the classpath (add as Maven dependency if needed)
- **JMS**: JMS is optional; if `JMS_QUEUE_CONNECTION_FACTORY_CLASS` is empty, async order processing is disabled automatically

---

## Support

For issues with this deployment, check:
- Application logs: `kubectl logs -n daytrader-ee7-ejb`
- AKS diagnostics: Azure Portal → AKS cluster → Diagnose and solve problems
- Azure Monitor: Container Insights for metrics and log aggregation
