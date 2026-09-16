# FIC POS MOBILE V1.10.3+35

Fix QR order notifications:
- Android foreground: show real system notification for new QR order, with sound/vibration.
- Use fresh Android notification channels v1103 so sound/vibration settings are applied.
- Bell red badge includes pending QR orders.
- Notification Center also shows pending QR orders and opens QR queue on tap.
- Preserve existing 5-second polling and background foreground-service fallback.
