# FIC POS Mobile V1.13.34+92 — Trial Banner

## Added
- Compact Trial banner on the Home screen when the verified entitlement says `license_type=trial` and `trial.active=true`.
- Displays Platform-provided `trial.days_remaining` and `trial.expires_at`. The app does not calculate a competing Trial deadline.
- `Nâng cấp ngay` opens `trial.upgrade_url` from Platform.
- Online `/me` data remains authoritative; cached `/me` is used only by the existing offline flow.

## Preserved
- Existing offline mode and queue/sync behavior.
- Notification center, payment-request badges, push/APNs behavior, and Build 91 features.
- No second license/expiry enforcement was added to Mobile. Existing entitlement/license enforcement remains authoritative.

## Backend requirement
- FIC POS Web V255.51 exposes the existing verified Platform entitlement in `/api/mobile/v1/me`.

## Version
- 1.13.34+92
