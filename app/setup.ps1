# Home Chat app - setup + build for Windows (PowerShell).
#
#   .\setup.ps1               install what's missing, then build the Windows app and the Android APK
#   .\setup.ps1 -Run          install what's missing, then run the app on this PC to try it
#   .\setup.ps1 -SkipAndroid  only build the Windows app
#   .\setup.ps1 -SkipWindows  only build the Android APK
#
# It installs (asking first): Git, the Flutter SDK, and optionally Visual Studio
# (C++ tools, for the Windows app) and Android Studio (for the APK).
param([switch]$Run, [switch]$SkipAndroid, [switch]$SkipWindows)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes downloads much faster in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-Location $PSScriptRoot

# ---------------------------------------------------------------- helpers
function Step($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" }
function Ok($m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    !   $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host ''; Write-Host "STOPPED: $m" -ForegroundColor Red; exit 1 }
function Ask($q)  { $a = Read-Host "    $q [Y/n]"; return ($a -eq '' -or $a -match '^[Yy]') }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-UserPath($dir) {
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $user) { $user = '' }
  if (($user -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', ($dir + ';' + $user).TrimEnd(';'), 'User')
    Info "Added $dir to your PATH (new terminals will find it too)."
  }
  if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

# Runs a command and stops with a clear message if it fails.
function Run-Native([string]$exe, [string[]]$argList) {
  & $exe @argList
  if ($LASTEXITCODE -ne 0) { Fail "'$exe $($argList -join ' ')' failed (exit code $LASTEXITCODE). Scroll up for the reason, or paste it to Claude." }
}

# ---------------------------------------------------------------- 1. Git
Step 'Checking Git (Flutter needs it)'
if (-not (Have 'git') -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $env:Path = "C:\Program Files\Git\cmd;$env:Path" }
if (-not (Have 'git')) {
  if ((Have 'winget') -and (Ask 'Git is not installed. Install it now?')) {
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (Test-Path 'C:\Program Files\Git\cmd\git.exe') { $env:Path = "C:\Program Files\Git\cmd;$env:Path" }
  }
  if (-not (Have 'git')) { Fail 'Install Git for Windows from https://git-scm.com/download/win, then run .\setup.ps1 again.' }
}
Ok (git --version)

# ---------------------------------------------------------------- 2. Flutter
Step 'Checking Flutter'
if (-not (Have 'flutter')) {
  $known = @("$env:USERPROFILE\develop\flutter\bin", "$env:USERPROFILE\flutter\bin", 'C:\flutter\bin', 'C:\src\flutter\bin',
             'C:\tools\flutter\bin', 'D:\flutter\bin', 'E:\flutter\bin', 'F:\flutter\bin')
  foreach ($dir in $known) {
    if (Test-Path "$dir\flutter.bat") { Info "Found Flutter in $dir"; Add-UserPath $dir; break }
  }
}
if (-not (Have 'flutter')) {
  $dest = "$env:USERPROFILE\develop"
  Info 'Flutter is not installed. It is a free download from Google, about 1 GB.'
  if (-not (Ask "Download and install Flutter into $dest\flutter now?")) {
    Fail 'Install Flutter yourself (https://docs.flutter.dev/get-started/install/windows), then run .\setup.ps1 again.'
  }
  $index = Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
  $stable = $index.current_release.stable
  $release = $index.releases | Where-Object { $_.hash -eq $stable -and $_.channel -eq 'stable' } | Select-Object -First 1
  if (-not $release) { Fail 'Could not find the latest Flutter version. Check your internet connection and try again.' }
  $url = "$($index.base_url)/$($release.archive)"
  $zip = Join-Path $env:TEMP (Split-Path $release.archive -Leaf)
  Info "Downloading Flutter $($release.version)... (this takes a while)"
  curl.exe -L --fail --retry 3 -o $zip $url
  if ($LASTEXITCODE -ne 0) { Fail "Download failed: $url" }
  Info 'Checking the download...'
  if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $release.sha256.ToLower()) {
    Remove-Item $zip -Force
    Fail 'The download was damaged (checksum mismatch). Run .\setup.ps1 again.'
  }
  Info 'Unpacking...'
  New-Item -ItemType Directory -Force $dest | Out-Null
  if (Test-Path "$dest\flutter") { Rename-Item "$dest\flutter" "flutter-old-$(Get-Date -Format yyyyMMddHHmmss)" }
  tar.exe -xf $zip -C $dest
  if ($LASTEXITCODE -ne 0) { Expand-Archive $zip -DestinationPath $dest -Force }
  Remove-Item $zip -Force
  Add-UserPath "$dest\flutter\bin"
  Info 'First start of Flutter (downloads its Dart tools)...'
  Run-Native 'flutter' @('--disable-analytics')
}
Run-Native 'flutter' @('--version')

# ---------------------------------------------------------------- 3. Windows prerequisites
Step 'Checking Windows settings'
# Flutter plugins need symbolic links: the project must be on an NTFS drive and Developer Mode must be on.
try {
  $letter = (Get-Item $PSScriptRoot).PSDrive.Name
  $fs = (Get-Volume -DriveLetter $letter -ErrorAction Stop).FileSystem
  if ($fs -and $fs -notin @('NTFS', 'ReFS')) {
    Fail "Drive ${letter}: uses $fs, which can't hold the links Flutter needs. Copy the messenger-chat-app folder to an NTFS drive (for example C:\apps\) and run setup.ps1 from there."
  }
  Ok "Drive ${letter}: is $fs"
} catch { Info 'Could not check the drive format (fine on most PCs).' }

function DevMode-On {
  $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
  return ($k -and $k.AllowDevelopmentWithoutDevLicense -eq 1)
}
if (-not (DevMode-On)) {
  Warn 'Windows "Developer Mode" is off. Flutter needs it to build apps with plugins.'
  Start-Process 'ms-settings:developers'
  Read-Host '    In the Settings window that just opened, switch ON "Developer Mode", then press Enter here'
  if (-not (DevMode-On)) { Fail 'Developer Mode is still off. Turn it on (Settings > System > For developers) and run .\setup.ps1 again.' }
}
Ok 'Developer Mode is on'

# ---------------------------------------------------------------- 4. Build tools (Windows app / Android)
$buildWindows = -not $SkipWindows
$buildAndroid = -not $SkipAndroid -and -not $Run

if ($buildWindows) {
  Step 'Checking Visual Studio C++ tools (for the Windows app)'
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $vcTools = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
  $atl = 'Microsoft.VisualStudio.Component.VC.ATL'
  function VS-Path([string[]]$components) {
    if (-not (Test-Path $vswhere)) { return $null }
    $p = & $vswhere -latest -products * -requires @components -property installationPath
    if ($p) { return ($p | Select-Object -First 1) }
    return $null
  }
  function Has-VS { return [bool](VS-Path @($vcTools, $atl)) }

  # C++ tools present but without ATL (the notifications plugin needs atlbase.h): add it.
  $vsNoAtl = VS-Path @($vcTools)
  if ($vsNoAtl -and -not (Has-VS)) {
    Info "Visual Studio is missing the 'C++ ATL' component that the notifications plugin needs."
    if (Ask 'Add it now? (Windows will ask for administrator permission)') {
      $installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
      Start-Process -FilePath $installer -Verb RunAs -Wait -ArgumentList @(
        'modify', '--installPath', "`"$vsNoAtl`"", '--add', $atl,
        '--passive', '--norestart')
    }
  }
  if (-not (Has-VS)) {
    Info 'Building the Windows app needs Visual Studio with "Desktop development with C++" (free, about 8 GB).'
    if ((Have 'winget') -and (Ask 'Install Visual Studio Community with the C++ tools now?')) {
      winget install --id Microsoft.VisualStudio.2022.Community -e --source winget --accept-package-agreements --accept-source-agreements `
        --override '--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended'
    }
    if (-not (Has-VS)) {
      Warn 'No Visual Studio C++ tools, so the Windows app will be skipped this time.'
      Warn 'In the Visual Studio Installer, tick "Desktop development with C++" and, under Individual components, "C++ ATL".'
      $buildWindows = $false
      if ($Run) { Fail 'Running on this PC needs the Visual Studio C++ tools.' }
    }
  }
  if ($buildWindows) { Ok 'Visual Studio C++ tools found' }
}

if ($buildAndroid) {
  Step 'Checking the Android SDK (for the phone app)'
  $sdk = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk") | Where-Object { $_ -and (Test-Path "$_\platform-tools") } | Select-Object -First 1
  if (-not $sdk) {
    $studio = Test-Path "$env:ProgramFiles\Android\Android Studio\bin\studio64.exe"
    if (-not $studio -and (Have 'winget') -and (Ask 'The Android SDK is missing. Install Android Studio now (about 1 GB)?')) {
      winget install --id Google.AndroidStudio -e --source winget --accept-package-agreements --accept-source-agreements
    }
    Warn 'Android APK skipped for now. To finish the Android setup (one time):'
    Warn '  1. Open Android Studio and click through the setup wizard (Standard). It downloads the Android SDK.'
    Warn '  2. In Android Studio: More Actions > SDK Manager > SDK Tools tab > tick "Android SDK Command-line Tools" > OK.'
    Warn '  3. Run .\setup.ps1 again.'
    $buildAndroid = $false
  } else {
    Ok "Android SDK found in $sdk"
    if (-not (Test-Path "$sdk\cmdline-tools")) {
      Warn 'Android "SDK Command-line Tools" are missing. In Android Studio: SDK Manager > SDK Tools > tick'
      Warn '"Android SDK Command-line Tools" > OK, then run .\setup.ps1 again. Skipping the APK for now.'
      $buildAndroid = $false
    } else {
      & flutter config --android-sdk $sdk | Out-Null
      Info 'Accepting the Android SDK licenses...'
      ("y`n" * 30) | flutter doctor --android-licenses | Out-Null
    }
  }
}

# ---------------------------------------------------------------- 5. Project setup
Step 'Preparing the project (keeps our files)'
$platforms = @()
if (-not $SkipAndroid) { $platforms += 'android' }
if (-not $SkipWindows) { $platforms += 'windows' }
Run-Native 'flutter' @('create', '--org', 'net.homechat', '--project-name', 'homechat', '--platforms', ($platforms -join ','), '.')

# Android release signing key: every version must be signed with the SAME key,
# or phones refuse to install the update. Made once, then reused forever.
if ($buildAndroid -and -not (Test-Path 'android\key.properties')) {
  Step 'Creating the Android signing key (one time)'
  $keytool = @("$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe", "$env:JAVA_HOME\bin\keytool.exe") |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $keytool -and (Have 'keytool')) { $keytool = 'keytool' }
  if (-not $keytool) {
    Warn 'keytool (comes with Android Studio) not found, so the APK will use a temporary debug key.'
  } else {
    $pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    & $keytool -genkeypair -keystore 'android\app\homechat-release.jks' -storetype PKCS12 -alias homechat `
      -keyalg RSA -keysize 2048 -validity 10000 -storepass $pw -keypass $pw -dname 'CN=Home Chat' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Could not create the signing key.' }
    Set-Content 'android\key.properties' "storePassword=$pw`nkeyPassword=$pw`nkeyAlias=homechat`nstoreFile=homechat-release.jks" -Encoding ascii
    Ok 'Signing key created: app\android\app\homechat-release.jks'
    Warn 'BACK UP these two files somewhere safe (not in Git): app\android\key.properties and app\android\app\homechat-release.jks'
    Warn 'Then give them to GitHub once: .\tool\github-secrets.ps1 -Repo <you>/<repo>'
  }
}

Run-Native 'dart' @('run', 'tool/patch_platforms.dart')
Run-Native 'flutter' @('pub', 'get')

Step 'Running tests (checks the encryption is right)'
Run-Native 'flutter' @('test')

if ($Run) {
  Step 'Starting Home Chat on this PC'
  Run-Native 'flutter' @('run', '-d', 'windows')
  exit
}

# ---------------------------------------------------------------- 6. Build
$built = @()
if ($buildWindows) {
  Step 'Building the Windows app'
  Run-Native 'flutter' @('build', 'windows', '--release')
  $built += '  Windows app : app\build\windows\x64\runner\Release\homechat.exe  (copy the whole Release folder)'
}
if ($buildAndroid) {
  Step 'Building the Android APK'
  Run-Native 'flutter' @('build', 'apk', '--release')
  $built += '  Android APK : app\build\app\outputs\flutter-apk\app-release.apk  (send to phones and install)'
}

Write-Host ''
if ($built.Count -eq 0) {
  Warn 'Nothing was built yet. Follow the steps above, then run .\setup.ps1 again.'
} else {
  Write-Host 'Done!' -ForegroundColor Green
  $built | ForEach-Object { Write-Host $_ }
}
