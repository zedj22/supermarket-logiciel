# -*- coding: utf-8 -*-
"""
utils/network_discovery.py
=========================
اكتشاف الجهاز الرئيسي (الخادم) على الشبكة المحلية — نظام اكتشاف هجين متين
يجمع بين بثّ UDP ونطاق TCP مُوازٍ سريع. طبقة شبكات نقيّة لا تعتمد على أي
شيفرة واجهة (tkinter/customtkinter) ولا على قاعدة البيانات، ليصحّ استدعاؤها
من أي مكان في التطبيق واختبارها مستقلاً.

البروتوكول:
  - منفذ UDP مخصص واحد (DISCOVERY_PORT).
  - طلب الاكتشاف يبدأ ببادئة نصية ثابتة (DISCOVERY_REQUEST) أيًّا كان
    متغيّرًا فيه البيئة، والرد JSON يحمل حقل app = APP_SIGNATURE حتى لا يقبل
    العميل أي مستجيب عشوائي على الشبكة.

الموثوقية (مُحسّنة لشبكات البيع بالتجزئة عبر WiFi/DHCP):
  - كشف الواجهات الحقيقية عبر اتصال UDP وهمي (1.1.1.1:80) و name-based
    lookup، مع استبعاد loopback (127.*) و APIPA (169.254.*).
  - تحديد أولوية لشبكات IPv4 الخاصة (192.168.*, 10.*, 172.16-31.*).
  - البث إلى البثّ العام 255.255.255.255 بالإضافة إلى البثّ الموجه
    (x.x.x.255) لكل واجهة نشطة — تتجاوب مع شبكات Wi-Fi/موجّهات تمنع
    البثّ الموجه (client isolation / broadcast suppression).
  - نطاق TCP مُوازٍ سريع (ThreadPoolExecutor) لا يلمس قاعدة البيانات
    أثناء المسح: يكتفي بفحص المنفذ عبر connect_ex، ما يجعله سريعًا ومتينًا
    تحت زمن الوصول.
  - إلغاء نظيف للمقبس وخيط الخلفية. عملية مفقودة تترك المنفذ مفتوحًا
    تُكتشف بـ: netstat -ano | findstr <port>
"""

import ipaddress
import json
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

DISCOVERY_PORT = 50000
DISCOVERY_REQUEST = b"SUPERMARKET_PRO_DISCOVER"
APP_SIGNATURE = "supermarket_pro"

# أسماء معرّفة تخص المُبدِّلات الافتراضية — نتجنّب إعلانها/البثّ منها
# عندما يكون هناك بديل حقيقي يحمل بوابة افتراضية.
_VIRTUAL_HINTS = (
    "virtual", "vmware", "virtualbox", "vbox", "hyper-v", "vEthernet",
    "docker", "wsl", "tap-", "tun", "tunnel", "nordvpn", "wireguard",
    "openvpn", "zerotier", "tailscale", "hamachi", "radmin", "protonvpn",
    "expressvpn", "anyconnect", "globalprotect", "loopback", "localhost",
    "صاحبي", "mullvad",
)

# منفذ TCP الافتراضي الذي يفحصه نطاق الشبكة — كانت قاعدة بيانات التطبيق.
DEFAULT_DISCOVERY_TCP_PORT = 3306


# ----------------------------------------------------------------
# أدوات مساعدة
# ----------------------------------------------------------------

def _is_loopback(ip):
    try:
        return ipaddress.ip_address(str(ip)).is_loopback
    except Exception:
        return ip == "127.0.0.1" or ip == "localhost"


def _is_apipa(ip):
    """هل العنوان ضمن 169.254.0.0/16 (APIPA / link-local)؟"""
    try:
        return str(ipaddress.ip_address(str(ip))).startswith("169.254.")
    except Exception:
        return False


def _is_routable_ipv4(ip):
    """عنوان IPv4 صالح على الشبكة (لا loopback ولا APIPA ولا multicast/0/1)."""
    try:
        addr = ipaddress.ip_address(str(ip))
    except Exception:
        return False
    if addr.version != 4:
        return False
    if addr.is_loopback or addr.is_multicast or addr.is_unspecified:
        return False
    if _is_apipa(addr):
        return False
    return True


