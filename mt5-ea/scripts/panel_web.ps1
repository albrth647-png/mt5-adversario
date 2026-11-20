# Arranca el panel web del EA y lo publica con un tunel de Cloudflare, para
# abrirlo desde el movil mientras el bot corre en el runner.
#
# Uso:  .\panel_web.ps1 -Puerto 8787 -MinutosAviso 90
#
# El panel NO decide nada y NO toca la estrategia: lee panel_estado.json y
# adv.log, que el EA ya escribe, y los sirve por HTTP. El tunel rapido de
# Cloudflare (trycloudflare.com) no necesita cuenta ni dominio, pero cambia de
# URL en cada corrida y no soporta SSE: la pagina se refresca por polling.
#
# Credenciales por entorno: TELEGRAM_TOKEN, TELEGRAM_CHAT (opcional, para
# mandar el enlace). MT5_FILES o MT5_DIR para localizar la carpeta del terminal.

param(
  [int]$Puerto = 8787,
  [string]$Mt5Dir = 'C:\Program Files\MetaTrader 5',
  [string]$Salida = 'panel-out'
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot es mt5-adversario/mt5-ea/scripts: el panel vive en mt5-adversario/panel
$raiz   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$panel  = Join-Path $raiz 'panel'
$script = Join-Path $panel 'panel.mjs'
$files  = if ($env:MT5_FILES) { $env:MT5_FILES } else { Join-Path $Mt5Dir 'MQL5\Files' }
$token  = $env:TELEGRAM_TOKEN
$chat   = $env:TELEGRAM_CHAT

if (-not (Test-Path $script)) { throw "no encuentro el panel en $script" }
New-Item -ItemType Directory -Force -Path $Salida | Out-Null

# Clave aleatoria: la URL del tunel es publica, y sin clave cualquiera que la
# adivine veria el log. Va en el enlace que se manda a Telegram.
$clave = -join ((1..28) | ForEach-Object { 'abcdefghijkmnpqrstuvwxyz23456789'[(Get-Random -Maximum 32)] })

$env:PANEL_PORT  = "$Puerto"
$env:PANEL_TOKEN = $clave
$env:MT5_FILES   = $files

# ------------------------------------------------------------------- node
$logNode = Join-Path $Salida 'panel.log'
$errNode = Join-Path $Salida 'panel.err.log'
$pNode = Start-Process -FilePath 'node' -ArgumentList @($script) -WorkingDirectory $raiz `
           -RedirectStandardOutput $logNode -RedirectStandardError $errNode `
           -WindowStyle Hidden -PassThru
Write-Host "panel node pid=$($pNode.Id) puerto=$Puerto"

# Espera a que conteste en local antes de publicar nada.
$localOk = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Puerto/salud" -TimeoutSec 2 -UseBasicParsing
    if ($r.StatusCode -eq 200) { $localOk = $true; Write-Host "panel local: $($r.Content.Trim())"; break }
  } catch { }
  if ($pNode.HasExited) { break }
}
if (-not $localOk) {
  Write-Warning 'el panel no respondio en local; se sigue sin panel'
  if (Test-Path $errNode) { Get-Content $errNode -Tail 20 | ForEach-Object { Write-Host "  node: $_" } }
  exit 0
}

# --------------------------------------------------------------- cloudflared
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$cf = Join-Path $tmp 'cloudflared.exe'
if (-not (Test-Path $cf)) {
  $url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
  try {
    Invoke-WebRequest -Uri $url -OutFile $cf -UseBasicParsing -TimeoutSec 120
    Write-Host "cloudflared descargado: $((Get-Item $cf).Length) B"
  } catch {
    Write-Warning "no pude descargar cloudflared: $($_.Exception.Message)"
    exit 0
  }
}

$logCf = Join-Path $Salida 'cloudflared.log'
$errCf = Join-Path $Salida 'cloudflared.err.log'
$pCf = Start-Process -FilePath $cf `
         -ArgumentList @('tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$Puerto") `
         -RedirectStandardOutput $logCf -RedirectStandardError $errCf `
         -WindowStyle Hidden -PassThru
Write-Host "cloudflared pid=$($pCf.Id)"

$publica = $null
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 1
  foreach ($f in @($errCf, $logCf)) {
    if (-not (Test-Path $f)) { continue }
    $m = Select-String -Path $f -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($m) { $publica = $m.Matches[0].Value; break }
  }
  if ($publica) { break }
  if ($pCf.HasExited) { Write-Warning 'cloudflared termino solo'; break }
}
if (-not $publica) {
  Write-Warning 'no obtuve URL publica del tunel'
  foreach ($f in @($errCf, $logCf)) { if (Test-Path $f) { Get-Content $f -Tail 15 | ForEach-Object { Write-Host "  cf: $_" } } }
  exit 0
}

$enlace = "$publica/?k=$clave"
# El DNS del tunel tarda unos segundos en resolver; se avisa igual porque en el
# movil, cuando llegue el mensaje, ya estara listo.
Write-Host "PANEL: $enlace"
Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "## Panel en vivo`n`n$enlace`n"

if ($token -and $chat) {
  $texto = "🖥️ Panel en vivo`n$enlace`n`nSe apaga cuando termine la corrida."
  $body = @{ chat_id = $chat; text = $texto; disable_web_page_preview = $false } | ConvertTo-Json -Compress
  try {
    $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post `
           -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
    if ($r.ok) { Write-Host "enlace enviado a Telegram (msg $($r.result.message_id))" }
  } catch {
    Write-Warning "no pude mandar el enlace a Telegram: $($_.Exception.Message)"
  }
} else {
  Write-Host 'sin TELEGRAM_TOKEN/CHAT: el enlace queda en el resumen del run'
}
