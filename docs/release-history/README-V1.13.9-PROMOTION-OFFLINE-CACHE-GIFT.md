# FIC POS Mobile V1.13.9+63

- Built forward from V1.13.8 promotion baseline (which itself was rebuilt from reverted V1.13.7 navigation baseline).
- Promotion snapshot is cached independently per server + branch in local SQLite KV storage.
- App start/login downloads promotions; sync-version compares `promotion_version`; changed rules refresh only the promotion section.
- Offline order promotion evaluation uses the cached snapshot and the individual order's own creation time.
- Open invoices remain locked and are not recalculated.
- Android/iOS table cards show 🎁 beside total when any open order on that table has a promotion/gift.
- Pending offline orders persist their promotion preview so 🎁 remains visible without Internet.
