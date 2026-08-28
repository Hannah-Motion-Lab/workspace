# Hannah — launcher for Windows. `hannah.cmd` next to this file makes it a plain `hannah` command
# (install.ps1 adds this folder to your user PATH).
#   hannah            bring up Ollama + voice/listening sidecars + backend (+ agent) and open the overlay
#   hannah stop       shut it all down (add -KeepOllama to leave the model server running)
#   hannah doctor     what is running and what is missing
# Everything runs in your user session, no admin. Logs: <root>\.hannah-logs\
param([string]$Command = 'up', [switch]$KeepOllama)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Back = Join-Path $Root 'hannah-backend'
$Agent = Join-Path $Root 'hannah-agent'
$Lab = Join-Path $Root 'hannah-motion-lab'
$App = if ($env:HANNAH_APP) { $env:HANNAH_APP } else { Join-Path $env:LOCALAPPDATA 'Programs\Hannah\Hannah.exe' }
$Log = Join-Path $Root '.hannah-launch.log'
$env:Path = "$Root\.tools\git\cmd;$Root\.tools\node;$Root\.tools\ollama;$env:LOCALAPPDATA\Programs\Ollama;$env:USERPROFILE\.local\bin;$env:USERPROFILE\.bun\bin;$env:Path"

function Has($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Up($port) { [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) }
function HealthPath($port) { switch ($port) { 3001 { '/api/v1/health' } 8006 { '/hannah/v0/health' } 11434 { '/api/tags' } default { '/health' } } }
function Healthy($port) { try { Invoke-WebRequest "http://127.0.0.1:$port$(HealthPath $port)" -UseBasicParsing -TimeoutSec 2 | Out-Null; $true } catch { $false } }
function EnvVal($key) {
  # dotenv-like: quotes respected, `#` after a space is a comment
  $f = Join-Path $Back '.env'; if (-not (Test-Path $f)) { return '' }
  foreach ($line in Get-Content $f) {
    $m = [regex]::Match($line, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
    if (-not $m.Success -or $m.Groups[1].Value -ne $key) { continue }
    $v = $m.Groups[2].Value.Trim()
    if ($v.Length -ge 2 -and $v[0] -eq $v[-1] -and ($v[0] -eq '"' -or $v[0] -eq "'")) { return $v.Substring(1, $v.Length - 2) }
    return ($v -split '\s+#', 2)[0].Trim()
  }
  return ''
}
function Settings($section, $key) {
  $f = Join-Path $Back 'data\settings.json'; if (-not (Test-Path $f)) { return '' }
  try { $j = Get-Content $f -Raw | ConvertFrom-Json; $s = $j.$section; if ($s -and $s.$key) { return [string]$s.$key } } catch {}
  return ''
}
function AgentOn { (EnvVal 'AGENT_ENABLED') -eq 'true' }
function AgentKey { $k = Settings 'agent' 'apiKey'; if ($k) { return $k }; foreach ($v in 'ANTHROPIC_API_KEY', 'OPENROUTER_API_KEY') { $k = EnvVal $v; if ($k) { return $k } }; '' }
function AgentKeyVar { $k = AgentKey; if ($k -like 'sk-or-*') { 'OPENROUTER_API_KEY' } else { 'ANTHROPIC_API_KEY' } }
function AgentToken {
  $t = Settings 'agent' 'token'; if (-not $t) { $t = EnvVal 'HANNAH_AGENT_TOKEN' }
  if (-not $t) {
    $t = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $f = Join-Path $Back '.env'; $txt = Get-Content $f -Raw
    if ($txt -match '(?m)^#?\s*HANNAH_AGENT_TOKEN=') { $txt = $txt -replace '(?m)^#?\s*HANNAH_AGENT_TOKEN=.*$', "HANNAH_AGENT_TOKEN=$t" } else { $txt += "`nHANNAH_AGENT_TOKEN=$t`n" }
    Set-Content $f $txt -NoNewline
  }
  $t
}
function SenseOn { (EnvVal 'SENSE_ENABLED') -eq 'true' }
function SenseToken {
  $t = Settings 'sense' 'token'; if (-not $t) { $t = EnvVal 'HANNAH_SENSE_TOKEN' }
  if (-not $t) {
    $t = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $f = Join-Path $Back '.env'; $txt = Get-Content $f -Raw
    if ($txt -match '(?m)^#?\s*HANNAH_SENSE_TOKEN=') { $txt = $txt -replace '(?m)^#?\s*HANNAH_SENSE_TOKEN=.*$', "HANNAH_SENSE_TOKEN=$t" } else { $txt += "`nHANNAH_SENSE_TOKEN=$t`n" }
    Set-Content $f $txt -NoNewline
  }
  $t
}
function WatchCounts {
  try { $w = (Invoke-RestMethod 'http://127.0.0.1:8007/health' -TimeoutSec 2).watches; "$($w.armed) armed · $($w.blind) blind · $($w.suspended) suspended" } catch { '' }
}
# our own processes: anchored to this checkout's path (never other apps)
function OwnProcs { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$Root\*" -and $_.ProcessId -ne $PID } }
# one log per service under <root>\.hannah-logs (two processes cannot share one redirected file)
$Logs = Join-Path $Root '.hannah-logs'; New-Item -ItemType Directory -Force -Path $Logs | Out-Null
function StartBg($name, $dir, $exe, $args, $extraEnv) {
  foreach ($k in $extraEnv.Keys) { Set-Item "env:$k" $extraEnv[$k] }
  Start-Process -WindowStyle Hidden -WorkingDirectory $dir -FilePath $exe -ArgumentList $args -RedirectStandardOutput (Join-Path $Logs "$name.log") -RedirectStandardError (Join-Path $Logs "$name.err.log")
  foreach ($k in $extraEnv.Keys) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
}

switch ($Command) {
  'doctor' {
    Write-Host 'Hannah — Windows'
    Write-Host "  root       : $Root"
    $t = foreach ($x in 'node', 'uv', 'bun', 'ollama') { if (Has $x) { "$x✓" } else { "$x✗" } }; Write-Host "  tools      : $($t -join ' ')"
    $s = foreach ($p in @{11434='ollama'; 8002='tts'; 8001='asr'; 8005='motion'; 3001='backend'; 8006='agent'; 8007='sense'}.GetEnumerator() | Sort-Object Name) {
      if (Healthy $p.Name) { "$($p.Value)✓" } elseif (Up $p.Name) { "$($p.Value)⚠(port busy)" } else { "$($p.Value)✗" } }
    Write-Host "  services   : $($s -join ' ')"
    Write-Host "  app        : $App $(if (Test-Path $App) { '✓' } else { '✗ (re-run the installer)' })"
    $mdev = try { (Invoke-RestMethod 'http://127.0.0.1:8005/health' -TimeoutSec 2).device } catch { '' }
    Write-Host "  gestures   : $(if ($mdev) { "on $mdev" } else { 'not running' })"
    Write-Host "  hands      : $(if (AgentOn) { "AGENT_ENABLED=true · key $(if (AgentKey) { '✓' } else { '✗' })" } else { 'off (AGENT_ENABLED=false)' })"
    Write-Host "  watches    : $(if (SenseOn) { $c = WatchCounts; if ($c) { $c } else { 'SENSE_ENABLED=true but :8007 is not answering' } } else { 'off (SENSE_ENABLED=false)' })"
    exit 0
  }
  'stop' {
    Write-Host 'Hannah — shutting down:'
    Get-Process -Name Hannah -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $App } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  overlay ✓'
    OwnProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host '  backend, sidecars, agent ✓'
    if (-not $KeepOllama) { Get-Process -Name ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Host '  ollama ✓' } else { Write-Host '  ollama kept' }
    exit 0
  }
}

if (-not (Test-Path (Join-Path $Back '.env'))) { Write-Host "hannah: $Back\.env is missing — run the installer first"; exit 1 }
Add-Content $Log "[hannah] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') up"
if (-not (Healthy 11434) -and (Has ollama)) { Start-Process -WindowStyle Hidden -FilePath 'ollama' -ArgumentList 'serve' }
$py = Join-Path $Back 'sidecar\.venv\Scripts\python.exe'
if (-not (Up 8002)) { StartBg 'tts' (Join-Path $Back 'sidecar\tts') $py '-m uvicorn main:app --port 8002' @{ TTS_DEVICE = 'cpu' } }
if (-not (Up 8001)) { StartBg 'asr' (Join-Path $Back 'sidecar\asr') $py '-m uvicorn main:app --port 8001' @{ ASR_DEVICE = 'cpu' } }
# gestures: the NVIDIA card if there is one, else the CPU — never skipped
$mpy = Join-Path $Lab '.venv\Scripts\python.exe'
if (-not (Up 8005) -and (Test-Path $mpy)) { StartBg 'motion' $Lab $mpy '-m uvicorn serve.main:app --port 8005' @{ MOTION_DEVICE = 'auto'; PYTHONPATH = (Join-Path $Lab 'src') } }
# the watches, before the backend so its capability probe finds them
$spy = Join-Path $Back 'sidecar\sense\.venv\Scripts\python.exe'
if ((SenseOn) -and (Test-Path $spy) -and -not (Up 8007)) { StartBg 'sense' (Join-Path $Back 'sidecar\sense') $spy '-m uvicorn main:app --host 127.0.0.1 --port 8007' @{ HANNAH_SENSE_TOKEN = (SenseToken) } }
if ((AgentOn) -and (Has bun) -and (Test-Path $Agent) -and -not (Up 8006)) {
  $tok = AgentToken
  $aenv = @{ HANNAH_AGENT_TOKEN = $tok; HANNAH_AGENT_SERVER_PASSWORD = $tok; HANNAH_AGENT_MAX_MODE = (EnvVal 'AGENT_MODE'); HANNAH_AGENT_DENY_DIRS = (Join-Path $Back 'data') }
  $aenv[(AgentKeyVar)] = (AgentKey)
  StartBg 'agent' $Agent 'bun' 'run dev serve --port 8006' $aenv
}
if (-not (Up 3001)) { StartBg 'backend' $Back 'node' 'src\server.js' @{} }
for ($i = 0; $i -lt 60 -and -not (Healthy 3001); $i++) { Start-Sleep 1 }
if (-not (Healthy 3001)) { Write-Host "hannah: the backend did not come up — see $Logs\backend.err.log"; exit 1 }
foreach ($p in 8001, 8002, 8005, 8006, 8007) { if ((Up $p) -and -not (Healthy $p)) { Add-Content $Log "[hannah] WARNING: port $p is busy with something else" } }
if (Test-Path $App) {
  # the packaged app serves its own frontend and talks to the backend at localhost:3001;
  # it holds a single-instance lock, so a second launch just focuses the existing window
  Start-Process -FilePath $App
} else {
  Write-Host "hannah: $App not found — re-run the installer, or open http://localhost:3001/test-client.html"
}
