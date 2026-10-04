"""Application constants.

Centralized constants that do not change at runtime.
"""

APP_VERSION = "0.1.0"

# Database
MAX_VARCHAR_LENGTH = 255
BARCODE_MAX_LENGTH = 64
INVOICE_NUMBER_MAX_LENGTH = 64
DEVICE_NAME_MAX_LENGTH = 100

# Pagination defaults
DEFAULT_PAGE_SIZE = 40
MAX_PAGE_SIZE = 100

# POS sale / cart lines
# Maximum DISTINCT sale lines in ONE sale, cart-validate request or hold
# snapshot.  This counts cart lines, never quantity: 500 x Product A plus
# 700 x Product B is 2 lines; 10 000 different products x qty 1 is
# 10 000 lines.  The sale itself stays ONE atomic transaction.
# Applied by app/schemas/sale.py (CreateSaleRequest, CartValidateRequest,
# HoldCreateRequest) — sale/cart lines only, no other contract uses it.
MAX_SALE_LINES = 10_000

# Money precision (PostgreSQL NUMERIC)
MONEY_PRECISION = 18
MONEY_SCALE = 3

# PIN constraints
PIN_MIN_LENGTH = 4
PIN_MAX_LENGTH = 6

# Auth / Security
ARGON2_TIME_COST = 3
ARGON2_MEMORY_COST = 65536  # 64 MB
ARGON2_PARALLELISM = 4
ARGON2_HASH_LENGTH = 32
ARGON2_SALT_LENGTH = 16