def _is_private_subnet(ip):
    """هل العنوان ضمن نطاقات IPv4 الخاصة (192.168/16, 10/8, 172.16-31/12)؟"""
    try:
        return ipaddress.ip_address(str(ip)).is_private
    except Exception:
        return False


def _priv_priority(ip):
    """ترتيب للتفضيل: نطاقات خاصة أولًا ثم الباقي (متوافق مع enum)."""
    return 0 if _is_private_subnet(ip) else 1


# ----------------------------------------------------------------
# كشف واجهات LAN — نهج هجين
#  - اتصال UDP وهمي نحو 1.1.1.1:80 (connect لا يُرسل شيئًا، يختار المسار فقط).
#  - بحث باسم hostname لكل الواجهات.
#  - استبعاد loopback/APIPA، وتفضيل الشبكات الخاصة.
# ----------------------------------------------------------------

def _udp_connect_default_ip():
    """عنوان IP للواجهة التي يختارها نظام التشغيل للبث للإنترنت."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.settimeout(0.3)
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except Exception:
        pass
    finally:
        try:
            s.close()
        except Exception:
            pass
    # إعادة محاولة نحو مضيف آخر إن فشل الأول
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.settimeout(0.3)
        s.connect(("8.8.8.8", 53))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        try:
            s.close()
        except Exception:
            pass


def _hostname_ips():
    """كل عناوين IPv4 من gethostbyname_ex(hostname) (قد تكون متعددة)."""
    try:
        _name, _aliases, addrs = socket.gethostbyname_ex(socket.gethostname())
    except Exception:
        return []
    return [a for a in addrs if _is_routable_ipv4(a)]


def get_all_active_local_ips():
    """كل عناوين IPv4 النشطة على الجهاز (المرشَّحات).

    يجمع من:
      1) اتصال UDP وهمي نحو 1.1.1.1:80 (الواجهة الافتراضية).
      2) socket.gethostbyname_ex(hostname).
    يستبعد loopback (127.*) و APIPA (169.254.*).
    """
    candidates = set()

    default_ip = _udp_connect_default_ip()
    if default_ip and _is_routable_ipv4(default_ip):
        candidates.add(str(default_ip))

    for ip in _hostname_ips():
        candidates.add(str(ip))

    result = list(candidates)
    # الأفضلية: الشبكات الخاصة أولًا.
    result.sort(key=_priv_priority)
    print(f"[DISCOVERY-DEBUG] Active IPs: {result}")
    return result


def list_interfaces():
    """قائمة الواجهات IPv4 غير الحلقية: (ip, prefixlen, has_gateway, desc).

    صياغة متوافقة مع الاستدعاءات القديمة — نعتبر كل عنصر واجهة نشطة.
    """
    rows = []
    seen = set()
    ips = get_all_active_local_ips()
    for idx, ip in enumerate(ips):
        if ip in seen:
            continue
        seen.add(ip)
        # الواجهة الأولى هي مسار الإنترنت الافتراضي (حسب UDP connect).
        desc = "default" if idx == 0 else "hostname"
        has_gateway = (idx == 0)
        rows.append((ip, 24, has_gateway, desc))
    if not rows:
        try:
            fallback = socket.gethostbyname(socket.gethostname())
        except Exception:
            fallback = "127.0.0.1"
        rows.append((fallback, 24, False, "fallback"))
    return rows


def primary_ip():
    """أفضل عنوان IP محلي — يفضّل شبكات IPv4 الخاصة غير الافتراضية.

    يركّز على واجهة LAN الحقيقية (Wi-Fi/Ethernet): العنوان الذي لا ينتهي بـ .1
    (محوّلات VMware/VirtualBox الافتراضية تنتهي غالبًا بـ .1). نعود إلى الإعداد
    الافتراضي (أوّل IP نشط) إذا لم يكن هناك أي عنوان حقيقي.
    """
    ips = get_all_active_local_ips()
    if not ips:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"
    real = [ip for ip in ips if _looks_like_real_lan(ip)
            and not _is_loopback(ip) and not _is_apipa(ip)]
    if real:
        return real[0]
    return ips[0]


def _looks_like_real_lan(ip_str):
    """هل العنوان يبدو لواجهة LAN حقيقية (Wi-Fi/Ethernet) لا واجهة افتراضية؟

    محوّلات VMware/VirtualBox غالبًا تحمل عنوانًا شبكيًا ينتهي بـ .1 (بوابة/
    مبدّل افتراضي). نعتبر عنوانًا لا ينتهي بـ .1 مرشّحًا أقوى لشبكة حقيقية.
    """
    try:
        last = int(str(ip_str).rsplit(".", 1)[1])
    except Exception:
        return True
    return last != 1


def get_real_lan_ip():
    """اكتشاف عنوان IP المحلي المتصل فعلًا بالشبكة/الموجّه.

    اتصال UDP وهمي نحو بوابة/خادم DNS عام: لا يُرسل أي حزم فعلية، بل يختار
    نظام التشغيل الواجهة التي تُخرجها للشبكة، فنقرأ عنوانها الحقيقي.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # الاتصال لا يُرسل بيانات؛ فقط يختار المسار الصحيح نحو الخارج.
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        if _is_routable_ipv4(ip):
            return str(ip)
        return ip
    except Exception:
        return "127.0.0.1"
    finally:
        try:
            s.close()
        except Exception:
            pass


