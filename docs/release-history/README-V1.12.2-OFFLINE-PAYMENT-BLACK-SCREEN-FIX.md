# FIC POS Mobile V1.12.2+47

## Offline payment black-screen fix

- Fixes a navigation issue where tapping **Xong** after an offline payment could leave the app on a black screen.
- The offline invoice is still finalized locally and queued for sync exactly as in V1.12.1.
- After the success dialog closes, the current table/order screen is reset to an empty local state instead of automatically popping the route.
- The table is considered released locally and the user can press Back to return to the room/table list or immediately create a new order.
- Applies to the shared Flutter source used by both Android and iOS.

No backend change is required for this fix.
