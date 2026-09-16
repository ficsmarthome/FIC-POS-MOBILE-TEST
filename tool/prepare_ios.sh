#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.ficpos.app.test"
INFO_PLIST="ios/Runner/Info.plist"

if [ ! -d ios ] || [ ! -f "$INFO_PLIST" ]; then
  echo "[FIC] ios/ missing -> generating once"
  flutter create --platforms=ios --org com.ficpos .
else
  echo "[FIC] using committed ios/ project"
fi

# Force the exact App Store bundle identifier and entitlements path.
ruby <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target not found' unless target
target.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ficpos.app.test'
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end
project.save
RUBY

# Display name.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName FIC POS TEST" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'FIC POS TEST'" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName FIC POS TEST" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'FIC POS TEST'" "$INFO_PLIST"

# Apple privacy purpose strings required by App Store validation 90683.
MIC_TEXT="FIC POS có thể sử dụng micro để hỗ trợ các tính năng nhập liệu và thao tác bằng giọng nói khi người dùng sử dụng chức năng có liên quan."
SPEECH_TEXT="FIC POS có thể sử dụng nhận dạng giọng nói để chuyển giọng nói thành nội dung nhập liệu khi người dùng sử dụng chức năng có liên quan."
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription $MIC_TEXT" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string '$MIC_TEXT'" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSSpeechRecognitionUsageDescription $SPEECH_TEXT" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string '$SPEECH_TEXT'" "$INFO_PLIST"

LOCAL_NET_TEXT="FIC POS cần truy cập mạng nội bộ để kết nối trực tiếp máy in LAN/IP trong cùng cửa hàng."
/usr/libexec/PlistBuddy -c "Set :NSLocalNetworkUsageDescription $LOCAL_NET_TEXT" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string '$LOCAL_NET_TEXT'" "$INFO_PLIST"

# Remote notification background mode.
/usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes" "$INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string remote-notification" "$INFO_PLIST"

# Optional Firebase config supplied by local file or Codemagic base64 env.
mkdir -p firebase
if [ -n "${FIC_IOS_GOOGLE_SERVICE_INFO_B64:-}" ]; then
  printf '%s' "$FIC_IOS_GOOGLE_SERVICE_INFO_B64" | base64 --decode > firebase/GoogleService-Info.plist
fi

if [ -f firebase/GoogleService-Info.plist ]; then
  # Fail early if the Firebase plist secret is malformed.
  plutil -lint firebase/GoogleService-Info.plist
  cp firebase/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist

  ruby <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target not found' unless target
group = project.main_group.find_subpath('Runner', true)
ref = group.files.find { |f| f.path == 'GoogleService-Info.plist' } || group.new_file('GoogleService-Info.plist')
unless target.resources_build_phase.files_references.include?(ref)
  target.resources_build_phase.add_file_reference(ref, true)
end
project.save
RUBY
  echo "[FIC] Firebase iOS config applied"
else
  echo "[FIC] Firebase iOS config missing. Preview build is allowed, but real APNs/FCM push needs the config."
fi

# Push capability entitlement. Production signing profile must include Push Notifications.
cat > ios/Runner/Runner.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>aps-environment</key>
  <string>production</string>
</dict>
</plist>
PLIST

# Generate launcher icons after iOS exists.
dart run flutter_launcher_icons

# Final sanity checks.
test -f ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json
plutil -lint "$INFO_PLIST"
plutil -lint ios/Runner/Runner.entitlements
/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Print :NSSpeechRecognitionUsageDescription" "$INFO_PLIST"

echo "[FIC] iOS project prepared: bundle=$BUNDLE_ID"
