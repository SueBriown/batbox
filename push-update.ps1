 $zip = "$env:USERPROFILE\Downloads\batbox-fixed.zip"
 $proj = "C:\Users\silve\Documents\code\flutter\batbox"
 $temp = "$env:TEMP\batbox-new"

Expand-Archive -Path $zip -DestinationPath $temp -Force
Copy-Item "$temp\lib\main.dart" "$proj\lib\main.dart" -Force
Copy-Item "$temp\pubspec.yaml" "$proj\pubspec.yaml" -Force -ErrorAction SilentlyContinue
Copy-Item "$temp\android\build.gradle.kts" "$proj\android\build.gradle.kts" -Force -ErrorAction SilentlyContinue
Copy-Item "$temp\android\app\src\main\AndroidManifest.xml" "$proj\android\app\src\main\AndroidManifest.xml" -Force -ErrorAction SilentlyContinue
if (Test-Path "$temp\.github") { Copy-Item "$temp\.github" "$proj\.github" -Recurse -Force }

Set-Location $proj
git add .
git commit -m "Update from z.ai $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git push

Write-Host "Build starting at: https://github.com/YOUR_USERNAME/batbox/actions" -ForegroundColor Green