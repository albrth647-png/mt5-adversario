# Configura la cuenta demo, arranca el EA y vigila la sesion.
# Uso:  .\ejecutar_ea.ps1 -Minutos 240 -Tf M5
#
# Credenciales por entorno (nunca por linea de comandos):
#   MT5_LOGIN, MT5_PASSWORD, MT5_SERVER, TELEGRAM_TOKEN, TELEGRAM_CHAT, MT5_SYMBOLS
#
# El EA calcula y manda por WebRequest. Si MT5 bloquea la salida (error 4014,
# URL no autorizada), el EA deja el mensaje en MQL5/Files/adv_pendientes.txt y
# este script lo entrega: la senal no se pierde por una restriccion del terminal.
param(
  [int]$Minutos = 240,
  [string]$Mt5Dir = 'C:\Program Files\MetaTrader 5',
  [string]$Tf = 'M5',
  [string]$Panel = 'si'   # si/no: publicar el panel web en vivo
)

$ErrorActionPreference = 'Stop'

$login  = $env:MT5_LOGIN
$pass   = $env:MT5_PASSWORD
$server = $env:MT5_SERVER
$token  = $env:TELEGRAM_TOKEN
$chat   = $env:TELEGRAM_CHAT
$sims   = if ($env:MT5_SYMBOLS) { $env:MT5_SYMBOLS } else { 'FX Vol 20,FX Vol 40,SFX Vol 20,SFX Vol 40' }

$falta = @()
foreach ($par in @(@('MT5_LOGIN', $login), @('MT5_PASSWORD', $pass), @('MT5_SERVER', $server),
                   @('TELEGRAM_TOKEN', $token), @('TELEGRAM_CHAT', $chat))) {
  if (-not $par[1]) { $falta += $par[0] }
}
if ($falta.Count -gt 0) { throw "Faltan credenciales: $($falta -join ', ')" }

if ($Minutos -gt 330) { $Minutos = 330 }

$files   = Join-Path $Mt5Dir 'MQL5\Files'
$pend    = Join-Path $files 'adv_pendientes.txt'
$logEa   = Join-Path $files 'adv.log'
New-Item -ItemType Directory -Force -Path $files | Out-Null

# ------------------------------------------------------- configuracion del EA
$precios = if ($env:MT5_PRECIOS) { $env:MT5_PRECIOS } else { '1' }
$cfg = @(
  "token=$token"
  "chat=$chat"
  "simbolos=$sims"
  "tf=$Tf"
  "velas=3000"
  "latido=15"
  "precios=$precios"
) -join "`r`n"
Set-Content -Path (Join-Path $files 'adv.cfg') -Value $cfg -Encoding ASCII

$primero = ($sims -split ',')[0].Trim()
$ini = @(
  '[Common]'
  "Login=$login"
  "Password=$pass"
  "Server=$server"
  ''
  '[Experts]'
  'AllowLiveTrading=1'
  'Enabled=1'
  'AllowDllImport=0'
  'WebRequest=1'
  'WebRequestUrl=api.telegram.org,https://api.telegram.org'
  ''
  '[StartUp]'
  'Expert=EstrategiaAdversaria'
  "Symbol=$primero"
  "Period=$Tf"
) -join "`r`n"
Set-Content -Path (Join-Path $Mt5Dir 'adv.ini') -Value $ini -Encoding ASCII

Write-Host "simbolos: $sims | tf: $Tf | grafico: $primero"

# ----------------------------------------- lista blanca de WebRequest en MT5
# Vive en el common.ini del terminal (UTF-16) y hay que FUSIONARLA: si se
# sobrescribe el archivo, MT5 lo regenera y se pierden login y arranque del EA.
$cp = Join-Path $Mt5Dir 'config\common.ini'
New-Item -ItemType Directory -Force -Path (Split-Path $cp) | Out-Null
$lineas = @()
if (Test-Path $cp) {
  $lineas = @(Get-Content -LiteralPath $cp -Encoding Unicode)
}
Write-Host "common.ini previo: $(if (Test-Path $cp) { "$($lineas.Count) lineas" } else { 'no existia' })"

$extra = @('WebRequest=1', 'WebRequestUrl=api.telegram.org,https://api.telegram.org')
$salida = New-Object System.Collections.Generic.List[string]
$i = 0
$visto = $false
while ($i -lt $lineas.Count) {
  $l = [string]$lineas[$i]
  if ($l -match '^\s*\[(.+)\]\s*$') {
    $sec = $matches[1]
    $salida.Add($l)
    if ($sec -eq 'Experts') {
      $i++
      while ($i -lt $lineas.Count -and ([string]$lineas[$i]) -notmatch '^\s*\[') {
        if (([string]$lineas[$i]) -notmatch '^\s*WebRequest') { $salida.Add([string]$lineas[$i]) }
        $i++
      }
      foreach ($e in $extra) { $salida.Add($e) }
      $visto = $true
      continue
    }
  } else {
    $salida.Add($l)
  }
  $i++
}
if (-not $visto) {
  $salida.Add('[Experts]')
  foreach ($e in $extra) { $salida.Add($e) }
}
Set-Content -LiteralPath $cp -Value $salida -Encoding Unicode
Write-Host "common.ini escrito: $((Get-Content -LiteralPath $cp -Encoding Unicode).Count) lineas"
foreach ($x in (Get-Content -LiteralPath $cp -Encoding Unicode | Select-String 'WebRequest')) { Write-Host "  $x" }

