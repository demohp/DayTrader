@echo off
setlocal enabledelayedexpansion

REM =============================================================================
REM build-push.bat - Build and push Docker image for daytrader-ee7-ejb (Windows)
REM Supports: Azure Container Registry (ACR) and Docker Hub
REM Usage: scripts\build-push.bat
REM =============================================================================

set PROJECT_NAME=daytrader-ee7-ejb
set DOCKERFILE_PATH=Dockerfile

echo ==============================================
echo  DayTrader EE7 EJB - Docker Build ^& Push
echo ==============================================
echo.

REM Sanitize image name to lowercase using PowerShell
for /f "delims=" %%i in ('powershell -Command "\"!PROJECT_NAME!\".ToLower() -replace '[^a-z0-9]','-' -replace '^-+','' -replace '-+$',''"') do set IMAGE_NAME=%%i

echo Image name: !IMAGE_NAME!
echo.

REM Prompt for image tag
set /p INPUT_TAG="Enter image tag (press Enter for 'latest'): "
if "!INPUT_TAG!"=="" (
    set IMAGE_TAG=latest
) else (
    for /f "delims=" %%i in ('powershell -Command "\"!INPUT_TAG!\".ToLower() -replace '[^a-z0-9._-]','-' -replace '^-+','' -replace '-+$',''"') do set IMAGE_TAG=%%i
)
if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest
echo Image tag: !IMAGE_TAG!
echo.

REM Select registry type
echo Select container registry:
echo   1. Azure Container Registry (ACR)
echo   2. Docker Hub
set /p REGISTRY_CHOICE="Enter choice [1 or 2]: "
echo.

if "!REGISTRY_CHOICE!"=="1" (
    REM ---- Azure Container Registry ----
    echo --- Azure Container Registry (ACR) ---
    set /p ACR_NAME="Enter ACR name (e.g. myregistry): "

    if "!ACR_NAME!"=="" (
        echo ERROR: ACR name cannot be empty.
        exit /b 1
    )

    for /f "delims=" %%i in ('powershell -Command "\"!ACR_NAME!\".ToLower() -replace '[^a-z0-9]',''"') do set ACR_NAME_CLEAN=%%i
    set REGISTRY=!ACR_NAME_CLEAN!.azurecr.io
    set FULL_IMAGE_NAME=!REGISTRY!/!IMAGE_NAME!:!IMAGE_TAG!

    echo.
    echo Logging in to ACR: !ACR_NAME_CLEAN! ...
    az acr login --name !ACR_NAME_CLEAN!
    if !ERRORLEVEL! neq 0 (
        echo ERROR: ACR login failed.
        exit /b 1
    )
    echo ACR login successful.

) else if "!REGISTRY_CHOICE!"=="2" (
    REM ---- Docker Hub ----
    echo --- Docker Hub ---
    set /p DOCKER_USERNAME="Enter Docker Hub username: "
    set /p DOCKER_PASSWORD="Enter Docker Hub password/token: "

    if "!DOCKER_USERNAME!"=="" (
        echo ERROR: Docker Hub username cannot be empty.
        exit /b 1
    )
    if "!DOCKER_PASSWORD!"=="" (
        echo ERROR: Docker Hub password cannot be empty.
        exit /b 1
    )

    set FULL_IMAGE_NAME=!DOCKER_USERNAME!/!IMAGE_NAME!:!IMAGE_TAG!

    echo.
    echo Logging in to Docker Hub ...
    echo !DOCKER_PASSWORD! | docker login --username !DOCKER_USERNAME! --password-stdin
    if !ERRORLEVEL! neq 0 (
        echo ERROR: Docker Hub login failed.
        exit /b 1
    )
    echo Docker Hub login successful.

) else (
    echo ERROR: Invalid registry choice. Please enter 1 or 2.
    exit /b 1
)

echo.
echo Full image name: !FULL_IMAGE_NAME!
echo.

REM Build Docker image (build context is repository root)
echo Building Docker image ...
docker build -f !DOCKERFILE_PATH! -t !FULL_IMAGE_NAME! .
if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker build failed.
    exit /b 1
)
echo Docker build successful.
echo.

REM Push Docker image
echo Pushing image to registry ...
docker push !FULL_IMAGE_NAME!
if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker push failed.
    exit /b 1
)
echo Docker push successful.
echo.

echo ==============================================
echo  Build ^& Push Complete!
echo  Image: !FULL_IMAGE_NAME!
echo ==============================================

endlocal
