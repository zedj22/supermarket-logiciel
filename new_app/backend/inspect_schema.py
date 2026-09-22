"""PostgreSQL schema inspection script."""
import psycopg2
from app.core.config import settings

conn = psycopg2.connect(settings.DATABASE_URL)
cur = conn.cursor()

# List all tables
cur.execute("""
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name
""")
tables = [r[0] for r in cur.fetchall()]
print("=== ALL TABLES ===")
for t in tables:
    print(f"  {t}")
print(f"Total: {len(tables)}\n")

# Check timestamp defaults for all tables with datetime columns
print("=== TIMESTAMP DEFAULTS ===")
cur.execute("""
SELECT table_name, column_name, column_default, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type LIKE '%timestamp%'
  AND column_default IS NOT NULL
ORDER BY table_name, column_name
""")
for row in cur.fetchall():
    table, col, default, dtype = row
    is_dynamic = "now()" in str(default) or "CURRENT_TIMESTAMP" in str(default)
    status = "OK" if is_dynamic else "FIX NEEDED"
    print(f"  [{status}] {table}.{col} = {default}")

# Check ALL foreign keys
print("\n=== FOREIGN KEYS ===")
cur.execute("""
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table,
    ccu.column_name AS foreign_column,
    rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
    AND ccu.table_schema = tc.table_schema
JOIN information_schema.referential_constraints rc
    ON rc.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
    AND tc.table_schema = 'public'
ORDER BY tc.table_name, kcu.column_name
""")
fk_results = cur.fetchall()
print(f"Total FKs found: {len(fk_results)}\n")
for table, col, ftable, fcol, delete_rule in fk_results:
    print(f"  {table}.{col} -> {ftable}.{fcol} (ON DELETE {delete_rule})")

# Check inventory_movements specifically
print("\n=== INVENTORY_MOVEMENTS DETAILS ===")
cur.execute("""
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'inventory_movements'
ORDER BY ordinal_position
""")
for row in cur.fetchall():
    print(f"  {row[0]}: {row[1]} nullable={row[2]} default={row[3]}")

# Check tables missing FKs
print("\n=== TABLES WITHOUT FKs ===")
cur.execute("""
SELECT t.table_name
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints tc
    ON t.table_name = tc.table_name
    AND tc.constraint_type = 'FOREIGN KEY'
    AND tc.table_schema = 'public'
WHERE t.table_schema = 'public'
    AND t.table_type = 'BASE TABLE'
    AND tc.constraint_name IS NULL
ORDER BY t.table_name
""")
no_fk = [r[0] for r in cur.fetchall()]
for t in no_fk:
    print(f"  {t}")

cur.close()
conn.close()
