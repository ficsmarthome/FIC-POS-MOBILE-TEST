$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$customBuild = Get-Content "android/app/build.gradle.kts" -Raw
$customManifest = Get-Content "android/app/src/main/AndroidManifest.xml" -Raw
$customGradleProperties = Get-Content "android/gradle.properties" -Raw

flutter create --platforms=android .

Set-Content "android/app/build.gradle.kts" $customBuild -NoNewline
Set-Content "android/app/src/main/AndroidManifest.xml" $customManifest -NoNewline
Set-Content "android/gradle.properties" $customGradleProperties -NoNewline

$firebaseSource = "firebase/google-services.json"
if (Test-Path $firebaseSource) {
    Copy-Item $firebaseSource "android/app/google-services.json" -Force

    $settingsPath = "android/settings.gradle.kts"
    $settings = Get-Content $settingsPath -Raw
    if ($settings -notmatch 'com.google.gms.google-services') {
        $settings = $settings.Replace("plugins {", "plugins {`r`n    id(`"com.google.gms.google-services`") version `"4.4.3`" apply false")
        Set-Content $settingsPath $settings -NoNewline
    }

    $appBuildPath = "android/app/build.gradle.kts"
    $appBuild = Get-Content $appBuildPath -Raw
    if ($appBuild -notmatch 'id\("com.google.gms.google-services"\)') {
        $appBuild = $appBuild.Replace("plugins {", "plugins {`r`n    id(`"com.google.gms.google-services`")")
        Set-Content $appBuildPath $appBuild -NoNewline
    }
    Write-Host "FIC Firebase Android config applied."
} else {
    Write-Host "FIC Firebase: firebase/google-services.json not found. App still builds, but killed-app push is disabled until Firebase is configured."
}

Write-Host "FIC Android scaffold ready. Run: flutter clean; flutter pub get; flutter analyze"