def get_local_subnet_ips():
    """توليد مرشّحات IP في /24 للشبكة المحلية الحقيقية فقط (مباشرة).

    نعتمد على get_real_lan_ip() لنمنع أي خلط مع المحوّلات الافتراضية
    (VMware/VirtualBox). إن قدّم عنوانًا غير حلقية نولّد نطاق /24 كاملًا
    (من x.x.x.1 إلى x.x.x.254 باستثناء عنوان الجهاز نفسه) — أي ~253 مرشّحًا.
    إن فشل كشف الواجهة الحقيقية نتراجع إلى primary_ip() (مكتشف LAN القوي).
    """
    local_ip = get_real_lan_ip()
    if local_ip.startswith("127."):
        local_ip = primary_ip()
    if local_ip.startswith("127.") or _is_apipa(local_ip) or not _is_routable_ipv4(local_ip):
        print("[DISCOVERY-DEBUG] No real LAN IP available; aborting subnet sweep.")
        return []

    prefix = local_ip.rsplit(".", 1)[0] + "."
    candidates = [
        f"{prefix}{i}"
        for i in range(1, 255)
        if f"{prefix}{i}" != local_ip
    ]
    print(f"[DISCOVERY-DEBUG] Real LAN IP: {local_ip} | Candidates: {len(candidates)} on {prefix}0/24")
    return candidates


def broadcast_targets():
    """عناوين البثّ: دائمًا 255.255.255.255 + البثّ الموجّه لكل واجهة نشطة."""
    targets = {"255.255.255.255"}
    for ip in get_all_active_local_ips():
        if _is_routable_ipv4(ip):
            try:
                net = ipaddress.IPv4Network(f"{ip}/24", strict=False)
                targets.add(str(net.broadcast_address))
            except Exception:
                try:
                    parts = str(ip).split(".")
                    parts[3] = "255"
                    targets.add(".".join(parts))
                except Exception:
                    pass
    return sorted(targets)


def get_local_ip():
    """عبر عكسية — عودة الواجهة الرئيسية (للتوافق مع استدعاءات قديمة)."""
    return primary_ip()


# ----------------------------------------------------------------
# بناء/تحليل الرد
# ----------------------------------------------------------------

def build_reply(host, port, store_name=""):
    payload = {
        "app": APP_SIGNATURE,
        "host": str(host or "127.0.0.1"),
        "port": int(port or 3306),
        "store_name": str(store_name or ""),
    }
    return json.dumps(payload).encode("utf-8")


def parse_reply(data):
    try:
        obj = json.loads(bytes(data).decode("utf-8"))
    except Exception:
        return None
    if isinstance(obj, dict) and obj.get("app") == APP_SIGNATURE:
        try:
            obj["host"] = str(obj.get("host") or "")
            obj["port"] = int(obj.get("port") or 3306)
            obj["store_name"] = str(obj.get("store_name") or "")
        except Exception:
            return None
        return obj
    return None


# ----------------------------------------------------------------
# المستجيب (الجهاز الرئيسي)
# ----------------------------------------------------------------

