<#
  voice-type.ps1 — VoiceType engine for Windows (PowerShell). Toggle dictation.

  TOGGLE: first run  = start recording the microphone (ffmpeg/dshow).
          second run = stop -> transcribe -> clipboard -> paste (Ctrl+V) at the cursor.

  Backends (VOICETYPE_BACKEND): local (whisper.cpp) | cloud (OpenAI-compatible) | deepgram | elevenlabs
  (Parakeet is Apple-Silicon only via MLX and is not available on Windows.)

  Config via env vars (all optional):
    VOICETYPE_BACKEND   local (default) | cloud | deepgram | elevenlabs
    VOICETYPE_LANG      language code (default pl; 'auto' = autodetect)
    VOICETYPE_MIC       dshow device name; auto-detected if empty
    VOICETYPE_PROMPT    initial prompt / vocabulary (local + cloud OpenAI-compatible)
    VOICETYPE_PASTE     1 = auto-paste Ctrl+V (default), 0 = clipboard only
    VOICETYPE_DIR       work dir (default %TEMP%\voice-type)
    local:      VOICETYPE_MODEL        path to ggml model (default %USERPROFILE%\.voicetype\models\ggml-large-v3-turbo.bin)
                VOICETYPE_WHISPER_BIN  whisper-cli executable (default whisper-cli.exe)
    cloud:      VOICETYPE_CLOUD_URL/MODEL/KEY  (key falls back to $env:GROQ_API_KEY then $env:OPENAI_API_KEY)
    deepgram:   VOICETYPE_DEEPGRAM_KEY/MODEL   (key falls back to $env:DEEPGRAM_API_KEY)
    elevenlabs: VOICETYPE_ELEVENLABS_KEY/MODEL (key falls back to $env:ELEVENLABS_API_KEY)

  Requires: ffmpeg + curl.exe (built into Windows 10/11). Local backend also needs whisper-cli.exe.
#>

$ErrorActionPreference = 'SilentlyContinue'

# whisper-cli/curl emit UTF-8; PowerShell 5.1 defaults to ANSI and mangles e.g. Polish diacritics.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Get-Env($name, $default) { if ($v = [Environment]::GetEnvironmentVariable($name)) { $v } else { $default } }

$WorkDir   = Get-Env 'VOICETYPE_DIR' (Join-Path $env:TEMP 'voice-type')
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$PidFile   = Join-Path $WorkDir 'ffmpeg.pid'
$Wav       = Join-Path $WorkDir 'rec.wav'
$Pcm       = Join-Path $WorkDir 'rec.pcm'   # raw capture (no header to finalize on stop)

$Backend   = Get-Env 'VOICETYPE_BACKEND' 'local'
$Lang      = Get-Env 'VOICETYPE_LANG' 'pl'
$Mic       = Get-Env 'VOICETYPE_MIC' ''
$Prompt    = Get-Env 'VOICETYPE_PROMPT' ''
$Paste     = Get-Env 'VOICETYPE_PASTE' '1'
$Model     = Get-Env 'VOICETYPE_MODEL' (Join-Path $env:USERPROFILE '.voicetype\models\ggml-large-v3-turbo.bin')
$VadModel  = Get-Env 'VOICETYPE_VAD_MODEL' (Join-Path $env:USERPROFILE '.voicetype\models\ggml-silero-v5.1.2.bin')
$WhisperBin = Get-Env 'VOICETYPE_WHISPER_BIN' 'whisper-cli.exe'
$ParakeetBin = Get-Env 'VOICETYPE_PARAKEET_BIN' 'parakeet-cli.exe'
$ParakeetModel = Get-Env 'VOICETYPE_PARAKEET_MODEL' (Join-Path $env:USERPROFILE '.voicetype\models\ggml-parakeet-tdt-0.6b-v3-q8_0.bin')
$CloudUrl  = Get-Env 'VOICETYPE_CLOUD_URL' 'https://api.groq.com/openai/v1/audio/transcriptions'
$CloudModel = Get-Env 'VOICETYPE_CLOUD_MODEL' 'whisper-large-v3-turbo'
$DeepgramModel = Get-Env 'VOICETYPE_DEEPGRAM_MODEL' 'nova-3'
$ElevenModel   = Get-Env 'VOICETYPE_ELEVENLABS_MODEL' 'scribe_v1'

