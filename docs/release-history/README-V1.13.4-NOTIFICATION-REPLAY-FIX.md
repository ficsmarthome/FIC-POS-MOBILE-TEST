# FIC POS Mobile V1.13.4+59 — Notification Replay Fix

Based directly on V1.13.3+58 FAST ORDER.

## Fixes
- Prevents old `payment_request` notification events from replaying every time the app starts.
- The first successful event poll after startup is treated as a baseline even if the original `initial` poll ran before authentication was ready.
- Persists the latest event cursor in SharedPreferences, scoped by tenant host, user and branch when available.
- New payment request events after startup are still shown, vibrate/sound and open the existing payment request center exactly as before.
- No change to payment, offline sync, table sync or FAST ORDER flow.

## Version
`1.13.4+59`