class DiscoveryResponder:
    """يستمع على DISCOVERY_PORT ويردّ بالبيانات الحيّة عبر payload_provider.

    ربط المقبس يتم بشكل متزامن داخل start() (قبل إطلاق خيط الاستقبال) فلا
    يوجد سباق إقلاع؛ ويعود start() بـ True فقط بعد نجاح الربط.
    stop() يغلق المقبس ويوقّف الخيط بنظافة (لا مقبس/خيط متبقٍّ).
    """

    def __init__(self, payload_provider, port=DISCOVERY_PORT):
        self._get_payload = payload_provider
        self._port = int(port or DISCOVERY_PORT)
        self._sock = None
        self.thread = None
        self.bound = False
        self.error = None
        self._stop_event = threading.Event()
        self._lock = threading.Lock()

    def start(self):
        with self._lock:
            if self.thread and self.thread.is_alive():
                return True
            self._stop_event.clear()
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("", self._port))
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                sock.settimeout(0.5)
            except Exception as exc:
                self.bound = False
                self.error = str(exc)
                try:
                    sock.close()
                except Exception:
                    pass
                return False
            self._sock = sock
            self.bound = True
            self.error = None
            self.thread = threading.Thread(
                target=self._loop, name="DiscoveryResponder", daemon=True)
            self.thread.start()
            return True

    def stop(self):
        with self._lock:
            self._stop_event.set()
            sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass
        t = self.thread
        if t and t.is_alive():
            t.join(timeout=1.0)

    def _loop(self):
        sock = self._sock
        if sock is None:
            return
        while not self._stop_event.is_set():
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if data and data.strip().startswith(DISCOVERY_REQUEST):
                try:
                    reply = self._get_payload() if callable(self._get_payload) else \
                        build_reply("127.0.0.1", 3306)
                    sock.sendto(reply, addr)
                except Exception:
                    pass
        try:
            sock.close()
        except Exception:
            pass


# ----------------------------------------------------------------
# الاكتشاف (الجهاز الإضافي)
# ----------------------------------------------------------------

def _is_client_reachable(host, port, connect_timeout=1.5):
    """فحص سريع ومقيّد: هل يمكن فتح اتصال TCP إلى منفذ الخادم؟"""
    if not host:
        return False
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(max(0.2, connect_timeout))
    try:
        s.connect((host, int(port or 3306)))
        return True
    except Exception:
        return False
    finally:
        try:
            s.close()
        except Exception:
            pass


def _udp_broadcast_scan(timeout, attempts, targets):
    """بثّ UDP إلى كل العناوين مع عدة محاولات، ويعيد أول ردّ صحيح فورًا.

    يبني مقبسًا واحدًا لكل دورة لتجنّب تسمّم مقبسٍ بمآخذ ICMP ، ويعيد
    (result, sock) حيث sock قد يكون مقبسًا مفتوحًا لا يزال يستمع (يُغلقه
    المتصل) — أو None عند انتهاء المهلة.
    """
    deadline = time.time() + max(0.5, float(timeout))
    attempt_interval = max(0.12, float(timeout) / max(1, int(attempts or 1)))
    next_send = 0.0

    sock = None

    def make_sock():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.settimeout(0.15)
            return s
        except Exception:
            return None

    sock = make_sock()
    try:
        while time.time() < deadline:
            now = time.time()
            if now >= next_send:
                for tgt in targets:
                    try:
                        if sock is not None:
                            sock.sendto(DISCOVERY_REQUEST, (tgt, DISCOVERY_PORT))
                    except ConnectionResetError:
                        try:
                            if sock is not None:
                                sock.close()
                        except Exception:
                            pass
                        sock = make_sock()
                        try:
                            if sock is not None:
                                sock.sendto(DISCOVERY_REQUEST, (tgt, DISCOVERY_PORT))
                        except Exception:
                            pass
                    except Exception:
                        pass
                next_send = now + attempt_interval

            remaining = deadline - time.time()
            if remaining <= 0:
                break
            if sock is not None:
                sock.settimeout(min(0.15, remaining))
                try:
                    data, _addr = sock.recvfrom(4096)
                except ConnectionResetError:
                    try:
                        sock.close()
                    except Exception:
                        pass
                    sock = make_sock()
                    continue
                except socket.timeout:
                    continue
                except Exception:
                    break
                parsed = parse_reply(data)
                if parsed:
                    return parsed, sock
    except Exception:
        pass
    return None, sock


