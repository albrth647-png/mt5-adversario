# Panel web del EA + tunel de Cloudflare, con supervision.
#
# Uso normal (lo llama ejecutar_ea.ps1 en segundo plano):
#   .\panel_web.ps1 -Puerto 8787 -Minutos 60 -Supervisar
#
# El panel NO decide nada y NO toca la estrategia: lee panel_estado.json y
# adv.log, que el EA ya escribe, y los sirve por HTTP. El tunel rapido de
# Cloudflare (trycloudflare.com) no necesita cuenta ni dominio, pero cambia de
# URL en cada corrida y no soporta SSE: la pagina se refresca por polling.
#
# -Supervisar mantiene el proceso vivo toda la sesion y RELEVANTA cloudflared
# si se cae, mandando el enlace nuevo a Telegram. Sin -Supervisar arranca una
# vez y sale (util para probar a mano).
#
# Por que asi: si cloudflared se lanza en un step y el step termina, el runner
# se lleva el proceso y el enlace queda muerto (error 1033 de Cloudflare). Por
# eso vive colgado del proceso que dura toda la sesion.

param(
  [int]$Puerto = 8787,
  [string]$Mt5Dir = 'C:\Program Files\MetaTrader 5',
  [string]$Salida = 'panel-out',
  [int]$Minutos = 60,
  [switch]$Supervisar
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

function Enviar-Enlace([string]$url) {
  # A Telegram solo van las señales: el enlace del panel queda en el log del
  # run y en el resumen, que caduca con la corrida.
  Write-Host "panel en vivo: $url"
}

# ------------------------------------------------------------------- node
$logNode = Join-Path $Salida 'panel.log'
$errNode = Join-Path $Salida 'panel.err.log'
$pNode = Start-Process -FilePath 'node' -ArgumentList @($script) -WorkingDirectory $raiz `
           -RedirectStandardOutput $logNode -RedirectStandardError $errNode `
           -WindowStyle Hidden -PassThru
Write-Host "panel node pid=$($pNode.Id) puerto=$Puerto"

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
  Write-Warning 'el panel no respondio en local; sigo sin panel'
  if (Test-Path $errNode) { Get-Content $errNode -Tail 20 | ForEach-Object { Write-Host "  node: $_" } }
  exit 0
}

# --------------------------------------------------------------- cloudflared
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$cf  = Join-Path $tmp 'cloudflared.exe'

function Asegurar-Cloudflared {
  if (Test-Path $cf) { return $true }
  $url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
  try {
    Invoke-WebRequest -Uri $url -OutFile $cf -UseBasicParsing -TimeoutSec 120
    Write-Host "cloudflared descargado: $((Get-Item $cf).Length) B"
    return $true
  } catch {
    Write-Warning "no pude descargar cloudflared: $($_.Exception.Message)"
    return $false
  }
}

# Un intento de tunel. Devuelve la URL publica o $null.
function Levantar-Tunel([string]$protocolo) {
  $sello = Get-Date -Format 'HHmmss'
  $logCf = Join-Path $Salida "cloudflared_$sello.log"
  $errCf = Join-Path $Salida "cloudflared_$sello.err.log"
  $argsCf = @('tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$Puerto")
  if ($protocolo) { $argsCf += @('--protocol', $protocolo) }
  $p = Start-Process -FilePath $cf -ArgumentList $argsCf `
         -RedirectStandardOutput $logCf -RedirectStandardError $errCf `
         -WindowStyle Hidden -PassThru
  Write-Host "cloudflared pid=$($p.Id) protocolo=$(if ($protocolo) { $protocolo } else { 'auto' })"

  $url = $null
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    foreach ($f in @($errCf, $logCf)) {
      if (-not (Test-Path $f)) { continue }
      $m = Select-String -Path $f -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches -ErrorAction SilentlyContinue |
             Select-Object -First 1
      if ($m) { $url = $m.Matches[0].Value; break }
    }
    if ($url) { break }
    if ($p.HasExited) { break }
  }
  if (-not $url) {
    Write-Warning "sin URL publica (protocolo $(if ($protocolo) { $protocolo } else { 'auto' }))"
    foreach ($f in @($errCf, $logCf)) { if (Test-Path $f) { Get-Content $f -Tail 8 | ForEach-Object { Write-Host "  cf: $_" } } }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    $script:pCf = $null
    return $null
  }
  $script:pCf   = $p
  $script:logCf = $errCf
  return $url
}

if (-not (Asegurar-Cloudflared)) { exit 0 }

$publica = Levantar-Tunel ''
# Si el primer intento falla (QUIC bloqueado en la red del runner), se reintenta
# por http2, que va por 443.
if (-not $publica) { $publica = Levantar-Tunel 'http2' }

if ($publica) {
  $enlace = "$publica/?k=$clave"
  Write-Host "PANEL: $enlace"
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "## Panel en vivo`n`n$enlace`n"
  Enviar-Enlace $enlace
} else {
  Write-Warning 'no obtuve URL publica del tunel'
  if (-not $Supervisar) { exit 0 }
}

if (-not $Supervisar) { exit 0 }

# ------------------------------------------------------------- supervision
# Vive lo que dura la sesion y relevanta el tunel si se cae: un tunel rapido se
# cae por rate limit o por red, y sin esto el enlace del movil queda muerto.
$limite   = (Get-Date).AddMinutes($Minutos + 20)
$ultimo   = $publica
$fallos   = 0
while ((Get-Date) -lt $limite) {
  Start-Sleep -Seconds 20
  if ($pNode.HasExited) {
    Write-Warning "el panel node termino (exit $($pNode.ExitCode)); no lo relevanto"
    break
  }
  if ($script:pCf -and -not $script:pCf.HasExited) { continue }

  $fallos++
  Write-Warning "cloudflared no esta vivo (fallo $fallos); relevanto"
  if ($fallos -ge 8) { Write-Warning 'demasiados fallos seguidos; dejo de relevantar'; break }

  $nueva = Levantar-Tunel ''
  if (-not $nueva) { $nueva = Levantar-Tunel 'http2' }
  if ($nueva -and $nueva -ne $ultimo) {
    Write-Host "PANEL (nuevo tunel): $nueva/?k=$clave"
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "`nPanel (enlace nuevo, el anterior ya no sirve):`n$nueva/?k=$clave`n"
    Enviar-Enlace "$nueva/?k=$clave"
    $ultimo = $nueva
  } else {
    Start-Sleep -Seconds 15
  }
}
Write-Host 'panel: supervision terminada'
