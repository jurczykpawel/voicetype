<#
  VoiceType installer for Windows (PowerShell).

    irm https://raw.githubusercontent.com/jurczykpawel/voicetype/main/windows/install.ps1 | iex

  Sets up the engine, ffmpeg, the chosen transcription backend, and AutoHotkey + the hotkey.

  Backends:
    whisper   — local whisper.cpp, offline (downloads ~1.5 GB model)
    parakeet  — local Parakeet v3 (parakeet-cli.exe, in the same whisper.cpp bundle); fast,
                multilingual, downloads a ~0.6 GB model. Best local choice on CPU.   [default]
    cloud     — Groq/OpenAI (OpenAI-compatible); no model download, needs an API key
    deepgram / elevenlabs — cloud; need an API key

  Param/env:  -Backend whisper|parakeet|cloud|deepgram|elevenlabs   (prompted if omitted)
#>
[CmdletBinding()]
param([string]$Backend = $env:VOICETYPE_BACKEND)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "▸ $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Download($url, $out) {
  if (Have 'curl.exe') { & curl.exe -L --fail --retry 3 -o $out $url }
  else { Invoke-WebRequest $url -OutFile $out }
}
function Winget-Install($id) {
  if (Have 'winget') { winget install --id $id -e --accept-source-agreements --accept-package-agreements }
  else { Warn "winget not found — install $id manually." }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Repo    = 'jurczykpawel/voicetype'
$Branch  = if ($env:VOICETYPE_BRANCH) { $env:VOICETYPE_BRANCH } else { 'main' }
$Raw     = "https://raw.githubusercontent.com/$Repo/$Branch"
$InstallDir = Join-Path $env:USERPROFILE '.voicetype'
$ModelDir   = Join-Path $InstallDir 'models'
$WhDir      = Join-Path $InstallDir 'whisper'
$Engine     = Join-Path $InstallDir 'voice-type.ps1'
$Ahk        = Join-Path $InstallDir 'voicetype.ahk'
New-Item -ItemType Directory -Force -Path $InstallDir, $ModelDir | Out-Null

# ── Choose backend ────────────────────────────────────────────────────────────
if (-not $Backend) {
  Write-Host "`nWhich transcription backend?"
  Write-Host "  1) Parakeet   — local, fast, multilingual (~0.6 GB)   [default]"
  Write-Host "  2) Whisper    — local, offline (~1.5 GB model)"
  Write-Host "  3) Cloud      — OpenAI-compatible / Groq (free), no model download"
  Write-Host "  4) Deepgram   — cloud"
  Write-Host "  5) ElevenLabs — cloud"
  switch (Read-Host 'Selection [1]') {
    '2' { $Backend = 'whisper' } '3' { $Backend = 'cloud' } '4' { $Backend = 'deepgram' } '5' { $Backend = 'elevenlabs' } default { $Backend = 'parakeet' }
  }
}
if ($Backend -eq 'local') { $Backend = 'whisper' }
Info "Backend: $Backend"
$wantWhisper  = ($Backend -eq 'whisper')
$wantParakeet = ($Backend -eq 'parakeet')

# ── ffmpeg ────────────────────────────────────────────────────────────────────
if (Have 'ffmpeg') { Ok 'ffmpeg already installed' } else { Info 'Installing ffmpeg…'; Winget-Install 'Gyan.FFmpeg' }

# ── whisper.cpp bundle (ships both whisper-cli.exe and parakeet-cli.exe) ───────
if ($wantWhisper -or $wantParakeet) {
  if (-not (Test-Path $WhDir)) {
    Info 'Fetching whisper.cpp Windows binaries…'
    try {
      $rel = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest' -Headers @{ 'User-Agent' = 'voicetype' }
      # Plain CPU build; avoid cublas/CUDA (need an NVIDIA GPU) and Win32.
      $asset = $rel.assets | Where-Object { $_.name -eq 'whisper-bin-x64.zip' } | Select-Object -First 1
      if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match 'whisper.*x64.*\.zip' -and $_.name -notmatch 'cublas|cuda|Win32' } | Select-Object -First 1 }
      if ($asset) {
        $zip = Join-Path $env:TEMP $asset.name
        Download $asset.browser_download_url $zip
        Expand-Archive $zip -DestinationPath $WhDir -Force
      } else { Warn 'No suitable whisper.cpp asset found — install manually.' }
    } catch { Warn "whisper.cpp download failed ($($_.Exception.Message)). Install manually." }
  } else { Ok 'whisper.cpp bundle already present' }
}

