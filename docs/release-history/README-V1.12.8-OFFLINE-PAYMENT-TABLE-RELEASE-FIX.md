# FIC POS Mobile V1.12.8+53 — Offline Payment Table Release Fix

## Fix
- After a successful offline payment, the local table is released immediately instead of continuing to show **Đang sử dụng** from stale cached bootstrap data.
- The release is persisted locally, so returning to the table list (or restarting the app while still offline) keeps the paid table as **Còn trống**.
- If the table still has another unpaid offline order, it remains **Đang sử dụng**.
- Creating/updating a new unpaid offline order clears the local-free override and makes the table busy again.
- Once the paid invoice is confirmed by the server, the temporary local-free override is cleared and server table state becomes authoritative again.

## Platforms
- Android
- iOS

No Web/API change is required for this fix. Compatible with Web V255.13.
