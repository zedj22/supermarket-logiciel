# KlickPOS License API — Google Cloud Run image.
#
# Build context is `new_app/` (the API imports the customer application's
# licensing contract read-only from `new_app/backend`; nothing there is copied
# into a client artifact or modified):
#
#   docker build -f new_app/license_manager/Dockerfile -t klickpos-license-api:local new_app
#
# Nothing secret is baked in: the signing seed and the activation-code key are
# read from Secret Manager at runtime, and there is no `.env`, no ADC file and
# no emulator configuration in the image.
#
# syntax=docker/dockerfile:1.7

# --- dependencies --------------------------------------------------------- #
FROM python:3.12-slim AS deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /install
# Runtime-only set: test tooling (pytest, httpx and friends) lives in
# `requirements.txt` and is deliberately not installed here.
COPY license_manager/requirements-runtime.txt ./requirements-runtime.txt
RUN pip install --no-cache-dir --prefix=/install/deps -r requirements-runtime.txt

# --- runtime -------------------------------------------------------------- #
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/license_manager:/app/backend \
    PORT=8080 \
    LICENSE_API_LOG_JSON=1

# Non-root: Cloud Run does not need root, and the process never writes to disk.
RUN groupadd --system --gid 10001 license \
    && useradd --system --uid 10001 --gid license --home-dir /app license

WORKDIR /app

COPY --from=deps /install/deps /usr/local

# The service never installs packages at runtime; dropping pip removes an
# unnecessary tool (and its vendor tree) from the production attack surface.
RUN python -m pip uninstall -y pip

# The shared licensing contract and the service itself. `bootstrap.py` resolves
# `new_app/backend` as `<service>/../../backend`, which is /app/backend here.
COPY backend/app ./backend/app
COPY backend/tools ./backend/tools
COPY license_manager/service ./license_manager/service
COPY license_manager/pyproject.toml ./license_manager/pyproject.toml

USER license

EXPOSE 8080

# Cloud Run's startup probe hits /healthz (it needs no credentials and touches
# no store). `--proxy-headers` is safe here: the only way into the container is
# Google's front end.
CMD ["sh", "-c", "exec uvicorn service.api:app \
      --host 0.0.0.0 \
      --port ${PORT:-8080} \
      --proxy-headers \
      --forwarded-allow-ips='*' \
      --timeout-graceful-shutdown 10 \
      --no-server-header"]
