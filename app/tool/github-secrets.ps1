# Uploads the Android signing key to your GitHub repo as Actions secrets,
# so the release workflow signs every APK with the same key.
# Needs the GitHub CLI (winget install GitHub.cli) and `gh auth login` once.
#   .\tool\github-secrets.ps1 -Repo yourname/messenger-chat-app
param([Parameter(Mandatory = $true)][string]$Repo)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$props = 'android\key.properties'
$jks = 'android\app\homechat-release.jks'
if (-not (Test-Path $props) -or -not (Test-Path $jks)) {
  Write-Host 'No signing key yet. Run .\setup.ps1 first (it creates one when building the Android app).' -ForegroundColor Red
  exit 1
}
$password = ((Get-Content $props | Where-Object { $_ -like 'storePassword=*' }) -split '=', 2)[1]
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $jks)))

$b64 | gh secret set ANDROID_KEYSTORE_BASE64 --repo $Repo
$password | gh secret set ANDROID_KEYSTORE_PASSWORD --repo $Repo
Write-Host "Secrets set on $Repo." -ForegroundColor Green
