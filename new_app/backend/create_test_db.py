"""Create the dedicated test database."""
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
from app.core.config import settings

# Connect to default database to create test DB
conn = psycopg2.connect(settings.DATABASE_URL)
conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
cur = conn.cursor()

# Check if test DB exists
cur.execute("SELECT 1 FROM pg_database WHERE datname = 'supermarket_pro_test'")
exists = cur.fetchone()

if not exists:
    cur.execute("CREATE DATABASE supermarket_pro_test")
    print("Created supermarket_pro_test")
else:
    print("supermarket_pro_test already exists")

cur.close()
conn.close()
