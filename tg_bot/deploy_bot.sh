#!/usr/bin/env bash
# deploy_bot.sh — Deploy saeka-tg-bot to GCP Cloud Run.
#
# Prereqs:
#   1. gcloud installed & authenticated (gcloud init)
#   2. BOT_TOKEN set in env or pass via --set-env-vars
#   3. Project set (gcloud config set project)
#
# Usage:
#   ./deploy_bot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')
if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: No active GCP project. Run 'gcloud init' first."
    exit 1
fi

SERVICE_NAME="saeka-tg-bot"
IMAGE_TAG="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"
REGION="${GCP_REGION:-us-central1}"

echo "=== Building bot image ==="
gcloud builds submit . \
    --config tg_bot/Dockerfile \
    --tag "${IMAGE_TAG}" \
    --project="${PROJECT_ID}"

echo "=== Deploying bot to Cloud Run ==="
gcloud run deploy "${SERVICE_NAME}" \
    --image "${IMAGE_TAG}" \
    --platform managed --region "${REGION}" \
    --allow-unauthenticated \
    --project "${PROJECT_ID}" \
    --set-env-vars "BOT_TOKEN=${BOT_TOKEN:-},GCP_PROJECT_ID=${PROJECT_ID},GCP_REGION=${REGION},REPO_DIR=/workspace/app" \
    --memory 512Mi --cpu 1 --concurrency 80 --timeout 3600 \
    --quiet

echo "=== Done ==="
gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --project "${PROJECT_ID}" --format='value(status.url)'
