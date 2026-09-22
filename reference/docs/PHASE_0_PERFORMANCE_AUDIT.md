# PHASE 0 — Performance Audit

## Identified Bottlenecks

### 1. Database Connection Per Query (HIGH)
**Location**: `db_manager.py` — all methods
- Each database operation opens a new connection via `get_connection()`
- Connection pool exists but connections are returned to pool immediately after each operation
- No connection reuse within a transaction or batch operation

**Impact**: ~20ms overhead per query due to connection acquisition
**Recommendation**: Use connection context managers, reuse connections within transactions

### 2. Full Product List Load (HIGH)
**Location**: `products.py:28-40`, `main_window.py` POS rendering
- `get_all_products()` loads ALL products with no pagination
- POS renders up to 40 products at a time but loads all into memory
- Product search re-queries the full list

**Impact**: Slow product search as catalog grows
**Recommendation**: Server-side pagination, indexed search, lazy loading

### 3. Repeated Product Queries (MEDIUM)
**Location**: `main_window.py` POS
- Product data queried on every search keystroke (debounced but still repeated)
- Product list re-rendered on every filter change
- Favorites re-queried on every POS open

**Impact**: Unnecessary database load during POS operation
**Recommendation**: Cache product list in memory, invalidate on changes

### 4. Report Generation Queries (MEDIUM)
**Location**: `db_manager.py` report methods
- Financial report executes 6+ separate queries
- Each query scans large date ranges
- No query result caching
- `get_profit_by_category` uses correlated subquery

**Impact**: Reports take 1-5 seconds depending on data volume
**Recommendation**: Pre-aggregate daily summaries, use materialized views

### 5. Image Loading (MEDIUM)
**Location**: `main_window.py:7661-7703`
- Images loaded from file system on every product display
- No thumbnail generation
- PIL Image opened and resized for each display
- `_image_cache` exists but limited to current session

**Impact**: Slow product grid rendering with images
**Recommendation: Generate thumbnails, use efficient caching, lazy load images

### 6. Network Discovery Scan (LOW-MEDIUM)
**Location**: `network_discovery.py`
- TCP scan of entire /24 subnet (254 hosts)
- Uses ThreadPoolExecutor with 100 workers
- Each connection has 1-second timeout
- Up to 3 scan attempts

**Impact**: 1-3 seconds on startup for client discovery
**Recommendation**: Cache last known server IP, reduce scan范围

### 7. Translation Dictionary (LOW)
**Location**: `main_window.py:183-667`
- ~500 translation keys stored as Python dict in class variable
- Every `t()` call does a dict lookup
- No caching of translated strings

**Impact**: Minimal per-call but unnecessary memory usage
**Recommendation**: Use proper i18n library, cache translations

### 8. Cart Recalculation (LOW)
**Location**: `main_window.py:10184-10270`
- Entire cart re-rendered on every change
- All cart item widgets destroyed and recreated
- No differential updates

**Impact**: Noticeable UI lag with large carts
**Recommendation**: Update only changed items, use efficient list rendering

### 9. Sales History Query (LOW)
**Location**: `db_manager.py:977-1012`
- `get_invoices_history` loads all invoices with no limit enforcement
- LEFT JOIN with customers on every query
- No indexing on sale_date for date range queries

**Impact**: Slow invoice history loading
**Recommendation**: Add composite index, enforce pagination

### 10. Variant/Stock Checks (LOW)
**Location**: `sales.py` create_invoice
- Each item requires separate stock check query
- Pack sales require N+1 queries for component validation
- No batch stock validation

**Impact**: Linear scaling with cart size
**Recommendation**: Batch stock validation, single query for all items

## Performance Requirements for New System

| Metric | Target | Notes |
|--------|--------|-------|
| POS search response | <100ms | Indexed search with pagination |
| Product list load | <200ms | First 50 products |
| Sale completion | <500ms | Full transaction |
| Report generation | <2s | Daily reports |
| Page navigation | <100ms | No full rebuilds |
| Image load | <50ms | Cached thumbnails |
| Connection acquisition | <10ms | Connection pool |
| LAN discovery | <3s | Server discovery |
| Print invoice | <3s | PDF generation |
| Export report | <5s | Excel/CSV |

## Optimization Strategy

1. **Backend**: Async FastAPI, connection pooling, query optimization
2. **Database**: Proper indexing, pagination, materialized views for reports
3. **Frontend**: Efficient state management, lazy loading, caching
4. **Network**: HTTP/2, connection keep-alive, response compression
5. **Images**: Thumbnail generation, lazy loading, CDN for large catalogs
