@echo off
setlocal enabledelayedexpansion

REM =============================================================================
REM deploy-image.bat - Deploy daytrader-ee7-ejb to Azure AKS (Windows)
REM Prerequisites: azure-cli, kubectl
REM Usage: scripts\deploy-image.bat
REM =============================================================================

set APP_NAME=daytrader-ee7-ejb
set NAMESPACE=daytrader-ee7-ejb
set MANIFESTS_DIR=kubernetes

echo ==============================================
echo  DayTrader EE7 EJB - Deploy to Azure AKS
echo ==============================================
echo.

REM ---- Collect Azure / AKS details ----
set /p RESOURCE_GROUP="Enter Azure Resource Group name: "
if "!RESOURCE_GROUP!"=="" (
    echo ERROR: Resource group cannot be empty.
    exit /b 1
)

set /p CLUSTER_NAME="Enter AKS Cluster name: "
if "!CLUSTER_NAME!"=="" (
    echo ERROR: AKS cluster name cannot be empty.
    exit /b 1
)

set /p IMAGE_URI="Enter full Docker image URI (e.g. myregistry.azurecr.io/daytrader-ee7-ejb:latest): "
if "!IMAGE_URI!"=="" (
    echo ERROR: Image URI cannot be empty.
    exit /b 1
)

echo.
echo --- Application Environment Variables ---
echo Press Enter to skip any variable.
echo.

set /p DB_URL_VAL="Enter DB_URL (e.g. jdbc:db2://db-host:50000/daytrader): "
set /p DB_USER_VAL="Enter DB_USER (e.g. daytrader): "
set /p DB_DRIVER_VAL="Enter DB_DRIVER (e.g. com.ibm.db2.jcc.DB2Driver): "
set /p JMS_QCF_CLASS_VAL="Enter JMS_QUEUE_CONNECTION_FACTORY_CLASS (or Enter to skip): "
set /p JMS_QCF_URL_VAL="Enter JMS_QUEUE_CONNECTION_FACTORY_URL (or Enter to skip): "
set /p JMS_BQ_CLASS_VAL="Enter JMS_BROKER_QUEUE_CLASS (or Enter to skip): "
set /p JMS_BQ_NAME_VAL="Enter JMS_BROKER_QUEUE_NAME [TradeBrokerQueue]: "
set /p JMS_TCF_CLASS_VAL="Enter JMS_TOPIC_CONNECTION_FACTORY_CLASS (or Enter to skip): "
set /p JMS_TCF_URL_VAL="Enter JMS_TOPIC_CONNECTION_FACTORY_URL (or Enter to skip): "
set /p JMS_ST_CLASS_VAL="Enter JMS_STREAMER_TOPIC_CLASS (or Enter to skip): "
set /p JMS_ST_NAME_VAL="Enter JMS_STREAMER_TOPIC_NAME [TradeStreamerTopic]: "
set /p REDIS_HOST_VAL="Enter REDIS_HOST (e.g. myredis.redis.cache.windows.net): "
set /p REDIS_PORT_VAL="Enter REDIS_PORT [6379]: "

REM Apply defaults
if "!JMS_BQ_NAME_VAL!"==""  set JMS_BQ_NAME_VAL=TradeBrokerQueue
if "!JMS_ST_NAME_VAL!"==""  set JMS_ST_NAME_VAL=TradeStreamerTopic
if "!REDIS_PORT_VAL!"==""   set REDIS_PORT_VAL=6379

echo.
echo --- Configuring kubectl for AKS cluster: !CLUSTER_NAME! ---
az aks get-credentials --resource-group !RESOURCE_GROUP! --name !CLUSTER_NAME! --overwrite-existing
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to get AKS credentials.
    exit /b 1
)
echo kubectl configured successfully.
echo.

echo --- Verifying cluster connectivity ---
kubectl cluster-info
if !ERRORLEVEL! neq 0 (
    echo ERROR: Cannot connect to AKS cluster.
    exit /b 1
)
echo.

