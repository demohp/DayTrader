#!/bin/bash
# =============================================================================
# build-push.sh - Build and push Docker image for daytrader-ee7-ejb
# Supports: Azure Container Registry (ACR) and Docker Hub
# Usage: ./scripts/build-push.sh
# =============================================================================
set -e
set -o pipefail

PROJECT_NAME="daytrader-ee7-ejb"
DOCKERFILE_PATH="Dockerfile"

echo "=============================================="
echo " DayTrader EE7 EJB - Docker Build & Push"
echo "=============================================="
echo ""

# Sanitize project name: lowercase, replace non-alphanumeric with hyphens, trim hyphens
IMAGE_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')

echo "Image name: $IMAGE_NAME"
echo ""

# Prompt for image tag
read -rp "Enter image tag (press Enter for 'latest'): " INPUT_TAG
IMAGE_TAG=$(echo "$INPUT_TAG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-*//;s/-*$//')
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="latest"
fi
echo "Image tag: $IMAGE_TAG"
echo ""

# Select registry type
echo "Select container registry:"
echo "  1. Azure Container Registry (ACR)"
echo "  2. Docker Hub"
read -rp "Enter choice [1 or 2]: " REGISTRY_CHOICE
echo ""

if [ "$REGISTRY_CHOICE" = "1" ]; then
  # ---- Azure Container Registry ----
  echo "--- Azure Container Registry (ACR) ---"
  read -rp "Enter ACR name (e.g. myregistry): " ACR_NAME
  ACR_NAME=$(echo "$ACR_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

  if [ -z "$ACR_NAME" ]; then
    echo "ERROR: ACR name cannot be empty." >&2
    exit 1
  fi

  REGISTRY="${ACR_NAME}.azurecr.io"
  FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

  echo ""
  echo "Logging in to ACR: $ACR_NAME ..."
  az acr login --name "$ACR_NAME"
  echo "ACR login successful."

elif [ "$REGISTRY_CHOICE" = "2" ]; then
  # ---- Docker Hub ----
  echo "--- Docker Hub ---"
  read -rp "Enter Docker Hub username: " DOCKER_USERNAME
  read -rsp "Enter Docker Hub password/token: " DOCKER_PASSWORD
  echo ""

  if [ -z "$DOCKER_USERNAME" ] || [ -z "$DOCKER_PASSWORD" ]; then
    echo "ERROR: Docker Hub username and password cannot be empty." >&2
    exit 1
  fi

  REGISTRY="docker.io"
  FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"

  echo ""
  echo "Logging in to Docker Hub ..."
  echo "$DOCKER_PASSWORD" | docker login --username "$DOCKER_USERNAME" --password-stdin
  echo "Docker Hub login successful."

else
  echo "ERROR: Invalid registry choice. Please enter 1 or 2." >&2
  exit 1
fi

echo ""
echo "Full image name: $FULL_IMAGE_NAME"
echo ""

# Build Docker image (build context is repository root)
echo "Building Docker image ..."
docker build -f "${DOCKERFILE_PATH}" -t "${FULL_IMAGE_NAME}" .
echo "Docker build successful."
echo ""

# Push Docker image
echo "Pushing image to registry ..."
docker push "${FULL_IMAGE_NAME}"
echo "Docker push successful."
echo ""

echo "=============================================="
echo " Build & Push Complete!"
echo " Image: ${FULL_IMAGE_NAME}"
echo "=============================================="