def scan_subnet_tcp(port=None, timeout=0.5, max_workers=100, max_duration=7.0):
    """مسح TCP مباشر ومُوازٍ عبر الشبكة المحلية الفعلية.

    يفحص المنفذ المعطى على كل مرشّح /24 للشبكة الحقيقية عبر connect_ex
    بمهلة 0.5 ث وبـ 100 عاملًا. أول مضيف يفتح المنفذ نُعيده فورًا مع إلغاء
    المهام المتبقية.

    *max_duration* (ثوانٍ) مهلة إجمالية — عند انقضائها نتوقف حتى لو بقيت
    مرشّحات لم تُفحص، لنضمن عدم تخطّي discover_server لمدّتها.
    """
    port = int(port or DEFAULT_DISCOVERY_TCP_PORT)
    candidates = get_local_subnet_ips()
    if not candidates:
        return None

    print(f"[DISCOVERY-DEBUG] Starting direct TCP sweep on port {port} across {len(candidates)} hosts...")
    found_host = None
    overall_deadline = None
    if max_duration is not None:
        overall_deadline = time.time() + float(max_duration)

    def probe(host):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            if sock.connect_ex((host, port)) == 0:
                return host
        except Exception:
            pass
        finally:
            try:
                sock.close()
            except Exception:
                pass
        return None

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(probe, ip): ip for ip in candidates}
        for f in as_completed(futures):
            try:
                res = f.result()
            except Exception:
                res = None
            if res:
                found_host = res
                print(f"[DISCOVERY-DEBUG] >>> TARGET LOCATED: {found_host}:{port}")
                for pending in futures:
                    if not pending.done():
                        pending.cancel()
                break
            # مهلة إجمالية: لا ننتظر كل المرشّحات حتى النهاية إن تجاوزنا الحد.
            if overall_deadline is not None and time.time() >= overall_deadline:
                for pending in futures:
                    if not pending.done():
                        pending.cancel()
                break

    if found_host:
        return {
            "host": found_host,
            "port": port,
            "store_name": "Supermarket Pro",
        }
    return None


def discover_server(timeout=5.0, attempts=3, cached_host=None, cached_port=3306):
    """اكتشاف الجهاز الرئيسي — منطق مباشر ونظيف.

    خطوات:
      1) إن وُجد cached_host غير حلقي -> فحص TCP سريع (مهلة 1 ث).
      2) مسح TCP مباشر مُوازٍ على الشبكة المحلية الفعلية (منفذ 3306 فقط،
         بلا لمس قاعدة البيانات).
      3) إعادة محاولة بثّ UDP كخطة احتياطية إضافية.

    إرجاع: dict {'host','port','store_name'} أو None.
    """
    print(f"[DISCOVERY-DEBUG] discover_server called with timeout={timeout}")

    # ----- مسار عنوان IP المخزَّن (سريع) -----
    if cached_host and not str(cached_host).startswith("127."):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        try:
            if s.connect_ex((cached_host, int(cached_port or DEFAULT_DISCOVERY_TCP_PORT))) == 0:
                result = {
                    "host": cached_host,
                    "port": int(cached_port or DEFAULT_DISCOVERY_TCP_PORT),
                    "store_name": "",
                }
                print(f"[DISCOVERY-DEBUG] discover_server returning: {result}")
                return result
        except Exception:
            pass
        finally:
            try:
                s.close()
            except Exception:
                pass

    # ----- مسح TCP مباشر مُوازٍ على الشبكة المحلية الفعلية -----
    result = scan_subnet_tcp(port=DEFAULT_DISCOVERY_TCP_PORT,
                             timeout=0.5, max_workers=100,
                             max_duration=min(float(timeout), 6.0))
    print(f"[DISCOVERY-DEBUG] discover_server result: {result}")
    if result is not None:
        return result

    # ----- بثّ UDP احتياطي (تغطية شبكات تمنع البثّ الموجّه) -----
    try:
        targets = broadcast_targets()
    except Exception:
        targets = ["255.255.255.255"]
    udp_sock = None
    try:
        udp_result, udp_sock = _udp_broadcast_scan(
            max(0.8, float(timeout) * 0.4), max(1, attempts), targets)
        if udp_result:
            print(f"[DISCOVERY-DEBUG] discover_server returning: {udp_result}")
            return udp_result
    finally:
        if udp_sock is not None:
            try:
                udp_sock.close()
            except Exception:
                pass

    print(f"[DISCOVERY-DEBUG] discover_server returning: None")
    return None