# ------------------------------------------------------- entrega de pendientes
function Enviar-Pendientes {
  $entregados = 0
  # Formato nuevo: un archivo por mensaje (pend_0001.txt, ...). Mas robusto:
  # sin regex, sin carreras de append, y cada mensaje se borra al entregarse.
  # Se usa Where-Object en lugar de -Filter: -Filter depende del proveedor y a
  # veces no devuelve archivos cuyo nombre tiene guiones bajos en esta ruta.
  $pendientes = @(Get-ChildItem -LiteralPath $files -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'pend_*.txt' } | Sort-Object CreationTime)
  if ($pendientes.Count -gt 0) {
    Write-Host ("pendientes encontrados: " + (($pendientes | ForEach-Object { $_.Name }) -join ', '))
  }
  foreach ($f in $pendientes) {
    $contenido = $null
    for ($r = 0; $r -lt 5 -and -not $contenido; $r++) {
      foreach ($enc in @('Unicode','UTF8','Default')) {
        try { $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding $enc -ErrorAction Stop; if ($raw) { $contenido = $raw; break } } catch { }
      }
      if (-not $contenido) { Start-Sleep -Seconds 1 }
    }
    if (-not $contenido) {
      $bytes = ''
      try { $bytes = ([System.IO.File]::ReadAllBytes($f.FullName) | ForEach-Object { $_.ToString('X2') }) -join ' ' } catch { }
      Write-Warning "no pude leer $($f.Name) (size=$($f.Length) bytes; primeros bytes: $bytes); se reintenta"
      continue
    }
    $body = @{ chat_id = $chat; text = $contenido.Trim(); parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    $ok = $false
    $resp = $null
    for ($r = 0; $r -lt 3 -and -not $ok; $r++) {
      try {
        $resp = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post `
                 -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
        if ($resp.ok) { $ok = $true }
      } catch {
        $detalle = $_.Exception.Message
        try {
          $stream = $_.Exception.Response.GetResponseStream()
          if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            $detalle = $detalle + ' | ' + $reader.ReadToEnd()
            $reader.Close()
          }
        } catch { }
        Write-Warning "intento $($r+1) fallo para $($f.Name): $detalle"
        if ($detalle -match '429') { Start-Sleep -Seconds 5 } else { Start-Sleep -Seconds 2 }
      }
    }
    if ($ok) {
      Remove-Item -LiteralPath $f.FullName -Force
      $destino = if ($resp.result.chat.username) { '@' + $resp.result.chat.username } else { $resp.result.chat.title }
      Write-Host "Telegram ok: msg $($resp.result.message_id) -> chat $($resp.result.chat.id) ($destino)"
      $entregados++
      Start-Sleep -Seconds 1
    } else {
      Write-Warning "NO se pudo entregar $($f.Name); se reintenta en el siguiente ciclo"
    }
  }
  # Formato legado (adv_pendientes.txt con marcadores) por compatibilidad.
  if (Test-Path $pend) {
    $raw = $null
    for ($r = 0; $r -lt 5 -and -not $raw; $r++) {
      try { $raw = Get-Content -LiteralPath $pend -Raw -Encoding Unicode } catch { }
      if (-not $raw) { Start-Sleep -Seconds 1 }
    }
    if ($raw) {
      $bloques = [regex]::Matches($raw, '(?s)===INICIO===\s*\r?\n(.*?)\r?\n===FIN===')
      if ($bloques.Count -gt 0) {
        $bl = 0
        foreach ($b in $bloques) {
          $body = @{ chat_id = $chat; text = $b.Groups[1].Value.Trim(); parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json -Compress
          try {
            $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post `
                   -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
            if ($r.ok) { $bl++; $entregados++ }
          } catch { Write-Warning "legado: $($_.Exception.Message)" }
        }
        if ($bl -eq $bloques.Count) { Remove-Item -LiteralPath $pend -Force; Write-Host "pendientes entregados: $bl" }
      }
    }
  }
  return $entregados
}

