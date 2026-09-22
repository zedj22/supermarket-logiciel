# database/db_manager.py
# طبقة قاعدة البيانات — MySQL/MariaDB عبر pymysql مع طبقة توافق تحوّل
# استعلامات SQLite تلقائيًا (? placeholders، PRAGMA، AUTOINCREMENT...)
# حتى تبقى بقية ملفات المشروع كما هي دون تعديل كل استعلام يدويًا.

import json
import os
import re
import sqlite3  # يُستخدم لإعادة رفع نفس أنواع الاستثناءات التي تعتدها الوحدات الحالية
import threading
from collections import deque

try:
    import pymysql
    import pymysql.err
except ImportError:  # يسمح للتطبيق بالعمل حتى قبل تثبيت المكتبة، مع رسالة واضحة عند أول اتصال
    pymysql = None


DEFAULT_DB_CONFIG = {
    "host": "localhost",
    "port": 3306,
    "user": "root",
    "password": "",
    "database": "supermarket_pro",
    # None = لم يُختر بعد (يعرض معالج الإعداد الأول) | local = جهاز واحد
    # server = الجهاز الرئيسي | client = جهاز إضافي يتصل بالرئيسي
    "network_mode": None,
    # store_linked = true إذا تم ربط هذا العميل بخادم بنجاح سابقاً
    # يستخدم لإخفاء مربع التأكيد في التشغيلات اللاحقة
    "store_linked": False,
    # local_ip = عنوان IP لهذا الجهاز إن حُدد يدويًا في الإعدادات؛
    # عندما يكون None/فارغًا نستنتجه تلقائيًا عبر get_local_ip() عند الاستخدام.
    "local_ip": None,
}


def project_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def db_config_path():
    return os.path.join(project_root(), "config", "db_config.json")


def load_db_config():
    """قراءة إعدادات الاتصال.

    لا نكتب الملف تلقائيًا عند غيابه: على جهاز جديد بدون إعدادات يبقى
    network_mode غير محدد (None) حتى يختار المستخدم دور الجهاز في معالج
    الإعداد الأول. أي مُهمة تريد الحفظ تستدعي save_db_config صراحةً.
    """
    cfg = dict(DEFAULT_DB_CONFIG)
    path = db_config_path()
    if os.path.exists(path):
        try:
            # utf-8-sig لتحمّل ملفات محرّرة من المفكرة وتحتوي BOM
            with open(path, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
            if isinstance(data, dict):
                cfg.update({k: v for k, v in data.items() if k in DEFAULT_DB_CONFIG})
        except Exception:
            pass
    return cfg


def save_db_config(cfg):
    path = db_config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    merged = dict(DEFAULT_DB_CONFIG)
    merged.update({k: v for k, v in (cfg or {}).items() if k in DEFAULT_DB_CONFIG})
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=2)
        return True
    except Exception:
        return False


# -----------------------------------------------------
# إعداد نشِط مشترك: كل نسخ DatabaseManager تشير لنفس القاموس،
# فتنتشر تغييرات وضع الشبكة/الخادم فورًا دون إعادة تشغيل.
# -----------------------------------------------------

_ACTIVE_CONFIG = None


def get_active_config():
    global _ACTIVE_CONFIG
    if _ACTIVE_CONFIG is None:
        _ACTIVE_CONFIG = load_db_config()
    return _ACTIVE_CONFIG


def set_active_config(cfg):
    """تحديث الإعداد المشترك وحفظه على القرص في نفس الوقت."""
    global _ACTIVE_CONFIG
    active = get_active_config()
    active.clear()
    active.update({k: v for k, v in dict(cfg).items() if k in DEFAULT_DB_CONFIG})
    save_db_config(active)
    return active