REM ---- Substitute placeholders using PowerShell ----
echo --- Updating Kubernetes manifests with provided values ---

copy /Y "!MANIFESTS_DIR!\deployment.yaml" "%TEMP%\deployment.yaml" >nul

powershell -Command ^
  "(Get-Content '%TEMP%\deployment.yaml') ^
   -replace '{{IMAGE_URI}}','!IMAGE_URI!' ^
   -replace '{{DB_URL}}','!DB_URL_VAL!' ^
   -replace '{{DB_USER}}','!DB_USER_VAL!' ^
   -replace '{{DB_DRIVER}}','!DB_DRIVER_VAL!' ^
   -replace '{{JMS_QUEUE_CONNECTION_FACTORY_CLASS}}','!JMS_QCF_CLASS_VAL!' ^
   -replace '{{JMS_QUEUE_CONNECTION_FACTORY_URL}}','!JMS_QCF_URL_VAL!' ^
   -replace '{{JMS_BROKER_QUEUE_CLASS}}','!JMS_BQ_CLASS_VAL!' ^
   -replace '{{JMS_BROKER_QUEUE_NAME}}','!JMS_BQ_NAME_VAL!' ^
   -replace '{{JMS_TOPIC_CONNECTION_FACTORY_CLASS}}','!JMS_TCF_CLASS_VAL!' ^
   -replace '{{JMS_TOPIC_CONNECTION_FACTORY_URL}}','!JMS_TCF_URL_VAL!' ^
   -replace '{{JMS_STREAMER_TOPIC_CLASS}}','!JMS_ST_CLASS_VAL!' ^
   -replace '{{JMS_STREAMER_TOPIC_NAME}}','!JMS_ST_NAME_VAL!' ^
   -replace '{{REDIS_HOST}}','!REDIS_HOST_VAL!' ^
   -replace '{{REDIS_PORT}}','!REDIS_PORT_VAL!' ^
   | Set-Content '%TEMP%\deployment_updated.yaml'"

if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to update deployment manifest.
    exit /b 1
)
echo Manifests updated.
echo.

REM ---- Apply manifests in order ----
echo --- Applying Kubernetes manifests ---

echo 1/4 Applying namespace ...
kubectl apply -f "!MANIFESTS_DIR!\namespace.yaml"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to apply namespace.
    exit /b 1
)

echo 2/4 Applying deployment ...
kubectl apply -f "%TEMP%\deployment_updated.yaml"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to apply deployment.
    exit /b 1
)

echo 3/4 Applying service ...
kubectl apply -f "!MANIFESTS_DIR!\service.yaml"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to apply service.
    exit /b 1
)

echo 4/4 Applying ingress ...
kubectl apply -f "!MANIFESTS_DIR!\ingress.yaml"
if !ERRORLEVEL! neq 0 (
    echo ERROR: Failed to apply ingress.
    exit /b 1
)

echo.
echo --- Waiting for deployment rollout ---
kubectl rollout status deployment/!APP_NAME! -n !NAMESPACE! --timeout=300s
if !ERRORLEVEL! neq 0 (
    echo ERROR: Deployment rollout failed.
    echo Rollback command: kubectl rollout undo deployment/!APP_NAME! -n !NAMESPACE!
    exit /b 1
)
echo Deployment rollout complete.
echo.

echo --- Verifying deployed resources ---
kubectl get pods,svc,ingress -n !NAMESPACE!
echo.

echo ==============================================
echo  Deployment Complete!
echo  Application: !APP_NAME!
echo  Namespace:   !NAMESPACE!
echo  Health endpoint: /api/health
echo.
echo  Rollback command (if needed):
echo    kubectl rollout undo deployment/!APP_NAME! -n !NAMESPACE!
echo ==============================================

REM Cleanup temp files
del /f /q "%TEMP%\deployment.yaml" 2>nul
del /f /q "%TEMP%\deployment_updated.yaml" 2>nul

endlocal