# ── Whisper backend ───────────────────────────────────────────────────────────
if ($wantWhisper) {
  # Prefer whisper-cli.exe; main.exe in recent releases is just a deprecation stub.
  $exe = Get-ChildItem $WhDir -Recurse -Include 'whisper-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { $exe = Get-ChildItem $WhDir -Recurse -Include 'main.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($exe) { [Environment]::SetEnvironmentVariable('VOICETYPE_WHISPER_BIN', $exe.FullName, 'User'); Ok "whisper binary: $($exe.FullName)" }
  else { Warn 'whisper-cli.exe not found — set VOICETYPE_WHISPER_BIN manually.' }

  $name = if ($env:VOICETYPE_MODEL_NAME) { $env:VOICETYPE_MODEL_NAME } else { 'ggml-large-v3-turbo.bin' }
  $path = Join-Path $ModelDir $name
  if (Test-Path $path) { Ok "Model present: $name" }
  else { Info "Downloading $name (~1.5 GB, one-time)…"; Download "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$name" $path; Ok "Model saved" }
  [Environment]::SetEnvironmentVariable('VOICETYPE_MODEL', $path, 'User')

  # VAD model (~0.9 MB) — skips non-speech so Whisper can't hallucinate phantom phrases on silence.
  $vad = Join-Path $ModelDir 'ggml-silero-v5.1.2.bin'
  if (Test-Path $vad) { Ok 'VAD model present' }
  else { Info 'Downloading VAD model (~0.9 MB, one-time)…'; Download 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin' $vad; Ok 'VAD model saved' }
}

# ── Parakeet backend ──────────────────────────────────────────────────────────
if ($wantParakeet) {
  $exe = Get-ChildItem $WhDir -Recurse -Include 'parakeet-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($exe) { [Environment]::SetEnvironmentVariable('VOICETYPE_PARAKEET_BIN', $exe.FullName, 'User'); Ok "parakeet binary: $($exe.FullName)" }
  else { Warn 'parakeet-cli.exe not found in the whisper.cpp bundle — set VOICETYPE_PARAKEET_BIN manually.' }

  $name = if ($env:VOICETYPE_PARAKEET_MODEL_NAME) { $env:VOICETYPE_PARAKEET_MODEL_NAME } else { 'ggml-parakeet-tdt-0.6b-v3-q8_0.bin' }
  $path = Join-Path $ModelDir $name
  if (Test-Path $path) { Ok "Model present: $name" }
  else { Info "Downloading $name (~0.6 GB, one-time)…"; Download "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/$name" $path; Ok "Model saved" }
  [Environment]::SetEnvironmentVariable('VOICETYPE_PARAKEET_MODEL', $path, 'User')
}

# ── Engine + AHK ──────────────────────────────────────────────────────────────
Download "$Raw/windows/voice-type.ps1" $Engine
Download "$Raw/windows/voicetype.ahk"  $Ahk
[Environment]::SetEnvironmentVariable('VOICETYPE_BACKEND', $Backend, 'User')
Ok "Engine installed to $Engine"

if ((Have 'AutoHotkey') -or (Test-Path "$env:ProgramFiles\AutoHotkey")) { Ok 'AutoHotkey present' }
else { Info 'Installing AutoHotkey v2…'; Winget-Install 'AutoHotkey.AutoHotkey' }

# ── Next steps ────────────────────────────────────────────────────────────────
Write-Host "`n✓ VoiceType installed." -ForegroundColor Green
Write-Host @"

Next steps:
  1. Double-click  $Ahk   to start the hotkey (or copy it to shell:startup to autostart).
  2. Press Win+Shift+Space to start dictating, press again to stop + paste.
     (edit the hotkey at the top of voicetype.ahk if it clashes)
"@
if (@('cloud','deepgram','elevenlabs') -contains $Backend) {
  Write-Host "  3. Set your API key, e.g.:  setx GROQ_API_KEY gsk_...   (or VOICETYPE_DEEPGRAM_KEY / VOICETYPE_ELEVENLABS_KEY)"
}
Write-Host "`nChange backend later:  setx VOICETYPE_BACKEND parakeet   (then reopen your apps)"
