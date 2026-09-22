# PHASE 0 — Security Audit

## Critical Issues

### 1. Plaintext Database Password
**File**: `config/db_config.json:4`
```json
"password": "Islem2002@"
```
- **Severity**: CRITICAL
- **Issue**: Database password stored in plaintext JSON file
- **Risk**: Any user with file access can read the password
- **Recommendation**: Encrypt with OS keychain or encrypted config with master key

### 2. License Check Disabled
**File**: `main.py:17-19`
```python
# if not license_manager.check_license():
#     print("❌ البرنامج غير مفعل...")
#     sys.exit(1)
```
- **Severity**: HIGH
- **Issue**: License verification is commented out
- **Risk**: Software can be used without activation
- **Recommendation**: Implement proper licensing in new system

### 3. MD5 Device ID Hashing
**File**: `security/license.py:19`
```python
hashlib.md5(platform_info.encode()).hexdigest()
```
- **Severity**: MEDIUM
- **Issue**: MD5 is cryptographically broken
- **Risk**: Device ID can be spoofed
- **Recommendation**: Use SHA-256 or better for device identification

### 4. Flask Debug Mode Enabled
**File**: `server/server.py:94`
```python
app.run(host="0.0.0.0", port=5000, debug=True)
```
- **Severity**: HIGH
- **Issue**: Flask debug mode exposes interactive debugger
- **Risk**: Remote code execution if server is network-accessible
- **Recommendation**: Never enable debug mode in production

### 5. Hardcoded Secret Key
**File**: `main_window.py:15` (in MainWindow class)
```python
self._SECRET_KEY = "supermarket_pro_secret_key_2024"
```
- **Severity**: MEDIUM
- **Issue**: Hardcoded secret key in source code
- **Risk**: Session/PII data can be decrypted
- **Recommendation**: Generate random key at first run, store securely

### 6. Database Port Exposure
**File**: `config/db_config.json:3`
```json
"port": 3306
```
- **Severity**: MEDIUM
- **Issue**: Default MySQL port may be exposed on network
- **Risk**: Direct database access from network
- **Recommendation**: Use firewall rules, consider non-standard port

## Medium Issues

### 7. No HTTPS for Server Communication
- Flask server runs on HTTP
- No TLS/SSL configuration
- All data transmitted in plaintext on LAN
- **Recommendation**: Add optional TLS for LAN communication

### 8. No Rate Limiting
- No authentication rate limiting
- No API rate limiting
- Brute force attacks possible on PIN codes
- **Recommendation**: Implement rate limiting on auth endpoints

### 9. No Input Sanitization in SQL
- Parameterized queries used (good)
- But some string interpolation in SQL (e.g., database name in `CREATE DATABASE`)
- **Recommendation**: Validate all inputs before use

### 10. Weak PIN Policy
- PINs are 4-6 digits
- No complexity requirements
- No lockout after failed attempts
- **Recommendation**: Add lockout, attempt tracking

### 11. No Audit Trail for Sensitive Operations
- Login attempts not logged
- Failed PIN attempts not logged
- Data export not logged
- **Recommendation**: Add comprehensive audit logging

## Low Issues

### 12. File Permissions
- Config files may have overly permissive access
- No file permission checks
- **Recommendation**: Check and set appropriate permissions

### 13. Image Path Traversal
- Product images stored as file paths
- No path validation
- **Recommendation**: Validate and restrict image paths

### 14. No Data Encryption at Rest
- Database data not encrypted
- Config files not encrypted
- **Recommendation**: Consider full-disk encryption for sensitive data

## Recommendations Summary

| Priority | Action | Impact |
|----------|--------|--------|
| CRITICAL | Encrypt database passwords | Prevent credential theft |
| CRITICAL | Enable license verification | Protect intellectual property |
| HIGH | Disable Flask debug mode | Prevent remote code execution |
| HIGH | Implement TLS for LAN | Protect data in transit |
| MEDIUM | Replace MD5 with SHA-256 | Stronger device identification |
| MEDIUM | Generate secure secret key | Protect session data |
| MEDIUM | Add rate limiting | Prevent brute force |
| MEDIUM | Add PIN lockout | Prevent PIN guessing |
| LOW | Add audit logging | Enable forensics |
| LOW | Restrict file permissions | Reduce attack surface |
