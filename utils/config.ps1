# Скрипт создания полного VPN на основе выбранного шаблона маскировки и Xbox-DNS
$ErrorActionPreference = "Stop"

# Автоматическое определение папки скрипта
$utilsDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($utilsDir)) { 
    $utilsDir = Get-Location
}

# Корневая папка (на один уровень выше папки utils)
$RootDir = Split-Path -Path $utilsDir -Parent
if ([string]::IsNullOrEmpty($RootDir)) {
    $RootDir = ".."
}

Set-Location $utilsDir

Write-Host "[*] Шаг 1: Получение списка доступных шаблонов маскировки..." -ForegroundColor Cyan

# Ищем все файлы .conf в папке utils, исключая служебные файлы wgcf
$templates = Get-ChildItem -Path $utilsDir -Filter "*.conf" | Where-Object { 
    $_.Name -notlike "wgcf-profile.conf" -and $_.Name -notlike "AmneziaWG_WARP.conf" -and $_.Name -notlike "AmneziaWG_Split.conf"
} | Sort-Object Name

if ($templates.Count -eq 0) {
    Write-Host "[-] Ошибка: Шаблоны маскировки (.conf) в папке utils не найдены!" -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host "       ВЫБОР ШАБЛОНА МАСКИРОВКИ (ОБХОДА БЛОКИРОВОК)" -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Yellow

for ($i = 0; $i -lt $templates.Count; $i++) {
    $note = ""
    if ($templates[$i].Name -like "*v3_33*") { $note = " - (Имитация SIP-телефонии)" }
    if ($templates[$i].Name -like "*v2_28*") { $note = " - (Hex-мусор / Запутывание DPI)" }
    Write-Host "[$($i + 1)] $($templates[$i].Name)$note" -ForegroundColor Gray
}
Write-Host ""

$selection = Read-Host "Введите номер шаблона [1-$($templates.Count)] (по умолчанию 1)"
if ([string]::IsNullOrWhiteSpace($selection)) { $selection = 1 }
$selectedIndex = [int]$selection - 1

if ($selectedIndex -lt 0 -or $selectedIndex -ge $templates.Count) {
    Write-Host "[!] Неверный выбор. Берем первый шаблон по умолчанию." -ForegroundColor Yellow
    $selectedIndex = 0
}

$templateFile = $templates[$selectedIndex]
Write-Host "[+] Выбран шаблон: $($templateFile.Name)" -ForegroundColor Green

Write-Host ""
Write-Host "[*] Шаг 2: Сбор сессии из official WARP..." -ForegroundColor Cyan
if (!(Get-Command "warp-cli" -ErrorAction SilentlyContinue)) {
    Write-Host "[-] Ошибка: Клиент WARP не найден." -ForegroundColor Red
    exit
}
$warpAccount = & warp-cli registration show 2>$null
if (!$warpAccount) { $warpAccount = & warp-cli account 2>$null }
$devMatch = $warpAccount | Select-String -Pattern "(Device ID|Registration ID|ID):\s*(.+)"
$deviceId = if ($devMatch.Matches.Count -gt 0) { $devMatch.Matches[0].Groups[2].Value.Trim() } else { $null }
$licMatch = $warpAccount | Select-String -Pattern "License Key:\s*(.+)"
$licenseKey = if ($licMatch.Matches.Count -gt 0) { $licMatch.Matches[0].Groups[1].Value.Trim() } else { $null }

if (!$deviceId) { Write-Host "[-] Не удалось получить Device ID." -ForegroundColor Red; exit }

Write-Host ""
Write-Host "[*] Шаг 3: Генерация официальных ключей через WGCF..." -ForegroundColor Cyan
$url = "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_windows_amd64.exe" 
if (!(Test-Path "wgcf.exe")) {
    try { (New-Object System.Net.WebClient).DownloadFile($url, (Join-Path $utilsDir "wgcf.exe")) } catch { curl.exe -L -A "Mozilla/5.0" -o "wgcf.exe" $url }
}
if (Test-Path "wgcf-account.toml") { Remove-Item "wgcf-account.toml" -Force }
& .\wgcf.exe register --accept-tos | Out-Null
$tomlContent = Get-Content "wgcf-account.toml" -Raw
$tomlContent = $tomlContent -replace 'device_id = ".*"', "device_id = `"$deviceId`""
if ($licenseKey) { $tomlContent = $tomlContent -replace 'license_key = ".*"', "license_key = `"$licenseKey`"" }
Set-Content -Path "wgcf-account.toml" -Value $tomlContent
& .\wgcf.exe update | Out-Null
if (Test-Path "wgcf-profile.conf") { Remove-Item "wgcf-profile.conf" -Force }
& .\wgcf.exe generate | Out-Null

Write-Host ""
Write-Host "[*] Шаг 4: Скрещивание маскировки и интеграция Xbox-DNS..." -ForegroundColor Cyan
$rawConf = Get-Content "wgcf-profile.conf" -Raw
$newPrivateKey = ($rawConf | Select-String -Pattern "PrivateKey\s*=\s*(.+)").Matches[0].Groups[1].Value.Trim()
$newAddress = ($rawConf | Select-String -Pattern "Address\s*=\s*(.+)").Matches[0].Groups[1].Value.Trim()
$newPublicKey = ($rawConf | Select-String -Pattern "PublicKey\s*=\s*(.+)").Matches[0].Groups[1].Value.Trim()

$templateContent = Get-Content $templateFile.FullName -Raw
$templateContent = $templateContent -replace '(?m)^PrivateKey\s*=.*$', "PrivateKey = $newPrivateKey"
$templateContent = $templateContent -replace '(?m)^Address\s*=.*$', "Address = $newAddress"
$templateContent = $templateContent -replace '(?m)^PublicKey\s*=.*$', "PublicKey = $newPublicKey"

# Интеграция Xbox-DNS (IPv4 + IPv6)
$xboxDNS = "111.88.96.50, 111.88.96.51, 2a00:ab00:1233:26::50, 2a00:ab00:1233:26::51"
if ($templateContent -match '(?m)^DNS\s*=') {
    $templateContent = $templateContent -replace '(?m)^DNS\s*=.*$', "DNS = $xboxDNS"
} else {
    $templateContent = $templateContent -replace '(?m)^\[Interface\]', "[Interface]`nDNS = $xboxDNS"
}

$finalConfPath = [System.IO.Path]::Combine($RootDir, "AmneziaWG_WARP.conf")
Set-Content -Path $finalConfPath -Value $templateContent

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " УСПЕХ: Конфиг ПОЛНОГО VPN готов!" -ForegroundColor Green
Write-Host " Создан файл в корне: AmneziaWG_WARP.conf" -ForegroundColor Yellow
Write-Host " Маскировка: $($templateFile.Name) | DNS: Xbox-DNS" -ForegroundColor Gray
Write-Host "---------------------------------------------------------" -ForegroundColor Gray
Write-Host " Еще не установлен клиент AmneziaWG? Скачайте отсюда:" -ForegroundColor Cyan
Write-Host " 1. GitHub (Зеркало): https://github.com/amnezia-vpn/amneziawg-windows/releases" -ForegroundColor White
Write-Host " 2. Официальный сайт: https://amnezia.org/" -ForegroundColor White
Write-Host "=========================================================" -ForegroundColor Green