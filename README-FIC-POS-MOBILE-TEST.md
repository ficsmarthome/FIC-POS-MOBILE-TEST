# FIC POS Mobile TEST — V1.14.0+93

Base: FIC-POS-MOBILE-V1.14.0+93 TEN-FUNCTION bundle.

## TEST isolation
- API login host: `https://{slug}.test.ficpos.com`
- TLS certificate bypass is enabled **only** for `test.ficpos.com` and `*.test.ficpos.com`.
- Production `*.ficpos.com` is not bypassed.
- Android applicationId: `com.ficpos.app.test`
- Android label: `FIC POS TEST`
- iOS bundle id: `com.ficpos.app.test`
- iOS display name: `FIC POS TEST`
- Can be installed separately from Production when signing/provisioning supports the TEST bundle id.

## iOS
The repository intentionally does not commit an `ios/` directory. On macOS/Codemagic, `tool/prepare_ios.sh` generates it and applies the TEST bundle id, privacy strings, local-network description and push entitlement. Preview and Simulator workflows can build without App Store signing. A signed device/TestFlight IPA requires an Apple App ID/provisioning profile for `com.ficpos.app.test`.

## Warning
This build deliberately accepts an untrusted TLS certificate for TEST hosts. Do not publish this TEST build as the Production App Store / Google Play application.