def test_connection(cfg=None, create_database=True):
    """اختبار الاتصال بالخادم. يعيد (True, رسالة نجاح) أو (False, رسالة الخطأ)."""
    if pymysql is None:
        return False, "مكتبة pymysql غير مثبتة: python -m pip install pymysql cryptography"
    cfg = cfg or load_db_config()
    host = str(cfg.get("host") or "localhost")
    port = int(cfg.get("port") or 3306)
    user = str(cfg.get("user") or "root")
    password = str(cfg.get("password") or "")
    database = str(cfg.get("database") or "supermarket_pro")

    server_conn = None
    try:
        server_conn = pymysql.connect(
            host=host, port=port, user=user, password=password,
            charset="utf8mb4", connect_timeout=6,
        )
        with server_conn.cursor() as cur:
            cur.execute("SELECT 1")
        if database and create_database:
            with server_conn.cursor() as cur:
                cur.execute(
                    "CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                    % database.replace("`", "")
                )
        server_conn.close()
        return True, "OK"
    except Exception as exc:
        try:
            if server_conn:
                server_conn.close()
        except Exception:
            pass
        return False, str(exc)


# =========================================================
# طبقة توافق SQL: تحويل صيغة SQLite إلى MySQL
# =========================================================

_RE_AUTOINCREMENT = re.compile(r"\bINTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT\b", re.I)
_RE_COLLATE_NOCASE = re.compile(r"\s+COLLATE\s+NOCASE\b", re.I)
_RE_TEXT_DEFAULT_EMPTY = re.compile(r"\bTEXT\s+DEFAULT\s+''(?![0-9a-zA-Z_'])", re.I)
_RE_INSERT_OR_IGNORE = re.compile(r"\bINSERT\s+OR\s+IGNORE\s+INTO\b", re.I)
_RE_PRAGMA = re.compile(r"PRAGMA\s+table_info\(\s*([^)]*?)\s*\)", re.I)
_RE_CREATE_INDEX_IF_NOT = re.compile(
    r"^\s*CREATE\s+(UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+`?([\w]+)`?\s+ON\s+`?([\w]+)`?\s*\((.+)\)\s*;?\s*$",
    re.I | re.S,
)


def translate_sql(sql):
    """تحويل عبارات SQL من صيغة SQLite إلى ما يدعمه MySQL/MariaDB.

    - ? -> %s خارج النصوص المقتبسة فقط
    - INTEGER PRIMARY KEY AUTOINCREMENT -> INT PRIMARY KEY AUTO_INCREMENT
    - COLLATE NOCASE -> حذف (الترتيب الافتراضي في MySQL غير حساس لحالة الأحرف)
    - TEXT DEFAULT '' -> TEXT NULL (للتوافق مع الإصدارات الأقدم)
    - INSERT OR IGNORE INTO -> INSERT IGNORE INTO (لتجاهل تعارض المفاتيح عند البذر)
    - PRAGMA table_info(t) -> استعلام INFORMATION_SCHEMA بنفس شكل الصفوف
    """
    if sql is None or not isinstance(sql, str):
        return sql

    def pragma_repl(m):
        table = m.group(1).strip().strip("'\"").replace("'", "''")
        return (
            "SELECT ORDINAL_POSITION AS cid, COLUMN_NAME AS name, COLUMN_TYPE AS type, "
            "CASE WHEN IS_NULLABLE = 'YES' THEN 0 ELSE 1 END AS notnull, "
            "COLUMN_DEFAULT AS dflt_value, "
            "(CASE WHEN COLUMN_KEY = 'PRI' THEN 1 ELSE 0 END) AS pk "
            "FROM INFORMATION_SCHEMA.COLUMNS "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '" + table + "' "
            "ORDER BY ORDINAL_POSITION"
        )

    sql = _RE_PRAGMA.sub(pragma_repl, sql)
    sql = _RE_AUTOINCREMENT.sub("INT PRIMARY KEY AUTO_INCREMENT", sql)
    sql = _RE_COLLATE_NOCASE.sub("", sql)
    sql = _RE_TEXT_DEFAULT_EMPTY.sub("TEXT NULL", sql)
    sql = _RE_INSERT_OR_IGNORE.sub("INSERT IGNORE INTO", sql)

    # تحويل العلامات ? إلى %s مع تجاهل ما داخل النصوص المقتبسة.
    out = []
    i, n = 0, len(sql)
    quote = None
    while i < n:
        ch = sql[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == "'" and i + 1 < n:
                out.append(sql[i + 1])
                i += 2
                continue
            if ch == quote:
                if i + 1 < n and sql[i + 1] == quote:  # '' هروب داخل النص
                    out.append(sql[i + 1])
                    i += 1
                else:
                    quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "?":
            out.append("%s")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


class _CompatCursor:
    """مؤشر يحاكي sqlite3.Cursor فوق مؤشر pymysql."""

    def __init__(self, raw_cursor):
        self._cur = raw_cursor

    def _prepare_args(self, args):
        if args is None:
            return None
        if isinstance(args, (list, tuple)) and len(args) == 0:
            return None  # تجنّب تفسير % داخل نص الاستعلام عندما لا توجد وسائط
        if isinstance(args, dict):
            return args
        return tuple(args)

    def execute(self, sql, args=None):
        translated = translate_sql(sql)
        m = _RE_CREATE_INDEX_IF_NOT.match(translated or "")
        if m:
            unique, name, table, cols = m.group(1) or "", m.group(2), m.group(3), m.group(4).rstrip().rstrip(";")
            self._cur.execute(
                "SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS "
                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND INDEX_NAME = %s",
                (table, name),
            )
            if (self._cur.fetchone() or [0])[0]:
                return self
            translated = f"CREATE {unique}INDEX `{name}` ON `{table}` ({cols})"
        try:
            self._cur.execute(translated, self._prepare_args(args))
        except pymysql.err.IntegrityError as exc:
            raise sqlite3.IntegrityError(str(exc))
        except pymysql.err.OperationalError as exc:
            raise sqlite3.OperationalError(str(exc))
        except pymysql.err.ProgrammingError as exc:
            raise sqlite3.ProgrammingError(str(exc))
        return self

    def executemany(self, sql, seq_of_args):
        try:
            self._cur.executemany(translate_sql(sql), list(seq_of_args or []))
        except pymysql.err.IntegrityError as exc:
            raise sqlite3.IntegrityError(str(exc))
        return self

    def fetchone(self):
        return self._cur.fetchone()

    def fetchmany(self, size=None):
        return self._cur.fetchmany(size) if size else self._cur.fetchmany()

    def fetchall(self):
        return self._cur.fetchall()

    def close(self):
        try:
            self._cur.close()
        except Exception:
            pass

    @property
    def lastrowid(self):
        return getattr(self._cur, "lastrowid", None)

    @property
    def rowcount(self):
        return getattr(self._cur, "rowcount", -1)

    @property
    def description(self):
        return getattr(self._cur, "description", None)

    def __iter__(self):
        return iter(self._cur)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class _ConnectionPool:
    """تجمع صغير لاتصالات pymysql الحيّة، مفاتيحه حسب إعداد الاتصال.

    get_connection() يلتقط اتصالًا جاهزًا، ويُعاد للربح (لا يُغلق فعلًا) عند
    close() — فيختفي ثمن فتح اتصال جديد (~20 مللي ثانية) من كل عملية.
    قبل إعادته للربح تُلفلف أي معاملة معلّقة (rollback) حتى لا تتسرب حالة
    قديمة لأي مستخدم لاحق ولا تتراكم إطلالات قديمة في InnoDB.
    الآمن للخيوط: يُعطى كل اتصال لمستخدم واحد في اللحظة (acquire حصري).
    """

    def __init__(self, max_idle=8):
        self.max_idle = max_idle
        self._buckets = {}   # fingerprint -> deque[raw]
        self._lock = threading.Lock()

    @staticmethod
    def fingerprint(cfg):
        return (
            str(cfg.get("host") or "localhost"),
            int(cfg.get("port") or 3306),
            str(cfg.get("user") or "root"),
            str(cfg.get("database") or "supermarket_pro"),
        )

    def acquire(self, cfg, connect):
        fp = self.fingerprint(cfg)
        with self._lock:
            dq = self._buckets.get(fp)
            while dq:
                raw = dq.popleft()
                try:
                    # ping(reconnect=False): لا نعيد الاتصال تلقائيًا هنا لأن إعادة
                    # الاتصال عبر ping قد لا تحترم connect_timeout وتعلّق الخيط عند
                    # فشل الشبكة. إن كان الاتصال ماثيّتًا نسقطه ونفتح واحدًا جديدًا
                    # عبر connect() الذي يفرض connect_timeout قصيرًا — فيبقى
                    # فشل الوصول إلى خادم غير متاح سريعًا ومحدودًا ولا يحمّل واجهة المستخدم.
                    raw.ping(reconnect=False)
                    return raw
                except Exception:
                    try:
                        raw.close()
                    except Exception:
                        pass
        # لا اتصال جاهز او كل المرمّزات ميّتة — افتح اتصالًا جديدًا (مقيّد المهلة)
        return connect()

    def release(self, raw, fp):
        # أي معاملة معلّقة تُسقط قبل الرجوع، فلا تتسرّب لعملية لاحقة.
        try:
            raw.rollback()
        except Exception:
            pass
        try:
            alive = bool(getattr(raw, "open", False))
        except Exception:
            alive = False
        if not alive:
            try:
                raw.close()
            except Exception:
                pass
            return
        with self._lock:
            dq = self._buckets.setdefault(fp, deque())
            if len(dq) < self.max_idle:
                dq.append(raw)
                return
        try:
            raw.close()
        except Exception:
            pass


# مجمّع اتصالات واحد مشترك بين كل نسخ DatabaseManager (نفس ذاكرة get_active_config).
_DB_POOL = _ConnectionPool()

# تُضاف الفهارس مرة واحدة فقط لكل عملية (لا تتكرر مع كل نسخة DatabaseManager).
_INDEXES_ENSURED = False


class CompatConnection:
    """اتصال يحاكي sqlite3.Connection: execute() مباشرة + commit/rollback/close."""

    def __init__(self, raw_connection, release_cb=None):
        self._raw = raw_connection
        self._release_cb = release_cb

    def cursor(self):
        return _CompatCursor(self._raw.cursor())

    def execute(self, sql, args=()):
        statement = translate_sql(sql)
        if statement is not None and statement.strip().upper() == "BEGIN":
            # pymysql يدير المعاملات تلقائيًا (autocommit=False)؛ نتجاهل BEGIN اليدوي.
            return self.cursor()

        m = _RE_CREATE_INDEX_IF_NOT.match(statement or "")
        if m:
            cur = self.cursor()
            return cur.execute(sql, args)

        cur = self.cursor()
        cur.execute(sql, args)
        return cur

    def commit(self):
        self._raw.commit()

    def rollback(self):
        self._raw.rollback()

    def close(self):
        if self._release_cb is not None:
            cb, self._release_cb = self._release_cb, None
            try:
                cb(self._raw)
                return
            except Exception:
                pass
        try:
            self._raw.close()
        except Exception:
            pass

    @property
    def total_changes(self):
        return 0


class DatabaseManager:
    def __init__(self, config=None):
        # بلا config صريح: نشير للإعداد المشترك الحيّ (ينتشر تغييره على كل المدراء).
        self.config = config if config is not None else get_active_config()
        # يُحفظ المسار القديم لأغراض أداة الترحيل من SQLite فقط.
        self.db_path = os.path.join(project_root(), "data", "supermarket.db")

        mode = str(self.config.get("network_mode") or "").strip().lower()
        self.mode = mode if mode in ("server", "client", "local") else None

        # إذا كان هذا العميل قد سبق ربطه بخادم (store_linked = true)،
        # نسمح للتدفق الطبيعي بالاستمرار مع فحص الاتصال.
        # وإذا كان store_linked = false (أو الإعداد缺失 للمرة الأولى)،
        # فسيتم التعامل معه في الواجهة الرئيسية عبر مربع التأكيد.
        self.store_linked = str(self.config.get("store_linked") or "").strip().lower() == "true"

        # لا يُسمح لفشل الشبكة/الخادم بإسقاط بدء التشغيل؛
        # مؤشر حالة الاتصال في الواجهة يعرض المشكلة للمستخدم.
        # وعندما لم يُختر وضع الشبكة بعد (None) لا نلمس قاعدة البيانات إطلاقًا:
        # معالج الإعداد الأول يتكفّل باختيار الدور قبل أي اتصال.
        if self.mode is None:
            return
        try:
            self.ensure_server_and_database()
            self.create_tables()
        except Exception as exc:
            print(f"⚠ تعذر تجهيز قاعدة البيانات الآن: {exc}")

    # -----------------------------------------------------
    # الاتصال
    # -----------------------------------------------------

    def _connect_server(self, with_database=False):
        if pymysql is None:
            raise RuntimeError(
                "مكتبة pymysql غير مثبتة. ثبّتها بأمر:\npython -m pip install pymysql cryptography"
            )
        kwargs = dict(
            host=str(self.config.get("host") or "localhost"),
            port=int(self.config.get("port") or 3306),
            user=str(self.config.get("user") or "root"),
            password=str(self.config.get("password") or ""),
            charset="utf8mb4",
            autocommit=False,
            # مهلة اتصال قصيرة حتى لا يعلّق التعامل مع خادم غير متاح (تغيير IP)
            # أيَّ خيط لفترة طويلة، خاصة إن صادف أن جرى على خيط الواجهة.
            connect_timeout=5,
        )
        if with_database:
            kwargs["database"] = str(self.config.get("database") or "supermarket_pro")
        return pymysql.connect(**kwargs)

    def ensure_server_and_database(self):
        """إنشاء قاعدة البيانات نفسها إن لم تكن موجودة (لا يؤثر إن كانت جاهزة)."""
        database = str(self.config.get("database") or "supermarket_pro").replace("`", "")
        conn = None
        try:
            conn = self._connect_server(with_database=False)
            with conn.cursor() as cur:
                cur.execute(
                    f"CREATE DATABASE IF NOT EXISTS `{database}` "
                    "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                )
            conn.commit()
        except Exception as exc:
            raise RuntimeError(f"تعذر الاتصال بخادم MySQL: {exc}")
        finally:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass

    def get_connection(self):
        """يعيد اتصالاً متوافقًا مع واجهة sqlite3 المستخدمة في كل المشروع.

        يستخدم مجمّع اتصالات مشتركًا: يُعاد الاتصال الفعلي للربح عند close()
        بدلًا من إغلاقه وفتحه من الصفر في كل مرة (يوفّر ~20 مللي ثانية لكل عملية).
        """
        cfg = dict(self.config)
        fp = _ConnectionPool.fingerprint(cfg)
        raw = _DB_POOL.acquire(cfg, lambda: self._connect_server(with_database=True))
        return CompatConnection(raw, release_cb=lambda r, _fp=fp: _DB_POOL.release(r, _fp))

    # -----------------------------------------------------
    # المخطط الأساسي
    # -----------------------------------------------------

    def create_tables(self):
        conn = self.get_connection()
        cursor = conn.cursor()

        # جدول المنتجات
        cursor.execute('''CREATE TABLE IF NOT EXISTS products (
            id INT PRIMARY KEY AUTO_INCREMENT,
            barcode VARCHAR(64) UNIQUE,
            name VARCHAR(255) NOT NULL,
            price DOUBLE NOT NULL,
            cost DOUBLE,
            quantity DOUBLE DEFAULT 0,
            unit VARCHAR(32) DEFAULT 'قطعة',
            expiry_date VARCHAR(32),
            image_path TEXT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول الزبائن — يجب إنشاؤه قبل sales لأن المفاتيح الأجنبية تُفحص فورًا في MySQL
        cursor.execute('''CREATE TABLE IF NOT EXISTS customers (
            id INT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(255) NOT NULL,
            phone VARCHAR(64),
            address TEXT NULL,
            balance DOUBLE DEFAULT 0,
            debt_ceiling DOUBLE DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول المبيعات
        cursor.execute('''CREATE TABLE IF NOT EXISTS sales (
            id INT PRIMARY KEY AUTO_INCREMENT,
            invoice_number VARCHAR(64) UNIQUE,
            customer_id INT,
            total DOUBLE,
            discount DOUBLE DEFAULT 0,
            paid_amount DOUBLE,
            change_amount DOUBLE,
            sale_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            device_name VARCHAR(100) DEFAULT 'PC1',
            status VARCHAR(20) DEFAULT 'completed',
            FOREIGN KEY (customer_id) REFERENCES customers(id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول تفاصيل المبيعات
        cursor.execute('''CREATE TABLE IF NOT EXISTS sale_items (
            id INT PRIMARY KEY AUTO_INCREMENT,
            sale_id INT,
            product_id INT,
            variant_id INT NULL,
            quantity DOUBLE,
            price DOUBLE,
            total DOUBLE,
            FOREIGN KEY (sale_id) REFERENCES sales(id),
            FOREIGN KEY (product_id) REFERENCES products(id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول متغيرات المنتج (المقاس / اللون) مع مخزون وباركود لكل متغير
        cursor.execute('''CREATE TABLE IF NOT EXISTS product_variants (
            id INT PRIMARY KEY AUTO_INCREMENT,
            product_id INT NOT NULL,
            variant_name VARCHAR(100) NOT NULL,
            barcode VARCHAR(64) UNIQUE,
            quantity DOUBLE DEFAULT 0,
            price DOUBLE NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول الترخيص
        cursor.execute('''CREATE TABLE IF NOT EXISTS license (
            id INT PRIMARY KEY AUTO_INCREMENT,
            serial_number VARCHAR(128) UNIQUE,
            device_id VARCHAR(128),
            activated_date VARCHAR(32),
            expiry_date VARCHAR(32),
            is_active INT DEFAULT 0
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول الأجهزة المتصلة
        cursor.execute('''CREATE TABLE IF NOT EXISTS connected_devices (
            id INT PRIMARY KEY AUTO_INCREMENT,
            device_name VARCHAR(255),
            device_id VARCHAR(128) UNIQUE,
            serial_number VARCHAR(128),
            last_seen VARCHAR(32),
            is_active INT DEFAULT 1
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول الأجهزة المصرّح بها — يعرض طلبات الاقتران القادمة من أجهزة
        # جديدة (PC2) ليوافق عليها مديرُ الجهاز الرئيسي (PC1) يدويًا.
        cursor.execute('''CREATE TABLE IF NOT EXISTS authorized_devices (
            id INT AUTO_INCREMENT PRIMARY KEY,
            device_name VARCHAR(100) NOT NULL,
            ip_address VARCHAR(45) NOT NULL,
            status VARCHAR(20) DEFAULT 'pending',
            requested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uq_device (device_name, ip_address)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول المنتجات المفضّلة (هجين: تلقائي حسب المبيعات + يدوي بالنجمة)
        cursor.execute('''CREATE TABLE IF NOT EXISTS product_favorites (
            id INT PRIMARY KEY AUTO_INCREMENT,
            product_id INT NOT NULL,
            is_manual TINYINT DEFAULT 0,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY (product_id),
            FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول المرتجعات — يتتبع الجهاز الذي سجّل كل مرتجع (device_name).
        cursor.execute('''CREATE TABLE IF NOT EXISTS returns (
            id INT PRIMARY KEY AUTO_INCREMENT,
            invoice_number VARCHAR(128) NOT NULL,
            sale_id INT NULL,
            customer_id INT NULL,
            total_amount DOUBLE NOT NULL DEFAULT 0,
            device_name VARCHAR(100) DEFAULT 'Main',
            return_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            note TEXT DEFAULT ''
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        cursor.execute('''CREATE TABLE IF NOT EXISTS return_items (
            id INT PRIMARY KEY AUTO_INCREMENT,
            return_id INT NOT NULL,
            product_id INT NOT NULL,
            quantity DOUBLE NOT NULL DEFAULT 0,
            price DOUBLE NOT NULL DEFAULT 0,
            total DOUBLE NOT NULL DEFAULT 0
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول المصاريف والفواتير التشغيلية (إيجار، كهرباء/ماء، رواتب، مستلزمات، صيانة...)
        cursor.execute('''CREATE TABLE IF NOT EXISTS expenses (
            id INT PRIMARY KEY AUTO_INCREMENT,
            title VARCHAR(150) NOT NULL,
            category VARCHAR(50) NOT NULL,
            amount DOUBLE NOT NULL,
            paid_from_drawer TINYINT DEFAULT 1,
            device_name VARCHAR(100) DEFAULT 'PC1',
            expense_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            note TEXT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول الموردين — يحمل رصيد الحساب الدائن (accounts payable) للمورد.
        # يُنشأ هنا أيضًا (وليس فقط من شاشة الموردين) لأن جدول المشتريات
        # يعتمد عليه كمفتاح أجنبي يجب ترتيبه قبل جدول purchases.
        cursor.execute('''CREATE TABLE IF NOT EXISTS suppliers (
            id INT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(255) NOT NULL,
            phone VARCHAR(64) DEFAULT '',
            address TEXT NULL,
            email VARCHAR(100) DEFAULT '',
            contact_person VARCHAR(100) DEFAULT '',
            balance DOUBLE DEFAULT 0,
            notes TEXT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول فواتير الشراء (Purchases / Supplier Invoices)
        cursor.execute('''CREATE TABLE IF NOT EXISTS purchases (
            id INT PRIMARY KEY AUTO_INCREMENT,
            supplier_id INT NULL,
            invoice_number VARCHAR(64) UNIQUE,
            total_amount DOUBLE NOT NULL DEFAULT 0,
            paid_amount DOUBLE NOT NULL DEFAULT 0,
            discount DOUBLE DEFAULT 0,
            purchase_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            device_name VARCHAR(100) DEFAULT 'PC1',
            note TEXT NULL,
            FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول بنود فواتير الشراء
        cursor.execute('''CREATE TABLE IF NOT EXISTS purchase_items (
            id INT PRIMARY KEY AUTO_INCREMENT,
            purchase_id INT NOT NULL,
            product_id INT,
            variant_id INT NULL,
            quantity DOUBLE NOT NULL DEFAULT 0,
            purchase_price DOUBLE NOT NULL DEFAULT 0,
            total DOUBLE NOT NULL DEFAULT 0,
            FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE,
            FOREIGN KEY (product_id) REFERENCES products(id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        # جدول حركات المخزون (مبيعات، مشتريات، جرد...) — يُنشأ هنا أيضًا حتى
        # تضمن فواتير الشراء كتابة الحركات حتى قبل تشغيل وحدة inventory.
        cursor.execute('''CREATE TABLE IF NOT EXISTS inventory_movements (
            id INT PRIMARY KEY AUTO_INCREMENT,
            product_id INT NOT NULL,
            quantity_change DOUBLE NOT NULL,
            reason TEXT NULL,
            movement_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4''')

        conn.commit()

        # ترحيل الأعمدة الجديدة للجداول القائمة (تُضاف بأمان إن لم تكن موجودة)
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sales' AND COLUMN_NAME = 'device_name'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE sales ADD COLUMN device_name VARCHAR(100) DEFAULT 'PC1'")
        except Exception:
            pass
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sales' AND COLUMN_NAME = 'status'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE sales ADD COLUMN status VARCHAR(20) DEFAULT 'completed'")
        except Exception:
            pass
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sale_items' AND COLUMN_NAME = 'variant_id'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE sale_items ADD COLUMN variant_id INT NULL")
        except Exception:
            pass
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'customers' AND COLUMN_NAME = 'debt_ceiling'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE customers ADD COLUMN debt_ceiling DOUBLE DEFAULT 0")
        except Exception:
            pass
        # ترحيل عمود الرصيد لجدول الموردين (أمان للمتاجر القائمة التي أنشأت الجدول
        # من شاشة الموردين قبل إضافة تتبع الحسابات الدائنة)
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'suppliers' AND COLUMN_NAME = 'balance'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE suppliers ADD COLUMN balance DOUBLE DEFAULT 0")
        except Exception:
            pass
        # ترحيل عمود المتغير (المقاس/اللون) لبنود فواتير الشراء للدعم المتغيرات
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'purchase_items' AND COLUMN_NAME = 'variant_id'
            """)
            has_col = cursor.fetchone()
            if has_col and has_col[0] == 0:
                cursor.execute("ALTER TABLE purchase_items ADD COLUMN variant_id INT NULL")
        except Exception:
            pass
        try:
            conn.commit()
        except Exception:
            pass

        conn.close()
        self._ensure_indexes()
        print("✅ قاعدة البيانات جاهزة!")

    # -----------------------------------------------------
    # الاقتران/التصريح بالأجهزة (authorized_devices)
    # -----------------------------------------------------

    def register_device_request(self, device_name, ip_address):
        """تسجيل طلب اقتران جديد (جهاز إضافي PC2) على جهاز الخادم.

        إدراج متماثل: إن وُجد طلب بنفس (device_name, ip_address) نعيده دون
        تكرار. إرجاع: dict {id, device_name, ip_address, status}.
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO authorized_devices (device_name, ip_address, status) "
                    "VALUES (%s, %s, 'pending') "
                    "ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)",
                    (str(device_name)[:100], str(ip_address)[:45]),
                )
                # استرجاع الصف في كل الحالات (مدرج حديثًا أو الموجود مسبقًا).
                cur.execute(
                    "SELECT id, device_name, ip_address, status FROM authorized_devices "
                    "WHERE device_name = %s AND ip_address = %s LIMIT 1",
                    (str(device_name)[:100], str(ip_address)[:45]),
                )
                row = cur.fetchone()
                conn.commit()
                if row:
                    return {"id": row[0], "device_name": row[1],
                            "ip_address": row[2], "status": row[3]}
                return {"id": None, "device_name": device_name,
                        "ip_address": ip_address, "status": "pending"}
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return None
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_pending_device_requests(self):
        """عرض طلبات الأجهزة الجديدة المعلّقة بانتظار موافقة المدير."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, device_name, ip_address, status, requested_at "
                    "FROM authorized_devices WHERE status = 'pending' "
                    "ORDER BY id ASC"
                )
                rows = cur.fetchall()
            return [
                {
                    "id": r[0], "device_name": r[1], "ip_address": r[2],
                    "status": r[3], "requested_at": r[4],
                }
                for r in rows
            ]
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def set_device_request_status(self, request_id, status):
        """تحديث حالة طلب اقتران (approve / deny)."""
        if status not in ("approved", "denied"):
            status = "denied"
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE authorized_devices SET status = %s WHERE id = %s",
                    (status, int(request_id)),
                )
            conn.commit()
            return True
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def is_device_authorized(self, ip_address):
        """هل الجهاز الموجود على هذا العنوان مصرَّح له بالاتصال؟"""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) FROM authorized_devices "
                    "WHERE ip_address = %s AND status = 'approved'",
                    (str(ip_address)[:45],),
                )
                r = cur.fetchone()
            return bool(r and r[0] > 0)
        except Exception:
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # -----------------------------------------------------
    # المرتجعات حسب الجهاز
    # -----------------------------------------------------

    def get_all_device_names(self):
        """إعادة قائمة بأسماء الأجهزة الفريدة التي سجّلت مرتجعات."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT DISTINCT device_name FROM returns ORDER BY device_name")
                return [r[0] for r in cur.fetchall() if r[0]]
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_returns(self, device_name=None, limit=100, offset=0):
        """جلب المرتجعات، بشكل اختياري مفلّتر حسب الجهاز.

        يُعيد list of tuples:
        (id, invoice_number, sale_id, customer_id, total_amount,
         device_name, return_date, note)
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                if device_name:
                    cur.execute(
                        "SELECT id, invoice_number, sale_id, customer_id, "
                        "total_amount, device_name, return_date, note "
                        "FROM returns WHERE device_name = %s "
                        "ORDER BY return_date DESC LIMIT %s OFFSET %s",
                        (device_name, limit, offset),
                    )
                else:
                    cur.execute(
                        "SELECT id, invoice_number, sale_id, customer_id, "
                        "total_amount, device_name, return_date, note "
                        "FROM returns ORDER BY return_date DESC LIMIT %s OFFSET %s",
                        (limit, offset),
                    )
                return cur.fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # -----------------------------------------------------
    # سجل الفواتير/الوصولات حسب الجهاز (sales history)
    # -----------------------------------------------------

    def get_all_sales_devices(self):
        """إعادة قائمة بأسماء الأجهزة الفريدة التي أصدرت وصلات بيع."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT DISTINCT device_name FROM sales ORDER BY device_name")
                return [r[0] for r in cur.fetchall() if r[0]]
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_invoices_history(self, device_name=None, search_term=None, limit=100):
        """جلب سجل الفواتير مع اسم الزبون، اختياريًا مفلّتر حسب الجهاز/البحث.

        يُعيد list of tuples:
        (id, invoice_number, total, discount, paid_amount, change_amount,
         sale_date, customer_name, device_name)
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                sql = (
                    "SELECT s.id, s.invoice_number, s.total, s.discount, "
                    "s.paid_amount, s.change_amount, s.sale_date, "
                    "COALESCE(c.name, '') AS customer_name, s.device_name "
                    "FROM sales s "
                    "LEFT JOIN customers c ON c.id = s.customer_id "
                    "WHERE s.status != 'void' "
                )
                args = []
                if device_name:
                    sql += "AND s.device_name = %s "
                    args.append(device_name)
                if search_term:
                    sql += "AND s.invoice_number LIKE %s "
                    args.append("%" + str(search_term) + "%")
                sql += "ORDER BY s.sale_date DESC LIMIT %s"
                args.append(limit)
                cur.execute(sql, tuple(args))
                return cur.fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_invoice_items(self, sale_id):
        """جلب بنود فاتورة محددة مع أسماء المنتجات ووحداتها.

        يُعيد list of tuples:
        (si.id, p.name, si.quantity, si.price, si.total, p.unit, si.product_id)
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT si.id, COALESCE(p.name, '(منتج محذوف)'), si.quantity, "
                    "si.price, si.total, COALESCE(p.unit, ''), si.product_id "
                    "FROM sale_items si "
                    "LEFT JOIN products p ON p.id = si.product_id "
                    "WHERE si.sale_id = %s ORDER BY si.id",
                    (sale_id,),
                )
                return cur.fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def void_invoice(self, sale_id):
        """إلغاء فاتورة بيع نهائيًا واستعادة الكميات للمخزون.

        - تَرجع كل بنود الفاتورة إلى مخزون المنتجات وتسجل ذلك في حركة المخزون.
        - إذا كانت مرتبطة بزبون ولديه دين، تخفض رصيده الزبون.
        - تضع status = 'void' كي تختفي من سجل الفواتير.
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("BEGIN")
                cur.execute(
                    "SELECT product_id, variant_id, quantity FROM sale_items WHERE sale_id = %s",
                    (sale_id,),
                )
                items = cur.fetchall()
                cur.execute(
                    "SELECT invoice_number, customer_id, total, discount, paid_amount FROM sales WHERE id = %s",
                    (sale_id,),
                )
                sale = cur.fetchone()
                invoice_number = sale[0] if sale else f"ID-{sale_id}"

                for row in items:
                    product_id, variant_id, qty = row[0], row[1], row[2]
                    if qty is None or not qty:
                        continue
                    if product_id is not None:
                        cur.execute(
                            "UPDATE products SET quantity = COALESCE(quantity, 0) + %s WHERE id = %s",
                            (qty, product_id),
                        )
                        cur.execute(
                            "INSERT INTO inventory_movements (product_id, quantity_change, reason) "
                            "VALUES (%s, %s, %s)",
                            (product_id, qty, f"إلغاء فاتورة - {invoice_number}"),
                        )
                    if variant_id is not None:
                        cur.execute(
                            "UPDATE product_variants SET quantity = COALESCE(quantity, 0) + %s WHERE id = %s",
                            (qty, variant_id),
                        )
                if sale:
                    customer_id, total, discount, paid_amount = sale[1:]
                    try:
                        total = float(total or 0)
                        paid_amount = float(paid_amount or 0)
                    except Exception:
                        total = 0.0
                        paid_amount = 0.0
                    if customer_id not in (None, 0) and paid_amount > 0:
                        cur.execute(
                            "UPDATE customers SET balance = GREATEST(0, COALESCE(balance, 0) - %s) WHERE id = %s",
                            (paid_amount, customer_id),
                        )
                cur.execute(
                    "UPDATE sales SET status = 'void', total = 0, discount = 0, paid_amount = 0, change_amount = 0 WHERE id = %s",
                    (sale_id,),
                )
                conn.commit()
            return True
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # -----------------------------------------------------
    # التقارير المالية والتحليلات المتقدمة
    # -----------------------------------------------------

    def get_financial_report(self, start_date, end_date, device_name=None):
        """تقرير مالي شامل بين تاريخين (بصيغة YYYY-MM-DD).

        يُعيد dict:
          gross_sales, discounts, returns_total, net_sales,
          paid_cash, outstanding_debt, cogs, net_profit,
          profit_margin_pct, invoice_count, items_sold, start_date, end_date
        """
        out = {
            "gross_sales": 0.0, "discounts": 0.0, "returns_total": 0.0,
            "net_sales": 0.0, "paid_cash": 0.0, "outstanding_debt": 0.0,
            "cogs": 0.0, "net_profit": 0.0, "profit_margin_pct": 0.0,
            "expenses_total": 0.0, "expenses_drawer": 0.0,
            "invoice_count": 0, "items_sold": 0,
            "start_date": start_date, "end_date": end_date,
        }
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND device_name = %s", [device_name]) if device_name else ("", [])

            inv = conn.execute(
                "SELECT COALESCE(SUM(total + discount),0), COALESCE(SUM(discount),0), "
                "COALESCE(SUM(paid_amount),0), "
                "COALESCE(SUM(CASE WHEN total > paid_amount THEN total - paid_amount ELSE 0 END),0), "
                "COUNT(*) "
                "FROM sales WHERE status != 'void' AND DATE(sale_date) BETWEEN %s AND %s" + dev_sql,
                [start_date, end_date] + dev_args,
            ).fetchone()
            if inv:
                out["gross_sales"] = float(inv[0] or 0)
                out["discounts"] = float(inv[1] or 0)
                out["paid_cash"] = float(inv[2] or 0)
                out["outstanding_debt"] = float(inv[3] or 0)
                out["invoice_count"] = int(inv[4] or 0)

            ret = conn.execute(
                "SELECT COALESCE(SUM(total_amount),0) FROM returns "
                "WHERE DATE(return_date) BETWEEN %s AND %s" + dev_sql,
                [start_date, end_date] + dev_args,
            ).fetchone()
            out["returns_total"] = float(ret[0] or 0) if ret else 0.0

            cogs = conn.execute(
                "SELECT COALESCE(SUM(si.quantity * COALESCE(p.cost,0)),0), "
                "COALESCE(SUM(si.quantity),0) "
                "FROM sale_items si "
                "LEFT JOIN products p ON p.id = si.product_id "
                "JOIN sales s ON s.id = si.sale_id "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s" + dev_sql,
                [start_date, end_date] + dev_args,
            ).fetchone()
            if cogs:
                out["cogs"] = float(cogs[0] or 0)
                out["items_sold"] = float(cogs[1] or 0)

            out["net_sales"] = max(0.0, out["gross_sales"] - out["discounts"] - out["returns_total"])

            exp = conn.execute(
                "SELECT COALESCE(SUM(amount),0), "
                "COALESCE(SUM(CASE WHEN paid_from_drawer = 1 THEN amount ELSE 0 END),0) "
                "FROM expenses "
                "WHERE DATE(expense_date) BETWEEN %s AND %s" + dev_sql,
                [start_date, end_date] + dev_args,
            ).fetchone()
            if exp:
                out["expenses_total"] = float(exp[0] or 0)
                out["expenses_drawer"] = float(exp[1] or 0)

            out["net_profit"] = out["net_sales"] - out["cogs"] - out["expenses_total"]
            if out["net_sales"] > 0:
                out["profit_margin_pct"] = (out["net_profit"] / out["net_sales"]) * 100.0
        except Exception:
            pass
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
        return out

    def get_hourly_traffic_data(self, day_of_week=None, device_name=None, lookback_days=60):
        """تحليل حركة العملاء حسب الساعة لآخر lookback_days يوم.

        day_of_week: رقم يوم الأسبوع بنظام MySQL DAYOFWEEK
        (1 = الأحد .. 7 = السبت) أو None لجميع الأيام.

        يُعيد dict:
          {"lookback_days": n, "total_days": n, "rows": [(dow, hour, invoices, volume), ...]}
        """
        data = {"lookback_days": int(lookback_days), "total_days": 0, "rows": []}
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND device_name = %s", [device_name]) if device_name else ("", [])
            dow_sql, dow_args = (" AND DAYOFWEEK(sale_date) = %s", [int(day_of_week)]) if day_of_week else ("", [])
            since = "DATE_SUB(CURDATE(), INTERVAL %s DAY)"

            days = conn.execute(
                "SELECT COUNT(DISTINCT DATE(sale_date)) FROM sales "
                "WHERE status != 'void' AND DATE(sale_date) >= " + since + dev_sql + dow_sql,
                [int(lookback_days)] + dev_args + dow_args,
            ).fetchone()
            data["total_days"] = int(days[0] or 0) if days else 0

            rows = conn.execute(
                "SELECT DAYOFWEEK(sale_date) AS dow, HOUR(sale_date) AS hr, "
                "COUNT(*) AS invoices, COALESCE(SUM(total - discount),0) AS volume "
                "FROM sales "
                "WHERE status != 'void' AND DATE(sale_date) >= " + since + dev_sql + dow_sql +
                " GROUP BY dow, hr ORDER BY dow, hr",
                [int(lookback_days)] + dev_args + dow_args,
            ).fetchall()
            data["rows"] = [
                (int(r[0]), int(r[1]), float(r[2] or 0), float(r[3] or 0))
                for r in rows or []
            ]
        except Exception:
            pass
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
        return data

    def get_slow_moving_products(self, days=30, threshold_qty=2):
        """منتجات بطيئة الحركة: مبيعاتها في آخر `days` يوم <= threshold_qty.

        تُعيد list of tuples:
        (id, name, unit, current_stock, sold_qty, cost)
        """
        conn = None
        try:
            conn = self.get_connection()
            rows = conn.execute(
                "SELECT p.id, p.name, p.unit, p.quantity AS current_stock, "
                "COALESCE(SUM(CASE WHEN s.sale_date >= DATE_SUB(CURDATE(), INTERVAL %s DAY) "
                "THEN si.quantity ELSE 0 END),0) AS sold_qty, "
                "COALESCE(p.cost,0) AS cost "
                "FROM products p "
                "LEFT JOIN sale_items si ON si.product_id = p.id "
                "LEFT JOIN sales s ON s.id = si.sale_id AND s.status != 'void' "
                "GROUP BY p.id, p.name, p.unit, p.quantity, p.cost "
                "HAVING sold_qty <= %s "
                "ORDER BY sold_qty ASC, p.quantity DESC",
                (int(days), float(threshold_qty)),
            ).fetchall()
            return [
                (int(r[0]), str(r[1] or ""), str(r[2] or "قطعة"),
                 float(r[3] or 0), float(r[4] or 0), float(r[5] or 0))
                for r in rows or []
            ]
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_product_performance(self, start_date, end_date, device_name=None):
        """أداء المنتجات: الكمية والإيراد والتكلفة وصافي الربح لفترة محددة.

        تُعيد list of tuples:
        (product_id, name, qty_sold, revenue, cogs, net_profit)
        """
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND s.device_name = %s", [device_name]) if device_name else ("", [])
            rows = conn.execute(
                "SELECT p.id, COALESCE(p.name, '(منتج محذوف)'), "
                "COALESCE(SUM(si.quantity),0) AS qty_sold, "
                "COALESCE(SUM(si.total),0) AS revenue, "
                "COALESCE(SUM(si.quantity * COALESCE(p.cost,0)),0) AS cogs "
                "FROM sale_items si "
                "LEFT JOIN products p ON p.id = si.product_id "
                "JOIN sales s ON s.id = si.sale_id "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s" + dev_sql +
                " GROUP BY p.id, p.name ORDER BY qty_sold DESC",
                [start_date, end_date] + dev_args,
            ).fetchall()
            result = []
            for r in rows or []:
                qty = float(r[2] or 0)
                rev = float(r[3] or 0)
                cost = float(r[4] or 0)
                result.append((int(r[0] or 0), str(r[1] or ""), qty, rev, cost, rev - cost))
            return result
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_profit_by_category(self, start_date, end_date, device_name=None):
        """ربح المبيعات حسب فئة المنتج (Categories) لفترة محددة.

        تُعيد list of tuples:
        (category_name, revenue, cogs, qty_sold)
        """
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND s.device_name = %s", [device_name]) if device_name else ("", [])
            rows = conn.execute(
                "SELECT COALESCE(c.name, 'غير مصنّف'), "
                "COALESCE(SUM(si.total),0) AS revenue, "
                "COALESCE(SUM(si.quantity * COALESCE(p.cost,0)),0) AS cogs, "
                "COALESCE(SUM(si.quantity),0) AS qty "
                "FROM sale_items si "
                "LEFT JOIN products p ON p.id = si.product_id "
                "LEFT JOIN categories c ON c.id = p.category_id "
                "JOIN sales s ON s.id = si.sale_id "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s" + dev_sql +
                " GROUP BY c.id, c.name ORDER BY revenue DESC",
                [start_date, end_date] + dev_args,
            ).fetchall()
            return [
                (str(r[0] or "غير مصنّف"), float(r[1] or 0),
                 float(r[2] or 0), float(r[3] or 0))
                for r in rows or []
            ]
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_daily_timeline(self, start_date, end_date, device_name=None):
        """الإيراد والأرباح اليومية لفترة محددة (لرسم خط الاتجاه اليومي).

        تُعيد list of tuples:
        (date, revenue, cogs, invoice_count)
        """
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND s.device_name = %s", [device_name]) if device_name else ("", [])
            rows = conn.execute(
                "SELECT DATE(s.sale_date) AS d, "
                "COALESCE(SUM(s.total),0) AS revenue, "
                "COALESCE(SUM((SELECT COALESCE(SUM(si.quantity * COALESCE(p.cost,0)),0) "
                "FROM sale_items si LEFT JOIN products p ON p.id = si.product_id "
                "WHERE si.sale_id = s.id)),0) AS cogs, "
                "COUNT(*) AS cnt "
                "FROM sales s "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s" + dev_sql +
                " GROUP BY DATE(s.sale_date) ORDER BY d",
                [start_date, end_date] + dev_args,
            ).fetchall()
            return [
                (str(r[0] or ""), float(r[1] or 0), float(r[2] or 0), int(r[3] or 0))
                for r in rows or []
            ]
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_hourly_revenue(self, start_date, end_date, device_name=None):
        """الإيراد والأرباح حسب الساعة (مجموع الفترة) لرسم المنحنى بالساعة.

        تُعيد list of tuples:
        (hour, revenue, cogs, invoice_count)
        """
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND s.device_name = %s", [device_name]) if device_name else ("", [])
            rows = conn.execute(
                "SELECT HOUR(s.sale_date) AS hr, "
                "COALESCE(SUM(s.total),0) AS revenue, "
                "COALESCE(SUM((SELECT COALESCE(SUM(si.quantity * COALESCE(p.cost,0)),0) "
                "FROM sale_items si LEFT JOIN products p ON p.id = si.product_id "
                "WHERE si.sale_id = s.id)),0) AS cogs, "
                "COUNT(*) AS cnt "
                "FROM sales s "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s" + dev_sql +
                " GROUP BY HOUR(s.sale_date) ORDER BY hr",
                [start_date, end_date] + dev_args,
            ).fetchall()
            return [
                (int(r[0] or 0), float(r[1] or 0), float(r[2] or 0), int(r[3] or 0))
                for r in rows or []
            ]
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_device_breakdown(self, start_date, end_date):
        """توزيع الأداء حسب الجهاز لفترة محددة.

        تُعيد list of tuples:
        (device_name, receipts, gross, returns_total)
        """
        conn = None
        try:
            conn = self.get_connection()
            rows = conn.execute(
                "SELECT s.device_name, COUNT(*) AS receipts, "
                "COALESCE(SUM(s.total + s.discount),0) AS gross "
                "FROM sales s "
                "WHERE s.status != 'void' AND DATE(s.sale_date) BETWEEN %s AND %s "
                "GROUP BY s.device_name ORDER BY receipts DESC",
                (start_date, end_date),
            ).fetchall()
            result = []
            for r in rows or []:
                dev = str(r[0] or "غير معروف")
                ret = conn.execute(
                    "SELECT COALESCE(SUM(total_amount),0) FROM returns "
                    "WHERE device_name = %s AND DATE(return_date) BETWEEN %s AND %s",
                    (dev, start_date, end_date),
                ).fetchone()
                result.append((dev, int(r[1] or 0), float(r[2] or 0),
                               float(ret[0] or 0) if ret else 0.0))
            return result
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_voided_invoices(self, start_date, end_date, device_name=None):
        """سجل الفواتير الملغاة (void) للفترة.

        تُعيد list of tuples:
        (id, invoice_number, sale_date, device_name)
        """
        conn = None
        try:
            conn = self.get_connection()
            dev_sql, dev_args = (" AND device_name = %s", [device_name]) if device_name else ("", [])
            rows = conn.execute(
                "SELECT id, invoice_number, sale_date, device_name FROM sales "
                "WHERE status = 'void' AND DATE(sale_date) BETWEEN %s AND %s" + dev_sql +
                " ORDER BY sale_date DESC",
                [start_date, end_date] + dev_args,
            ).fetchall()
            return [
                (int(r[0]), str(r[1] or ""), str(r[2] or "")[:19], str(r[3] or ""))
                for r in rows or []
            ]
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_debt_collected(self, start_date, end_date):
        """إجمالي الديون المحصلة (مدفوعات العملاء) خلال الفترة."""
        conn = None
        try:
            conn = self.get_connection()
            row = conn.execute(
                "SELECT COALESCE(SUM(amount),0) FROM debt_transactions "
                "WHERE transaction_type = 'payment' "
                "AND DATE(transaction_date) BETWEEN %s AND %s",
                (start_date, end_date),
            ).fetchone()
            return float(row[0] or 0) if row else 0.0
        except Exception:
            return 0.0
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    # -----------------------------------------------------
    # المصاريف والفواتير التشغيلية
    # -----------------------------------------------------

    def add_expense(self, title, category, amount, paid_from_drawer=1, device_name=None, note=""):
        """تسجيل مصروف / فاتورة تشغيلية جديدة.

        paid_from_drawer: 1 = نقدًا من الصندوق، 0 = سُدد خارجيًا.
        يُعيد معرّف المصروف الجديد أو None عند الفشل.
        """
        device_name = device_name or "PC1"
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO expenses (title, category, amount, paid_from_drawer, device_name, note) "
                    "VALUES (%s, %s, %s, %s, %s, %s)",
                    (
                        str(title).strip()[:150],
                        str(category).strip()[:50],
                        float(amount or 0),
                        1 if paid_from_drawer else 0,
                        str(device_name)[:100],
                        str(note or "").strip(),
                    ),
                )
                conn.commit()
                return True, cur.lastrowid
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, None
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_expenses(self, start_date=None, end_date=None, device_name=None):
        """جلب المصاريف المسجلة، اختياريًا خلال فترة أو حسب جهاز معين.

        تُعيد list of tuples:
        (id, title, category, amount, paid_from_drawer, device_name, expense_date, note)
        مرتبة من الأحدث إلى الأقدم.
        """
        conn = self.get_connection()
        try:
            where, args = [], []
            if start_date:
                where.append("DATE(expense_date) >= %s")
                args.append(start_date)
            if end_date:
                where.append("DATE(expense_date) <= %s")
                args.append(end_date)
            if device_name:
                where.append("device_name = %s")
                args.append(device_name)
            sql = ("SELECT id, title, category, amount, paid_from_drawer, "
                   "device_name, expense_date, note FROM expenses")
            if where:
                sql += " WHERE " + " AND ".join(where)
            sql += " ORDER BY expense_date DESC, id DESC"
            with conn.cursor() as cur:
                cur.execute(sql, args)
                return [
                    (int(r[0]), str(r[1] or ""), str(r[2] or ""), float(r[3] or 0),
                     int(r[4] or 1), str(r[5] or ""), str(r[6] or ""), str(r[7] or ""))
                    for r in cur.fetchall()
                ]
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def delete_expense(self, expense_id):
        """حذف مصروف / فاتورة حسب معرّفها."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM expenses WHERE id = %s", (int(expense_id),))
            conn.commit()
            return True
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # -----------------------------------------------------
    # متغيرات المنتج (المقاس / اللون)
    # -----------------------------------------------------

    def get_product_variants(self, product_id):
        """جلب متغيرات منتج محدد.

        يُعيد list of tuples:
        (id, variant_name, barcode, quantity, price)
        """
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, variant_name, barcode, quantity, price "
                    "FROM product_variants WHERE product_id = %s "
                    "ORDER BY id",
                    (product_id,),
                )
                return cur.fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def add_product_variant(self, product_id, variant_name, barcode, quantity, price=None):
        """إضافة متغير جديد لمنتج. يُعيد (success, variant_id_or_error)."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO product_variants "
                    "(product_id, variant_name, barcode, quantity, price) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (
                        product_id,
                        str(variant_name)[:100],
                        (str(barcode)[:64] if barcode else None),
                        float(quantity or 0),
                        (float(price) if price not in (None, "") else None),
                    ),
                )
                conn.commit()
                return True, cur.lastrowid
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, str(exc)
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def delete_product_variant(self, variant_id):
        """حذف متغير منتج."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM product_variants WHERE id = %s", (variant_id,))
                conn.commit()
            return True
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def update_variant_stock(self, variant_id, quantity_change):
        """تحديث كمية مخزون متغير (إضافة/خصم)."""
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE product_variants SET quantity = COALESCE(quantity, 0) + %s WHERE id = %s",
                    (float(quantity_change or 0), variant_id),
                )
                conn.commit()
            return True
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_variant_by_barcode(self, barcode):
        """البحث عن متغير بواسطة الباركود.

        يُعيد tuple مفرد:
        (variant_id, variant_name, variant_barcode, variant_quantity,
         variant_price, product_id, product_name, product_price, unit)
        أو None إذا لم يوجد.
        """
        if not barcode:
            return None
        conn = self.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT v.id, v.variant_name, v.barcode, v.quantity, v.price, "
                    "p.id, p.name, p.price, p.unit "
                    "FROM product_variants v "
                    "JOIN products p ON p.id = v.product_id "
                    "WHERE v.barcode = %s LIMIT 1",
                    (str(barcode),),
                )
                return cur.fetchone()
        except Exception:
            return None
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # -----------------------------------------------------
    # المشتريات وفواتير الشراء من الموردين (Purchases & Supplier Invoices)
    # -----------------------------------------------------

    def get_suppliers(self):
        """يعيد قائمة الموردين كصفوف (id, name, phone, balance)."""
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute("SELECT id, name, phone, balance FROM suppliers ORDER BY name")
                return cur.fetchall() or []
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def add_supplier(self, name, phone="", address="", email="", contact_person="", notes=""):
        """إضافة مورد جديد. تُرجع (True, new_id) عند النجاح أو (False, error)."""
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO suppliers (name, phone, address, email, contact_person, notes) "
                    "VALUES (%s, %s, %s, %s, %s, %s)",
                    (
                        str(name or "").strip()[:255],
                        str(phone or "").strip()[:64],
                        str(address or "").strip(),
                        str(email or "").strip()[:100],
                        str(contact_person or "").strip()[:100],
                        str(notes or "").strip(),
                    ),
                )
                conn.commit()
                return True, cur.lastrowid
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, str(exc)
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    @staticmethod
    def _new_purchase_invoice_number():
        from datetime import datetime as _dt
        now = _dt.now()
        return "PUR-{}-{:03d}".format(now.strftime("%Y%m%d-%H%M%S"), int(now.microsecond / 1000))

    def create_purchase_invoice(
        self,
        supplier_id,
        items,
        total_amount=None,
        paid_amount=0,
        discount=0,
        device_name=None,
        note="",
        invoice_number=None,
    ):
        """تسجيل فاتورة شراء في معاملة واحدة:
        - يُسجَّل الترويسة (purchases) والبنود (purchase_items)
        - يُزاد مخزون كل منتج في products
        - تُسجَّل حركة مخزون موجبة في inventory_movements
        - يُحدَّث سعر الشراء للمنتج إن تغيّر
        - يُزاد رصيد المورد (الحسابات الدائنة) بالمبلغ غير المسدد

        items: قائمة قواميس {"product_id", "quantity", "purchase_price",
                             "variant_id" (اختياري لتعبئة متغير مقاس/لون)}
        تُرجع (True, invoice_number, purchase_id, net_total, remaining)
        أو (False, error_message, None, 0, 0)
        """
        conn = None
        try:
            supplier_id = int(supplier_id or 0)
            discount = max(0.0, float(discount or 0))
            paid_amount = max(0.0, float(paid_amount or 0))
            if supplier_id > 0:
                # تأكد من وجود المورد (قيود المفاتيح الأجنبية في MySQL صارمة)
                conn = self.get_connection()
                with conn.cursor() as cur:
                    cur.execute("SELECT id FROM suppliers WHERE id = %s", (supplier_id,))
                    if not cur.fetchone():
                        conn.close()
                        return False, "المورد المحدد غير موجود", None, 0, 0
                conn.close()
            if not items:
                return False, "لا توجد منتجات في الفاتورة", None, 0, 0

            subtotal = 0.0
            prepared = []
            for item in items:
                pid = int(item.get("product_id") or 0)
                vid = item.get("variant_id")
                if vid is not None:
                    try:
                        vid = int(vid)
                    except Exception:
                        return False, "متغير المنتج غير صالح", None, 0, 0
                qty = float(item.get("quantity") or 0)
                price = float(item.get("purchase_price", item.get("price", 0)) or 0)
                if pid <= 0:
                    return False, "منتج غير صالح في الفاتورة", None, 0, 0
                if qty <= 0:
                    return False, "كمية المنتج يجب أن تكون أكبر من صفر", None, 0, 0
                if price < 0:
                    return False, "سعر الشراء لا يمكن أن يكون سالبًا", None, 0, 0
                subtotal += qty * price
                prepared.append((pid, vid, qty, price))

            if total_amount is None:
                gross = subtotal
            else:
                gross = max(0.0, float(total_amount or 0))
            if discount > gross:
                discount = gross
            net = max(0.0, gross - discount)
            if paid_amount > net:
                paid_amount = net
            remaining = max(0.0, net - paid_amount)

            number = str(invoice_number or self._new_purchase_invoice_number())[:64]

            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO purchases (supplier_id, invoice_number, total_amount, "
                    "paid_amount, discount, device_name, note) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    (
                        supplier_id if supplier_id > 0 else None,
                        number,
                        gross,
                        paid_amount,
                        discount,
                        str(device_name or "PC1")[:100],
                        str(note or "").strip(),
                    ),
                )
                purchase_id = cur.lastrowid

                for pid, vid, qty, price in prepared:
                    cur.execute("SELECT name, cost FROM products WHERE id = %s", (pid,))
                    prod = cur.fetchone()
                    if not prod:
                        raise ValueError("منتج غير موجود في الفاتورة: {}".format(pid))
                    variant_name = None
                    if vid is not None:
                        cur.execute(
                            "SELECT variant_name FROM product_variants WHERE id = %s AND product_id = %s",
                            (vid, pid),
                        )
                        vrow = cur.fetchone()
                        if not vrow:
                            raise ValueError("المتغير لا ينتمي إلى هذا المنتج أو غير موجود")
                        variant_name = str(vrow[0] or "")
                    current_cost = float(prod[1] or 0) if prod[1] is not None else 0.0
                    if vid is not None:
                        cur.execute(
                            "INSERT INTO purchase_items (purchase_id, product_id, variant_id, "
                            "quantity, purchase_price, total) VALUES (%s, %s, %s, %s, %s, %s)",
                            (purchase_id, pid, vid, qty, price, qty * price),
                        )
                    else:
                        cur.execute(
                            "INSERT INTO purchase_items (purchase_id, product_id, quantity, "
                            "purchase_price, total) VALUES (%s, %s, %s, %s, %s)",
                            (purchase_id, pid, qty, price, qty * price),
                        )
                    cur.execute(
                        "UPDATE products SET quantity = COALESCE(quantity, 0) + %s WHERE id = %s",
                        (qty, pid),
                    )
                    if vid is not None:
                        cur.execute(
                            "UPDATE product_variants SET quantity = COALESCE(quantity, 0) + %s WHERE id = %s",
                            (qty, vid),
                        )
                    if abs(price - current_cost) > 1e-9:
                        cur.execute("UPDATE products SET cost = %s WHERE id = %s", (price, pid))
                    reason = "شراء من مورد - {}".format(number)
                    if variant_name:
                        reason += " ({})".format(variant_name)
                    cur.execute(
                        "INSERT INTO inventory_movements (product_id, quantity_change, reason) "
                        "VALUES (%s, %s, %s)",
                        (pid, qty, reason),
                    )

                if supplier_id > 0 and remaining > 0:
                    cur.execute(
                        "UPDATE suppliers SET balance = COALESCE(balance, 0) + %s WHERE id = %s",
                        (remaining, supplier_id),
                    )
                conn.commit()
                return True, number, purchase_id, net, remaining
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, str(exc), None, 0, 0
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_purchases(self, search=None, device_name=None, limit=300):
        """يعيد فواتير الشراء كصفوف:
        (id, invoice_number, supplier_name, total_amount, paid_amount, discount,
         purchase_date, device_name, note). المتبقي = total_amount - discount - paid_amount.
        """
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                sql = (
                    "SELECT p.id, p.invoice_number, COALESCE(s.name, ''), "
                    "p.total_amount, p.paid_amount, p.discount, p.purchase_date, p.device_name, p.note "
                    "FROM purchases p LEFT JOIN suppliers s ON s.id = p.supplier_id "
                    "WHERE 1=1"
                )
                params = []
                if device_name:
                    sql += " AND p.device_name = %s"
                    params.append(device_name)
                if search:
                    sql += " AND (p.invoice_number LIKE %s OR COALESCE(s.name,'') LIKE %s OR COALESCE(p.note,'') LIKE %s)"
                    like = "%{}%".format(str(search).strip())
                    params.extend([like, like, like])
                sql += " ORDER BY p.purchase_date DESC, p.id DESC LIMIT %s"
                params.append(int(limit or 300))
                cur.execute(sql, params)
                return cur.fetchall() or []
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_purchase_items(self, purchase_id):
        """بنود فاتورة شراء محددة كصفوف:
        (id, product_id, name, quantity, purchase_price, total, variant_id, variant_name)
        """
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT pi.id, pi.product_id, COALESCE(p.name, ''), "
                    "pi.quantity, pi.purchase_price, pi.total, "
                    "pi.variant_id, COALESCE(v.variant_name, '') "
                    "FROM purchase_items pi "
                    "LEFT JOIN products p ON p.id = pi.product_id "
                    "LEFT JOIN product_variants v ON v.id = pi.variant_id "
                    "WHERE pi.purchase_id = %s ORDER BY pi.id",
                    (int(purchase_id or 0),),
                )
                return cur.fetchall() or []
        except Exception:
            return []
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def get_purchase(self, purchase_id):
        """ترويسة فاتورة شراء واحدة:
        (id, supplier_id, invoice_number, total_amount, paid_amount, discount,
         purchase_date, device_name, note)
        """
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, supplier_id, invoice_number, total_amount, paid_amount, "
                    "discount, purchase_date, device_name, note "
                    "FROM purchases WHERE id = %s",
                    (int(purchase_id or 0),),
                )
                return cur.fetchone()
        except Exception:
            return None
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def record_supplier_payment(self, supplier_id, amount, note=""):
        """تسجيل دفعة نقدية للمورد: يخصم المبلغ من رصيد المورد (الحساب الدائن).
        تُرجع (True, new_balance) أو (False, error).
        """
        conn = None
        try:
            supplier_id = int(supplier_id or 0)
            amount = float(amount or 0)
            if amount <= 0:
                return False, "المبلغ يجب أن يكون أكبر من صفر"
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute("SELECT balance FROM suppliers WHERE id = %s", (supplier_id,))
                row = cur.fetchone()
                if not row:
                    return False, "المورد غير موجود"
                current = float(row[0] or 0)
                if amount > current + 1e-9:
                    return False, "المبلغ أكبر من رصيد المورد"
                new_balance = max(0.0, current - amount)
                cur.execute(
                    "UPDATE suppliers SET balance = %s WHERE id = %s",
                    (new_balance, supplier_id),
                )
                conn.commit()
                return True, new_balance
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, str(exc)
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    def delete_purchase(self, purchase_id):
        """حذف فاتورة شراء بأمان (معاملة واحدة):
        - تُعاد الكميات إلى المخزون (نقصان) + حركة مخزون سالبة
        - يُخصم المبلغ غير المسدد من رصيد المورد
        - تُحذف البنود ثم الفاتورة
        تُرجع (True, message) أو (False, error).
        """
        conn = None
        try:
            conn = self.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT invoice_number, supplier_id, total_amount, discount, paid_amount "
                    "FROM purchases WHERE id = %s",
                    (int(purchase_id or 0),),
                )
                hdr = cur.fetchone()
                if not hdr:
                    return False, "فاتورة الشراء غير موجودة"
                invoice_number, supplier_id, total_amount, discount, paid_amount = hdr
                cur.execute(
                    "SELECT product_id, quantity, variant_id FROM purchase_items WHERE purchase_id = %s",
                    (int(purchase_id or 0),),
                )
                items = cur.fetchall() or []
                for row in items:
                    pid, qty, vid = row[0], row[1], row[2]
                    if pid is None:
                        continue
                    qty = float(qty or 0)
                    cur.execute(
                        "UPDATE products SET quantity = GREATEST(0, COALESCE(quantity, 0) - %s) WHERE id = %s",
                        (qty, pid),
                    )
                    if vid is not None:
                        try:
                            vid = int(vid)
                        except Exception:
                            vid = None
                        if vid:
                            cur.execute(
                                "UPDATE product_variants SET quantity = GREATEST(0, COALESCE(quantity, 0) - %s) WHERE id = %s",
                                (qty, vid),
                            )
                    cur.execute(
                        "INSERT INTO inventory_movements (product_id, quantity_change, reason) "
                        "VALUES (%s, %s, %s)",
                        (pid, -qty, "حذف فاتورة شراء - {}".format(invoice_number or purchase_id)),
                    )
                net = max(0.0, float(total_amount or 0) - float(discount or 0))
                remaining = max(0.0, net - float(paid_amount or 0))
                if supplier_id and remaining > 0:
                    cur.execute(
                        "UPDATE suppliers SET balance = GREATEST(0, COALESCE(balance, 0) - %s) WHERE id = %s",
                        (remaining, supplier_id),
                    )
                cur.execute("DELETE FROM purchase_items WHERE purchase_id = %s", (int(purchase_id or 0),))
                cur.execute("DELETE FROM purchases WHERE id = %s", (int(purchase_id or 0),))
                conn.commit()
                return True, "تم حذف فاتورة الشراء"
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            return False, str(exc)
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    # -----------------------------------------------------
    # الفهارس: تُضاف بطريقة آمنة (IF NOT EXISTS) للمسارات الأكثر استعمالًا.
    # تعالجها طبقة التوافق (CREATE INDEX IF NOT EXISTS) دون كسر القواعد القديمة.
    # -----------------------------------------------------
    def _ensure_indexes(self):
        global _INDEXES_ENSURED
        if _INDEXES_ENSURED:
            return
        conn = None
        try:
            conn = self.get_connection()
            cursor = conn.cursor()
            index_stmts = [
                "CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(sale_date)",
                "CREATE INDEX IF NOT EXISTS idx_sales_customer ON sales(customer_id)",
                "CREATE INDEX IF NOT EXISTS idx_sales_device ON sales(device_name)",
                "CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id)",
                "CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)",
                "CREATE INDEX IF NOT EXISTS idx_sale_items_variant ON sale_items(variant_id)",
                "CREATE INDEX IF NOT EXISTS idx_inv_mov_product ON inventory_movements(product_id)",
                "CREATE INDEX IF NOT EXISTS idx_returns_sale ON returns(sale_id)",
                "CREATE INDEX IF NOT EXISTS idx_returns_device ON returns(device_name)",
                "CREATE INDEX IF NOT EXISTS idx_retitems_return ON return_items(return_id)",
                "CREATE INDEX IF NOT EXISTS idx_retitems_product ON return_items(product_id)",
                "CREATE INDEX IF NOT EXISTS idx_products_name ON products(name)",
                "CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name)",
                "CREATE INDEX IF NOT EXISTS idx_variant_product ON product_variants(product_id)",
                "CREATE INDEX IF NOT EXISTS idx_variant_barcode ON product_variants(barcode)",
                "CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at)",
                "CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_log(username)",
                "CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(expense_date)",
                "CREATE INDEX IF NOT EXISTS idx_expenses_device ON expenses(device_name)",
                "CREATE INDEX IF NOT EXISTS idx_suppliers_name ON suppliers(name)",
                "CREATE INDEX IF NOT EXISTS idx_purchases_supplier ON purchases(supplier_id)",
                "CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases(purchase_date)",
                "CREATE INDEX IF NOT EXISTS idx_purchases_device ON purchases(device_name)",
                "CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items(purchase_id)",
                "CREATE INDEX IF NOT EXISTS idx_purchase_items_product ON purchase_items(product_id)",
                "CREATE INDEX IF NOT EXISTS idx_purchase_items_variant ON purchase_items(variant_id)",
            ]
            for stmt in index_stmts:
                try:
                    cursor.execute(stmt)
                except Exception:
                    pass
            try:
                conn.commit()
            except Exception:
                pass
            _INDEXES_ENSURED = True
        except Exception:
            pass
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
