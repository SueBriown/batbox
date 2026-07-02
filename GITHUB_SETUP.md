# BatBox — GitHub + GitHub Actions build workflow

## One-time setup

### 1. Create a GitHub repo

1. Go to https://github.com/new
2. Name it `batbox` (or whatever you like)
3. Set to **Private** (recommended — your code)
4. **Don't** initialize with README (we'll push existing code)
5. Click **Create repository**

### 2. Push your project to GitHub

Open PowerShell in your batbox folder and run:

```powershell
cd C:\Users\silve\Documents\code\flutter\batbox

# Initialize git (if not already)
git init
git branch -M main

# Add all files
git add .

# First commit
git commit -m "Initial commit"

# Add your remote (replace YOUR_USERNAME)
git remote add origin https://github.com/YOUR_USERNAME/batbox.git

# Push
git push -u origin main
```

If you haven't authenticated git with GitHub, it will prompt you. Use a Personal Access Token (GitHub → Settings → Developer settings → Personal access tokens → Generate new token with `repo` scope).

### 3. Enable GitHub Actions

- Go to your repo on GitHub
- Click the **Actions** tab
- If prompted, click "I understand my workflows, go ahead and enable them"
- The workflow file `.github/workflows/build-apk.yml` will be auto-detected

### 4. (Optional) Install GitHub CLI for easier auth

```powershell
winget install GitHub.cli
gh auth login
```

This makes future pushes not require password entry.

---

## Daily workflow (3 steps)

### Step 1: Describe the change to z.ai

Just tell me what you want changed. I edit the code in this environment.

### Step 2: Download + push to GitHub

After z.ai gives you the updated zip, run this ONE command:

```powershell
# Extract the new code over your local copy
Expand-Archive -Path "$env:USERPROFILE\Downloads\batbox-fixed.zip" -DestinationPath "$env:TEMP\batbox-new" -Force

# Copy the changed files (main.dart, pubspec.yaml, etc.)
Copy-Item "$env:TEMP\batbox-new\lib\main.dart" "C:\Users\silve\Documents\code\flutter\batbox\lib\main.dart" -Force
Copy-Item "$env:TEMP\batbox-new\pubspec.yaml" "C:\Users\silve\Documents\code\flutter\batbox\pubspec.yaml" -Force -ErrorAction SilentlyContinue
Copy-Item "$env:TEMP\batbox-new\android\build.gradle.kts" "C:\Users\silve\Documents\code\flutter\batbox\android\build.gradle.kts" -Force -ErrorAction SilentlyContinue
Copy-Item "$env:TEMP\batbox-new\android\app\src\main\AndroidManifest.xml" "C:\Users\silve\Documents\code\flutter\batbox\android\app\src\main\AndroidManifest.xml" -Force -ErrorAction SilentlyContinue

# Commit and push
cd C:\Users\silve\Documents\code\flutter\batbox
git add .
git commit -m "Update from z.ai"
git push
```

**Pro tip:** Save the above as `push-update.ps1` on your desktop. Then you just double-click it (or run `.\push-update.ps1`) after downloading a new zip.

### Step 3: Download the APK

1. Go to https://github.com/YOUR_USERNAME/batbox/actions
2. Wait for the latest build to finish (~10-15 min)
3. Click on the build
4. Scroll down to **Artifacts** → click `batbox-apk`
5. It downloads a ZIP containing `app-release.apk`
6. Extract and `adb install -r app-release.apk` (or copy to phone and tap to install)

---

## Make it even smoother: one-click push script

Create this file as `C:\Users\silve\Documents\code\flutter\batbox\push-update.ps1`:

```powershell
# push-update.ps1 — run after downloading a new batbox-fixed.zip
$zip = "$env:USERPROFILE\Downloads\batbox-fixed.zip"
$proj = "C:\Users\silve\Documents\code\flutter\batbox"
$temp = "$env:TEMP\batbox-new"

Write-Host "Extracting..." -ForegroundColor Cyan
Expand-Archive -Path $zip -DestinationPath $temp -Force

Write-Host "Copying files..." -ForegroundColor Cyan
Copy-Item "$temp\lib\main.dart" "$proj\lib\main.dart" -Force
Copy-Item "$temp\pubspec.yaml" "$proj\pubspec.yaml" -Force -ErrorAction SilentlyContinue
Copy-Item "$temp\android\build.gradle.kts" "$proj\android\build.gradle.kts" -Force -ErrorAction SilentlyContinue
Copy-Item "$temp\android\app\src\main\AndroidManifest.xml" "$proj\android\app\src\main\AndroidManifest.xml" -Force -ErrorAction SilentlyContinue
# Copy any other changed files...
if (Test-Path "$temp\.github") { Copy-Item "$temp\.github" "$proj\.github" -Recurse -Force }

Write-Host "Committing and pushing..." -ForegroundColor Cyan
Set-Location $proj
git add .
git commit -m "Update from z.ai $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git push

Write-Host ""
Write-Host "Done! Build starting at: https://github.com/YOUR_USERNAME/batbox/actions" -ForegroundColor Green
Write-Host "Download APK from the Actions tab in ~10-15 minutes." -ForegroundColor Green
```

Then your workflow is literally:
1. Tell z.ai what to change
2. Download the zip
3. Run `.\push-update.ps1`
4. Wait for the GitHub Actions build, download APK

---

## Alternative: use git directly from z.ai's environment

If you give z.ai your GitHub credentials (or a Personal Access Token), z.ai can push directly to your repo — then you don't even need to download/extract/copy. The flow becomes:

1. Tell z.ai what to change
2. z.ai commits and pushes
3. GitHub Actions builds
4. Download APK

This requires you to paste a GitHub Personal Access Token into the chat, which has security implications. The PowerShell script approach above is safer (you control the push).

---

## Build status badge

Add this to your repo's README.md to see build status at a glance:

```markdown
![Build Status](https://github.com/YOUR_USERNAME/batbox/actions/workflows/build-apk.yml/badge.svg)
```

---

## Cost

- **GitHub Free:** 2000 build minutes/month for private repos, unlimited for public
- Each build ~10-15 min, so you get ~130+ builds/month for free
- No credit card needed

## What's in the workflow file

The `.github/workflows/build-apk.yml` I created:
- Triggers on every push to main/master
- Sets up JDK 17 + Flutter stable
- Runs `flutter pub get` + `flutter build apk --release`
- Uploads the APK as an artifact (kept for 30 days)
- Shows build info in the Actions summary

The `subosito/flutter-action@v2` with `cache: true` caches the Flutter SDK and pub packages, so subsequent builds are faster (~8-10 min instead of 15).
