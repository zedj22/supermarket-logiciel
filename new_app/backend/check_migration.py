"""Check the migration file for literal timestamps."""
import re

with open("migrations/versions/2026_09_22_1128_73355bdf31d4_0002_phase2_domain_models.py") as f:
    content = f.read()

# Find all server_default patterns
patterns = re.findall(r"server_default=[^,\)]+", content)
print("=== server_default patterns in migration ===")
for p in patterns:
    print(f"  {p}")

# Check for literal timestamps
literal_ts = [p for p in patterns if "2026" in p]
print(f"\nLiteral timestamps found: {len(literal_ts)}")
for p in literal_ts:
    print(f"  {p}")

# Check for now() 
now_patterns = [p for p in patterns if "now()" in p]
print(f"\nnow() patterns found: {len(now_patterns)}")
for p in now_patterns:
    print(f"  {p}")