# --------------------------------------------------------------------- panel
# El panel y su tunel se cuelgan de ESTE proceso, que dura toda la sesion. Si se
# lanzaran en su propio step, al terminar el step el runner se lleva cloudflared
# y el enlace del movil muere (Cloudflare error 1033).
if ($Panel -eq 'si') {
  $scriptPanel = Join-Path $PSScriptRoot 'panel_web.ps1'
  if (Test-Path $scriptPanel) {
    $salidaPanel = Join-Path (Get-Location) 'panel-out'
    New-Item -ItemType Directory -Force -Path $salidaPanel | Out-Null
    # el propio ejecutable de este host, para no depender del PATH
    $pwshExe = (Get-Process -Id $PID).Path
    # Start-Process une ArgumentList con espacios y NO pone comillas: cada ruta
    # con espacios tiene que ir ya entre comillas o llega cortada (C:\Program).
    $pPanel = Start-Process -FilePath $pwshExe `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', "-File `"$scriptPanel`"",
                                '-Puerto', '8787', "-Mt5Dir `"$Mt5Dir`"", "-Salida `"$salidaPanel`"",
                                '-Minutos', "$Minutos", '-Supervisar') `
                -RedirectStandardOutput (Join-Path $salidaPanel 'panel_web.log') `
                -RedirectStandardError  (Join-Path $salidaPanel 'panel_web.err.log') `
                -WindowStyle Hidden -PassThru
    Write-Host "panel lanzado (pid $($pPanel.Id)), puerto 8787"
  } else {
    Write-Warning "no encuentro $scriptPanel; sigo sin panel"
  }
}

# ------------------------------------------------------------------- arranque
$p = Start-Process -FilePath (Join-Path $Mt5Dir 'terminal64.exe') `
      -ArgumentList '/portable', "/config:`"$(Join-Path $Mt5Dir 'adv.ini')`"" -PassThru
Write-Host "terminal64 pid=$($p.Id) durante $Minutos min"

$total = $Minutos * 60
# ------------------------------------------------------------------- publicar
# Copia la captura real de MT5 y el estado del EA a una rama 'live' del repo
# para que el movil pueda verlos en GitHub (raw.githubusercontent.com) sin
# depender del tunel de Cloudflare. Solo actua si hay token de GitHub (Actions).
function Publicar-EnGitHub {
  if (-not ($env:GITHUB_TOKEN -and $env:GITHUB_REPOSITORY)) { return }
  try {
    $tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $clone = Join-Path $tmp 'live-clone'
    if (Test-Path $clone) { Remove-Item -Recurse -Force $clone }
    $url = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$($env:GITHUB_REPOSITORY).git"
    git clone --depth 1 --branch live $url $clone 2>$null | Out-Null
    if (-not (Test-Path (Join-Path $clone '.git'))) {
      New-Item -ItemType Directory -Force -Path $clone | Out-Null
      Push-Location $clone
      git init -q 2>$null
      git remote remove origin 2>$null | Out-Null
      git remote add origin $url 2>$null
      Pop-Location
    }
    Push-Location $clone
    git checkout --orphan live 2>$null | Out-Null
    git rm -rf . 2>$null | Out-Null
    foreach ($f in @('panel_chart.png','panel_estado.json')) {
      $src = Join-Path $files $f
      if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $clone $f) -Force }
    }
    $html = @'
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Adversario en vivo</title>
<style>body{margin:0;background:#0b0f14;color:#d7e0ea;font:13px monospace}img{width:100%;height:auto;display:block}pre{padding:8px;white-space:pre-wrap}</style>
<h2>grafica real de MT5</h2>
<img src="panel_chart.png" alt="grafica MT5">
<h2>estado del EA</h2>
<pre id=e>...</pre>
<script>fetch('panel_estado.json').then(r=>r.json()).then(d=>{document.getElementById('e').textContent=JSON.stringify(d,null,2)}).catch(()=>{})</script>
'@
    Set-Content -Path (Join-Path $clone 'index.html') -Value $html -Encoding UTF8
    git config user.email 'github-actions[bot]@users.noreply.github.com'
    git config user.name 'github-actions[bot]'
    git add -A 2>$null
    git commit -m "live $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 2>$null | Out-Null
    git push --force $url live 2>$null | Out-Null
    Pop-Location
    Write-Host "publicado en GitHub (rama live)"
    if (-not $script:liveAvisado) {
      $script:liveAvisado = $true
      if ($token -and $chat) {
        $enlace = "https://github.com/$($env:GITHUB_REPOSITORY)/blob/live/panel_chart.png?raw=true"
        $txt = "📷 Grafica real de MT5 (se actualiza sola en GitHub):`n$enlace`n`nRama live del repo; el movil la abre sin tunel."
        try {
          $body = @{ chat_id = $chat; text = $txt; disable_web_page_preview = $false } | ConvertTo-Json -Compress
          Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
          Write-Host 'enlace de GitHub enviado a Telegram'
        } catch { Write-Warning "no pude mandar el enlace de GitHub: $($_.Exception.Message)" }
      }
    }
  } catch {
    Write-Warning "no pude publicar en GitHub: $($_.Exception.Message)"
    try { Pop-Location } catch { }
  }
}

for ($s = 15; $s -le $total; $s += 15) {
  Start-Sleep -Seconds 15
  if ($p.HasExited) { Write-Warning "el terminal termino solo (exit $($p.ExitCode))"; break }
  Enviar-Pendientes | Out-Null
  if ($s % 60 -eq 0) {
    Write-Host "==== minuto $($s / 60) ===="
    if (Test-Path $logEa) { Get-Content $logEa -Tail 3 } else { Write-Host 'sin adv.log todavia' }
  }
  # cada 5 minutos publica la captura real en GitHub (rama live)
  if ($s % 300 -eq 0) { Publicar-EnGitHub }
}

# ultimo intento antes de cerrar
Enviar-Pendientes | Out-Null
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Write-Host 'sesion cerrada'
