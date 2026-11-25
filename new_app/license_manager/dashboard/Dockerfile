# KlickPOS License Dashboard — Google Cloud Run image.
#
# Build context is `new_app/license_manager/` (the parent of `dashboard/`), so
# that `license_manager/.dockerignore` applies:
#
#   docker build -f license_manager/dashboard/Dockerfile \
#     -t klickpos-license-dashboard:local license_manager
#
# `next.config.ts` sets `output: "standalone"`, so the runtime image carries only
# the traced server bundle and the static assets — no node_modules tree, no
# source, no `.env` and no secrets.
#
# Public Firebase values are compiled in at build time (see the ARG block
# below); the API proxy target is NOT baked in: it is read at runtime from the
# server-only `LICENSE_API_BASE_URL`, so this image is environment-agnostic.
#
# Two rules keep this build correct (Phase 6.8.1):
#
# 1. the context never contains the host's `node_modules`/`.next` — `npm ci` and
#    `next build` run inside the image, so host copies are wasted bytes;
# 2. the source is copied **path by path**, never as `COPY dashboard/ ./`. A
#    whole-directory copy writes into `/app` on top of the `node_modules` that
#    came from the deps stage; BuildKit then has to apply metadata (chmod) to
#    files owned by an immutable lower layer and fails with
#    "read-only file system".
#
# syntax=docker/dockerfile:1.7

# --- dependencies: lockfile only, so this layer caches on manifest changes --- #
FROM node:22-alpine AS deps
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY dashboard/package.json dashboard/package-lock.json ./
RUN npm ci --no-audit --no-fund

# --- build ------------------------------------------------------------------ #
FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

# Dependencies first (from the deps stage), then source — and only the paths the
# build actually reads. Tests and their tooling stay out of the image.
COPY --from=deps /app/node_modules ./node_modules
COPY dashboard/package.json dashboard/package-lock.json ./
COPY dashboard/next.config.ts dashboard/tsconfig.json dashboard/next-env.d.ts ./
COPY dashboard/postcss.config.mjs dashboard/tailwind.config.ts dashboard/eslint.config.mjs ./
COPY dashboard/app ./app
COPY dashboard/components ./components
COPY dashboard/lib ./lib
# `prebuild` (scripts/public-build-env.mjs) refuses to build an image whose
# public Firebase configuration is incomplete, so the script must be here.
COPY dashboard/scripts ./scripts

# --- public Firebase web configuration (Phase 8.3.2) ----------------------- #
# Next.js inlines every NEXT_PUBLIC_* value at build time, so these must be
# present HERE, not only at `docker run`. Without them the image would ship an
# empty Firebase config and the login page would report "Not configured";
# `next.config.ts` fails the build instead of producing such an image.
#
# These are PUBLIC by design (a Firebase Web App config is not a secret). Never
# add a signing seed, AES key, service-account JSON or any server-only value as
# a build argument: build args are recorded in the image history.
#
#   docker build -f license_manager/dashboard/Dockerfile \
#     --build-arg NEXT_PUBLIC_FIREBASE_PROJECT_ID=<project-id> … \
#     -t klickpos-license-dashboard:local license_manager
#
# APPCHECK_SITE_KEY may stay empty until App Check is registered for the
# deployment's hostname. The two development switches must stay empty.
ARG NEXT_PUBLIC_FIREBASE_API_KEY
ARG NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN
ARG NEXT_PUBLIC_FIREBASE_PROJECT_ID
ARG NEXT_PUBLIC_FIREBASE_APP_ID
ARG NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID
ARG NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET
ARG NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY
ARG NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN
ARG NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST
# Build-time compatibility fallback only (Phase 6 Cloud Run). New deployments
# use the server-only LICENSE_API_BASE_URL at runtime instead, so one image can
# serve several environments.
ARG NEXT_PUBLIC_API_BASE_URL

ENV NEXT_PUBLIC_FIREBASE_API_KEY=$NEXT_PUBLIC_FIREBASE_API_KEY \
    NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=$NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN \
    NEXT_PUBLIC_FIREBASE_PROJECT_ID=$NEXT_PUBLIC_FIREBASE_PROJECT_ID \
    NEXT_PUBLIC_FIREBASE_APP_ID=$NEXT_PUBLIC_FIREBASE_APP_ID \
    NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=$NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID \
    NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=$NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET \
    NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY=$NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY \
    NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN=$NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN \
    NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST=$NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST \
    NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL

RUN npm run build

# --- runtime: standalone output only ---------------------------------------- #
FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080 \
    HOSTNAME=0.0.0.0

# Pick up the security patches published for Alpine 3.24 after this base
# image was built (Phase 6.9): zlib 1.3.2-r1 -> 1.4-r0, which is the only fix
# for CVE-2026-4738, and openssl 3.5.9-r0 -> 3.5.9-r1. The base image stays
# `node:22-alpine` (maintained, smallest supported Next.js standalone target);
# only the outdated OS packages inside it are upgraded.
RUN apk upgrade --no-cache && rm -rf /var/cache/apk/*

# The standalone server only needs `node`. npm / npx / corepack / yarn are build
# tools, never used past this point, and their bundled dependency tree
# (`/usr/local/lib/node_modules/npm`, ~17 MB) carries most of the remaining
# HIGH findings in this image. Removing them is not suppression: the vulnerable
# code is no longer present.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx \
              /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg

# Non-root: the Next server never writes to disk in this layout.
RUN addgroup -S --gid 10001 nextjs && adduser -S -u 10001 -G nextjs nextjs

# `standalone` contains server.js plus the traced node_modules subset.
COPY --from=build --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nextjs /app/.next/static ./.next/static

USER nextjs
EXPOSE 8080

# Next's standalone server binds HOSTNAME/PORT (Cloud Run injects PORT) and
# shuts down cleanly on SIGTERM.
CMD ["node", "server.js"]
