# FIC POS Mobile V1.11.1+41 - Build Fix

- Fix Dart type inference error in `lib/offline/offline_store.dart`.
- `_hashPassword()` now declares `List<int> bytes` explicitly so repeated `sha256.convert(...).bytes` assignments compile on current Dart/Flutter.
- No business/offline behavior changes from V1.11.0.