function Notify($text) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = [System.Drawing.SystemIcons]::Information
    $n.Visible = $true
    $n.BalloonTipTitle = 'VoiceType'
    $n.BalloonTipText = $text
    $n.ShowBalloonTip(2000)
    Start-Sleep -Milliseconds 300
    $n.Dispose()
  } catch {}
}

# Auto-detect the first dshow audio input device name.
# Modern ffmpeg tags each line with "(audio)" / "(video)" instead of section headers,
# so match the first line ending in (audio) and grab the quoted device name.
function Get-DefaultMic {
  # ffmpeg prints the device list to stderr. When the engine runs without a console
  # (launched hidden by AutoHotkey), capturing via "& ffmpeg 2>&1" yields nothing, so
  # run it as its own process with stderr redirected to a file.
  $tmp = Join-Path $WorkDir 'devices.txt'
  Start-Process -FilePath 'ffmpeg' -WindowStyle Hidden -Wait -RedirectStandardError $tmp `
    -ArgumentList @('-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy')
  $out = Get-Content $tmp -ErrorAction SilentlyContinue
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  # Prefer a real input; skip known virtual/loopback devices that are silent without routing.
  $virt = 'VB-Audio|VB-Cable|CABLE Output|VoiceMeeter|Virtual|Stereo Mix|Miks stereo|What U Hear|Wave Out'
  $first = $null
  foreach ($line in $out) {
    if ($line -match '"([^"]+)"\s*\(audio\)') {
      $name = $Matches[1]
      if ($name -notmatch $virt) { return $name }
      if (-not $first) { $first = $name }
    }
  }
  # Fallback for older ffmpeg with section headers.
  $inAudio = $false
  foreach ($line in $out) {
    if ($line -match 'DirectShow audio devices') { $inAudio = $true; continue }
    if ($line -match 'DirectShow video devices') { $inAudio = $false; continue }
    if ($inAudio -and $line -match '"([^"]+)"') {
      $name = $Matches[1]
      if ($name -notmatch $virt) { return $name }
      if (-not $first) { $first = $name }
    }
  }
  return $first   # all virtual? fall back to the first one
}

# ── Transcription backends -> raw text on stdout ──────────────────────────────
function Transcribe-Local {
  $of = Join-Path $WorkDir 'out'
  $a = @('-m', $Model, '-f', $Wav, '-l', $Lang, '-nt', '-np', '-otxt', '-of', $of)
  # pad 200ms: default 30ms clips short words ("w"/"z") at VAD segment edges
  if ((Test-Path $VadModel) -and (Test-WhisperVad)) { $a += @('--vad', '--vad-model', $VadModel, '--vad-speech-pad-ms', '200') }
  if ($Prompt) { $a += @('--prompt', $Prompt) }
  & $WhisperBin @a *> $null
  Get-Content "$of.txt" -Raw -Encoding UTF8
}

# Parakeet v3 (whisper.cpp's parakeet-cli.exe). Multilingual auto-detect, no language flag.
# ~10x faster than whisper on CPU. -ng forces CPU (reliable; no usable GPU in VMs).
function Transcribe-Parakeet {
  $of = Join-Path $WorkDir 'out'
  & $ParakeetBin -m $ParakeetModel -f $Wav -ng -otxt -of $of -np *> $null
  Get-Content "$of.txt" -Raw -Encoding UTF8
}

function Transcribe-Cloud {
  $key = Get-Env 'VOICETYPE_CLOUD_KEY' (Get-Env 'GROQ_API_KEY' (Get-Env 'OPENAI_API_KEY' ''))
  if (-not $key) { Notify 'Cloud: missing API key (VOICETYPE_CLOUD_KEY)'; return $null }
  $a = @('-fsS', $CloudUrl, '-H', "Authorization: Bearer $key",
         '-F', "file=@$Wav", '-F', "model=$CloudModel", '-F', 'response_format=text')
  if ($Lang -and $Lang -ne 'auto') { $a += @('-F', "language=$Lang") }
  if ($Prompt) { $a += @('-F', "prompt=$Prompt") }
  $r = & curl.exe @a
  if ($LASTEXITCODE -ne 0) { Notify 'Cloud: network/API error'; return $null }
  $r
}

function Transcribe-Deepgram {
  $key = Get-Env 'VOICETYPE_DEEPGRAM_KEY' (Get-Env 'DEEPGRAM_API_KEY' '')
  if (-not $key) { Notify 'Deepgram: missing key (VOICETYPE_DEEPGRAM_KEY)'; return $null }
  $lang = if ($Lang -eq 'auto') { 'multi' } else { $Lang }
  $url = "https://api.deepgram.com/v1/listen?model=$DeepgramModel&smart_format=true"
  if ($lang) { $url += "&language=$lang" }
  $r = & curl.exe -fsS -X POST $url -H "Authorization: Token $key" -H 'Content-Type: audio/wav' --data-binary "@$Wav"
  if ($LASTEXITCODE -ne 0) { Notify 'Deepgram: network/API error'; return $null }
  ($r | ConvertFrom-Json).results.channels[0].alternatives[0].transcript
}

function Transcribe-Elevenlabs {
  $key = Get-Env 'VOICETYPE_ELEVENLABS_KEY' (Get-Env 'ELEVENLABS_API_KEY' '')
  if (-not $key) { Notify 'ElevenLabs: missing key (VOICETYPE_ELEVENLABS_KEY)'; return $null }
  $a = @('-fsS', '-X', 'POST', 'https://api.elevenlabs.io/v1/speech-to-text',
         '-H', "xi-api-key: $key", '-F', "file=@$Wav", '-F', "model_id=$ElevenModel")
  if ($Lang -and $Lang -ne 'auto') { $a += @('-F', "language_code=$Lang") }
  $r = & curl.exe @a
  if ($LASTEXITCODE -ne 0) { Notify 'ElevenLabs: network/API error'; return $null }
  ($r | ConvertFrom-Json).text
}

# Known Whisper hallucinations on silence — whole output == phantom -> treat as no speech.
function Test-Phantom($t) {
  $n = ($t -replace '[.!?…]+$', '').Trim().ToLowerInvariant()
  $ph = @('dziękuję za uwagę', 'dzięki za uwagę', 'dziękuję za oglądanie', 'dzięki za oglądanie',
          'dziękuję za obejrzenie', 'dziękuję', 'dzięki', 'napisy stworzone przez społeczność amara.org',
          'zapraszam do subskrypcji', 'do zobaczenia', 'thank you for watching', 'thanks for watching',
          'thank you', 'you', 'subtitles by the amara.org community')
  return $ph -contains $n
}

# Does the installed whisper build understand --vad? (--help is empty on the Windows build, so we
# scan the binary for the compiled-in option string — reliable and cheap.)
function Test-WhisperVad {
  try {
    $p = (Get-Command $WhisperBin -ErrorAction SilentlyContinue).Source
    if (-not $p) { $p = $WhisperBin }
    return [bool](Select-String -Path $p -Pattern 'vad-model' -SimpleMatch -ErrorAction SilentlyContinue)
  } catch { return $false }
}

# Peak level (dB) of a wav via ffmpeg volumedetect; $null if unknown. Invariant parse (PL locale uses comma).
function Get-PeakDb($wavPath) {
  try {
    $vd = & ffmpeg -hide_banner -i $wavPath -af volumedetect -f null - 2>&1 | Out-String
    if ($vd -match 'max_volume:\s*(-?[0-9.]+) dB') {
      return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }
  } catch {}
  return $null
}

# ── STOP branch: a recording is in progress -> finish + transcribe ────────────
if (Test-Path $PidFile) {
  $ffPid = 0
  [int]::TryParse((Get-Content $PidFile -Raw).Trim(), [ref]$ffPid) | Out-Null
  if ($ffPid -gt 0 -and (Get-Process -Id $ffPid -ErrorAction SilentlyContinue)) {
    # We record to raw PCM (no header to finalize), so a hard kill is safe.
    & taskkill /F /PID $ffPid *> $null
    for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $ffPid -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
    Remove-Item $PidFile -Force

    if (-not (Test-Path $Pcm) -or (Get-Item $Pcm).Length -eq 0) { Notify 'No recording'; exit 0 }
    # Wrap raw PCM into a WAV the transcribers can read.
    Remove-Item $Wav -Force -ErrorAction SilentlyContinue
    & ffmpeg -nostdin -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i $Pcm -y $Wav *> $null
    if (-not (Test-Path $Wav) -or (Get-Item $Wav).Length -eq 0) { Notify 'No recording'; exit 0 }
    # Silence guard: a dead/virtual device (or no mic permission) records ~ -91 dB. Without this,
    # Whisper HALLUCINATES phantom phrases on silence. Threshold -70 dB.
    $peak = Get-PeakDb $Wav
    if ($null -ne $peak -and $peak -lt -70) { Notify 'Silence - check your microphone'; exit 0 }
    Notify 'Transcribing...'

    switch ($Backend) {
      'parakeet'   { $raw = Transcribe-Parakeet }
      'cloud'      { $raw = Transcribe-Cloud }
      'openai'     { $raw = Transcribe-Cloud }
      'groq'       { $raw = Transcribe-Cloud }
      'deepgram'   { $raw = Transcribe-Deepgram }
      'elevenlabs' { $raw = Transcribe-Elevenlabs }
      default      { $raw = Transcribe-Local }
    }
    if ($null -eq $raw) { exit 1 }

    $text = (($raw -replace '\[BLANK_AUDIO\]', '' -replace '\[[^\]]*\]', '') -replace '\s+', ' ').Trim()
    # Empty, or the whole output is a known silence-hallucination -> don't paste (VAD usually kills
    # these; this also covers cloud backends that have no VAD).
    if (-not $text -or (Test-Phantom $text)) { Notify 'Nothing recognized'; exit 0 }

    Set-Clipboard -Value $text
    if ($Paste -eq '1') {
      Add-Type -AssemblyName System.Windows.Forms
      Start-Sleep -Milliseconds 120
      [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    Notify ("OK: " + $text.Substring(0, [Math]::Min(90, $text.Length)))
    [Console]::Out.Write($text)
    exit 0
  }
  Remove-Item $PidFile -Force
}

# ── START branch: begin recording ────────────────────────────────────────────
Remove-Item $Wav, $Pcm -Force -ErrorAction SilentlyContinue
if (-not $Mic) { $Mic = Get-DefaultMic }
if (-not $Mic) { Notify 'No microphone found (set VOICETYPE_MIC)'; exit 1 }

# Record to raw PCM (s16le). The dshow device name has spaces, so it must stay quoted
# as one argument; and raw PCM needs no finalization, so stop = a safe hard kill.
$ffArgs = @('-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'dshow',
            '-i', "audio=`"$Mic`"", '-ar', '16000', '-ac', '1', '-f', 's16le',
            '-flush_packets', '1', '-y', $Pcm)
$p = Start-Process -FilePath 'ffmpeg' -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
$p.Id | Out-File -FilePath $PidFile -Encoding ascii
Notify 'Recording... (hotkey again = stop)'
exit 0
