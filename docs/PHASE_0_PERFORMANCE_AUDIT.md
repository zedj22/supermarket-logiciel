# Phase 0 — Performance Audit

| Priority | Observed path | Impact | Target remedy |
|---|---|---|---|
| High | `get_all_products`/POS rendering loads catalog then renders widgets | catalog scale and search lag | indexed server search, cursor pagination, debounced input, virtualized list |
| High | `MainWindow` rebuilds/destroys cart/product widgets | UI stalls for large carts | granular Riverpod state/list diffs |
| High | reports run multiple date-range queries; category profit has expensive composition | slow reports | query plans/composite indexes, daily aggregates only when measured |
| High | transactional services perform item-by-item checks | N+1/long locks | batch lookup and deterministic row locking |
| Medium | image opens/resizes on product display | slow grid and memory churn | generated thumbnails, lazy decode/cache |
| Medium | TCP subnet scan up to /24 / high worker count | noisy 1–seconds network load | cached known server then signed UDP/mDNS-style discovery; bounded backoff |
| Medium | manual connection lifecycles/repeated acquisitions | avoidable latency/leaks | SQLAlchemy pool/request session |
| Medium | PDF/XLSX work runs from UI path | frozen desktop | backend job worker with progress/cancel |
| Low | translation lookups/manual formatting | maintenance more than latency | generated catalogs/locale formatting |

Target SLOs: POS lookup p95 <100ms on indexed local LAN data; first product page <200ms; sale command <500ms excluding printing; dashboard/report daily <2s; navigation interaction <100ms; receipt job begins <3s; export <5s for agreed data size. Measure fixtures at 1k/10k/100k products and concurrent tills; do not introduce materialized views/caches until profiles show need.
