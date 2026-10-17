# Dockerfile for saeka-tg-bot (deploy to Cloud Run or GCE)
FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# System deps: gcloud SDK is NOT installed here; the bot calls `gcloud` which
# must be available. For Cloud Run, use a custom image with gcloud preinstalled
# (e.g. google/cloud-sdk:alpine) or mount credentials via a sidecar.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg lsb-release \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bot.py ./
COPY .env.example ./

# Copy the full deploy repo so the bot can run deploy.sh / generate-client-links.sh
COPY ../ /repo/

ENV REPO_DIR=/repo \
    GCP_REGION=us-central1

EXPOSE 8080
CMD ["python3", "bot.py"]
