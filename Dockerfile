# Multi-target Dockerfile for the OTel ecommerce demo
# Build targets: api, frontend, loadgen

# --- base stage ---
FROM python:3.11-slim AS base

WORKDIR /opt/app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap -a install

COPY app/ app/

# --- api target ---
FROM base AS api
EXPOSE 8000
CMD ["opentelemetry-instrument", "uvicorn", "app.api.main:app", "--host", "0.0.0.0", "--port", "8000"]

# --- frontend target ---
FROM base AS frontend
EXPOSE 80
CMD ["opentelemetry-instrument", "uvicorn", "app.frontend.main:app", "--host", "0.0.0.0", "--port", "80"]

# --- loadgen target ---
FROM base AS loadgen
CMD ["opentelemetry-instrument", "python", "-m", "app.loadgen.main"]
