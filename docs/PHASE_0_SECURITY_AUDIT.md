# Phase 0 — Security Audit

No secret value is reproduced here.

| Severity | Evidence | Risk / required remediation |
|---|---|---|
| Critical | `config/db_config.json` contains a database password | **SECRET PRESENT** at configuration path. Per-user OS credential storage or deployment secret injection; restrictive ACL; rotate existing credential. |
| High | license guard is commented in `main.py` | activation is bypassed. Re-design licensing server/offline entitlement separately; do not confuse with authorization. |
| High | `server/server.py` runs Flask debug and binds `0.0.0.0` | debugger/network exposure. Retire or run production FastAPI behind authenticated LAN policy; debug never enabled. |
| High | LAN clients use shared DB credentials/direct MySQL | broad database access, no request identity. Backend-only DB account; firewall PostgreSQL to server; short-lived API sessions/device enrollment. |
| Medium | `license.py` derives device ID with MD5 platform info | weak/spoofable identity. Use generated device keypair/UUID stored in OS-protected storage; SHA-256 only for non-secret fingerprints. |
| Medium | hardcoded `_SECRET_KEY` in MainWindow | predictable secret. Generate/store securely; rotate capability. |
| Medium | PIN roles / no visible rate lockout/session expiry | brute force and stale sessions. Argon2id password/PIN hashes, lockout/backoff, session expiry/revocation. |
| Medium | paths/images/backups/exports user file operations | traversal/data exposure. allowlist roots, canonicalize paths, access controls and audit. |
| Medium | HTTP LAN discovery/API lacks transport/auth hardening | sniff/replay/unauthorized device risk. Pairing with one-time code, device certificate/token, optional TLS/mTLS, signed enrollment. |

Keep parameterized SQL but validate identifiers (including database creation name), prohibit secrets in logs/backups, record login/export/void/device/restore attempts, use least-privilege DB roles, encrypted backups with integrity manifest, dependency scanning, and a security test suite. At-rest encryption is deployment/device policy; document it rather than claiming the app provides it.
