# modules/favorites.py
"""Hybrid product favorites: automatic (top sellers over a rolling window)
plus manual (owner-pinned via the star icon). Manual favorites always take
precedence and are never removed by the automatic recalculation."""

from database.db_manager import DatabaseManager

# Defaults (overridable by the caller; setting defaults also live in main_window).
AUTO_FAVORITE_LIMIT = 10      # top-N auto favorites computed from sales
ROLLING_WINDOW_DAYS = 30      # rolling window for "best sellers" (last N days)
DISPLAY_FAVORITE_CAP = 15     # max favorite cards shown in the POS top row


class FavoritesManager:
    def __init__(self):
        self.db = DatabaseManager()
        self.ensure_table()

    def ensure_table(self):
        """Idempotent creation — used by existing installs whose schema was
        created before product_favorites existed."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute('''CREATE TABLE IF NOT EXISTS product_favorites (
                id INT PRIMARY KEY AUTO_INCREMENT,
                product_id INT NOT NULL,
                is_manual TINYINT DEFAULT 0,
                added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                UNIQUE KEY (product_id),
                FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')
            conn.commit()
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # basic CRUD
    # ------------------------------------------------------------------
    def is_favorite(self, product_id):
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT is_manual FROM product_favorites WHERE product_id = ?",
                (product_id,),
            )
            row = cur.fetchone()
            return bool(row) and bool(int(row[0]))
        finally:
            conn.close()

    def is_pinned(self, product_id):
        """True if the product is a MANUAL favorite (owner-pinned)."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT is_manual FROM product_favorites WHERE product_id = ?",
                (product_id,),
            )
            row = cur.fetchone()
            return bool(row) and bool(int(row[0]))
        finally:
            conn.close()

    def pinned_ids(self):
        """Set of product_ids manually pinned — one query, avoids N+1."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT product_id FROM product_favorites WHERE is_manual = 1"
            )
            return set(int(r[0]) for r in cur.fetchall())
        finally:
            conn.close()

    def set_manual(self, product_id, manual):
        """Manually favorite (pin) or un-favorite a product. Manual override
        always wins: setting manual=True keeps it until explicitly removed."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO product_favorites (product_id, is_manual) VALUES (?, ?) "
                "ON DUPLICATE KEY UPDATE is_manual = ?",
                (product_id, 1 if manual else 0, 1 if manual else 0),
            )
            conn.commit()
        finally:
            conn.close()

    def get_all_favorites(self):
        """All favorite rows: (id, product_id, is_manual, added_at),
        manual first, then by added_at."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT id, product_id, is_manual, added_at FROM product_favorites "
                "ORDER BY is_manual DESC, added_at"
            )
            return cur.fetchall()
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # automatic top-N from real sales history
    # ------------------------------------------------------------------
    def top_product_ids_by_sales(self, limit=AUTO_FAVORITE_LIMIT, days=ROLLING_WINDOW_DAYS):
        """product_ids ranked by units sold over the rolling window. Only real
        product sales count (pack summary rows have NULL product_id and are
        excluded by the JOIN); each pack component counts as its own product."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT si.product_id, SUM(si.quantity) AS units
                FROM sale_items si
                JOIN products p ON p.id = si.product_id
                JOIN sales s ON s.id = si.sale_id
                WHERE si.product_id IS NOT NULL
                  AND s.sale_date >= DATE_SUB(NOW(), INTERVAL ? DAY)
                GROUP BY si.product_id
                ORDER BY units DESC, si.product_id ASC
                LIMIT ?
                """,
                (days, limit),
            )
            return [row[0] for row in cur.fetchall()]
        finally:
            conn.close()

    def refresh_auto_favorites(self, limit=AUTO_FAVORITE_LIMIT, days=ROLLING_WINDOW_DAYS):
        """Recompute the AUTOMATIC favorites to match the current top sellers,
        without touching manual (owner-pinned) favorites.

        - Auto rows that dropped out of the top-N are removed.
        - Top sellers not yet favorited are added as is_manual=0.
        - Manual rows (is_manual=1) are never removed or demoted here.
        """
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            top_ids = self.top_product_ids_by_sales(limit, days)
            top_set = set(top_ids)

            # Existing rows, split by manual/auto.
            cur.execute(
                "SELECT product_id, is_manual FROM product_favorites"
            )
            existing = cur.fetchall()
            for pid, is_manual in existing:
                pid = int(pid)
                if int(is_manual):
                    continue  # manual favorites are untouchable
                if pid not in top_set:
                    cur.execute(
                        "DELETE FROM product_favorites WHERE product_id = ? AND is_manual = 0",
                        (pid,),
                    )

            # Add top sellers that are not currently favorited (manual or auto).
            existing_set = set(int(r[0]) for r in existing)
            for pid in top_ids:
                if pid not in existing_set:
                    cur.execute(
                        "INSERT INTO product_favorites (product_id, is_manual) VALUES (?, 0)",
                        (pid,),
                    )
            conn.commit()
        finally:
            conn.close()

    def clear_auto_favorites(self):
        """Remove only automatic favorites (test/cleanup helper)."""
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute("DELETE FROM product_favorites WHERE is_manual = 0")
            conn.commit()
        finally:
            conn.close()

    def clear_all(self):
        conn = self.db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute("DELETE FROM product_favorites")
            conn.commit()
        finally:
            conn.close()
