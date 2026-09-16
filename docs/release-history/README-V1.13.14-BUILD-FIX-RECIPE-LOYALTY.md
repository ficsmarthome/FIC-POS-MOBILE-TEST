# FIC POS Mobile V1.13.14 — Build Fix Recipe + Loyalty

- Fix Dart syntax at `Thành viên & tích điểm` build block: remove one extra closing parenthesis before `RefreshIndicator`.
- Fix Dart syntax at `Công thức` build block: add the missing closing parenthesis for `Center > Padding > Column` before `RefreshIndicator`.
- No business logic changes to offline order, FAST ORDER, promotion, payment sync, table live total, license, or tenant logic.
- Version: `1.13.14+68`.

Validation in packaging environment:
- ZIP structure keeps project files at ZIP root.
- Archive integrity checked.
- Flutter SDK is not available in the packaging environment, so this package has not been compiled here. Run `flutter run -d emulator-5554` on the development machine to verify Android compilation.
