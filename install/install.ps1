# Kannaka one-shot installer (Windows).
#
# Binary-FIRST and Claude-OPTIONAL: the kannaka memory engine is a standalone
# binary that works with or without Claude Code. This installer always installs
# the binary first (the only hard requirement is being able to download it),
# puts it on PATH, and verifies it runs. THEN, if Claude Code is detected, it
# wires up the plugin + live statusline as a bonus — and if it isn't, it says so
# and finishes successfully rather than failing.
#
# Use -WithClaude to also install Node.js + Claude Code when they're missing
# (opt-in; off by default so standalone users aren't forced into a Node/Claude
# install they didn't ask for).
#
# Idempotent — safe to re-run. The .msi wraps this; you can also run it directly:
#   irm https://raw.githubusercontent.com/kannaka-labs/kannaka-plugin/master/install/install.ps1 | iex
[CmdletBinding()]
param(
  [string]$ReleaseRepo = "kannaka-labs/kannaka-memory",
  [string]$TuiRepo = "kannaka-labs/kannaka-tui",
  [switch]$WithClaude,
  [switch]$SkipStatusline,
  [switch]$SkipTui,
  # Constellation Pass credentials. Also read from the environment so the
  # portal can hand a subscriber one line that works, and so a re-run without
  # them leaves existing credentials alone rather than clearing them.
  [string]$NatsUser = $env:KANNAKA_NATS_USER,
  [string]$NatsPassword = $env:KANNAKA_NATS_PASSWORD,
  # Link the pass without typing a secret. See Get-ClaimCredentials.
  [switch]$Claim,
  # Link a pass on a machine that already has the engine. What the
  # double-clickable launcher runs, so it must not re-download binaries.
  [switch]$ClaimOnly,
  [string]$PortalApi = $(if ($env:KANNAKA_PORTAL_API) { $env:KANNAKA_PORTAL_API } else { "https://ninja-portal.com" }),
  # The constellation manifest: one document naming every component's pinned
  # release, asset URL and sha256. See Get-Manifest.
  [string]$ManifestUrl = $(if ($env:KANNAKA_MANIFEST) { $env:KANNAKA_MANIFEST } else { "https://ninja-portal.com/constellation.json" }),
  [switch]$NoManifest,
  [switch]$SkipHdl,
  # local | hosted — what `kannaka ask` answers with. Neither unless asked.
  [ValidateSet("", "local", "hosted", "none")][string]$Brain = "",
  [string]$Email = $env:KANNAKA_BRAIN_EMAIL
)

$InstallUrl = "https://raw.githubusercontent.com/kannaka-labs/kannaka-plugin/master/install/install.ps1"

function Say($m)  { Write-Host "▸ $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Say "Kannaka installer"

# ───────────────────────────────────────────────────────────────────────────
# 1. CORE: the kannaka binary → ~/.local/bin
#    This is the product. It needs nothing but the ability to download a file —
#    no Node, no Claude. Errors here are fatal (the install genuinely failed);
#    everything AFTER this is best-effort enhancement.
# ───────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$dest = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Download one release asset, refuse to install it unverified, and swap it into
# place even if the old copy is running.
#
# Was inline for the single binary; a second one (the TUI) made copying it the
# obvious move and the wrong one — a checksum check that exists twice is a
# checksum check that gets weakened once. Throws on any failure so the caller
# decides whether that is fatal; every failure path removes the partial file.

# ───────────────────────────────────────────────────────────────────────────
# THE MANIFEST
#
# constellation.json names every component's pinned release, each asset's URL
# and its sha256. Reading it first makes an install a COHERENT SET rather than
# whatever each repo's `latest` happened to be when each download ran.
#
# The ed25519 signature is verified when .NET can do it (Ed25519 is not in
# .NET's built-in crypto, so this is best-effort and usually reports
# "unsigned"); the real guarantee is per-asset: every file installed is checked
# against the sha256 the manifest carries, over TLS, so a tampered manifest
# cannot land an unverified binary.
# ───────────────────────────────────────────────────────────────────────────
$script:Manifest = $null
$script:ManifestState = "none"

function Get-Manifest {
  param([string]$Url)
  if ($NoManifest) { Say "Manifest skipped (-NoManifest); using each repo's latest release."; return }
  # The fallback is a RELEASE asset, not a Pages URL: when the constellation moved
  # into an organisation every other URL shape redirected and Pages did not.
  foreach ($u in @($Url, "https://github.com/kannaka-labs/kannaka-library/releases/download/library/constellation.json")) {
    try {
      $raw = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20).Content
      $m = $raw | ConvertFrom-Json
      if ($m.schema -ne "kannaka-constellation/1") { throw "not a constellation manifest" }
      $script:Manifest = $m
      $script:ManifestState = "unsigned"
      Ok ("Manifest loaded (unsigned check, generated " + $m.generated + ")")
      return
    } catch {
      Write-Verbose "manifest $u failed: $_"
    }
  }
  Warn "Could not fetch the constellation manifest — falling back to each repo's latest release."
}

# Returns @{ url; sha256; version } for a component's asset on this platform,
# or $null when the manifest does not have it.
function Get-PinnedAsset {
  param([string]$Component, [string]$Target)
  if (-not $script:Manifest) { return $null }
  $c = $script:Manifest.components | Where-Object { $_.id -eq $Component } | Select-Object -First 1
  if (-not $c -or -not $c.assets) { return $null }
  $a = $c.assets | Where-Object { $_.target -eq $Target } | Select-Object -First 1
  if (-not $a -or -not $a.sha256) { return $null }
  return @{ url = $a.url; sha256 = $a.sha256; version = $(if ($c.release) { $c.release.version } else { "pinned" }) }
}

# Download a pinned asset and verify it against the manifest's digest. Falls
# back to Install-Verified (latest + .sha256 sidecar) when unpinned, so a new
# component works before the manifest knows about it.
function Install-Pinned {
  param(
    [Parameter(Mandatory)][string]$Component,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Asset,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Label
  )
  $pin = Get-PinnedAsset -Component $Component -Target "windows-x86_64"
  if (-not $pin) { Install-Verified -Repo $Repo -Asset $Asset -Target $Target -Label $Label; return }

  $old = "$Target.old"
  if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction Stop } catch {} }
  $tmp = Join-Path $env:TEMP ("kannaka-download-" + [guid]::NewGuid().ToString("N") + ".exe")
  Say "Downloading $Label $($pin.version) (pinned)…"
  try {
    Invoke-WebRequest -Uri $pin.url -OutFile $tmp -UseBasicParsing
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "Failed to download $Label from $($pin.url). ($_)"
  }
  $got = (Get-FileHash $tmp -Algorithm SHA256).Hash
  if ($pin.sha256.ToLower() -ne $got.ToLower()) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "$Label sha256 mismatch against the manifest (expected $($pin.sha256), got $got)"
  }
  Say "sha256 verified against the manifest"
  try {
    Move-Item -Force $tmp $Target -ErrorAction Stop
  } catch {
    Move-Item -Force $Target $old -ErrorAction Stop
    Move-Item -Force $tmp $Target -ErrorAction Stop
  }
  Ok "$Label $($pin.version) installed → $Target"
}

function Install-Verified {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Asset,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Label
  )
  $b = "https://github.com/$Repo/releases/latest/download"
  $old = "$Target.old"
  if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction Stop } catch {} }
  # A GUID temp name per download: a shared one raced when two installs
  # overlapped and would have verified the wrong file against the wrong digest.
  $tmp = Join-Path $env:TEMP ("kannaka-download-" + [guid]::NewGuid().ToString("N") + ".exe")

  Say "Downloading $Label ($Asset)…"
  try {
    Invoke-WebRequest -Uri "$b/$Asset" -OutFile $tmp -UseBasicParsing
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "Failed to download $Asset from $b — check your internet connection. ($_)"
  }

  # The release always publishes a per-file .sha256 (Sigstore + checksums
  # trust). A MISSING checksum means we cannot verify — fail closed rather than
  # install an unverified binary. (A failed fetch used to warn and skip.)
  $want = $null
  try {
    $want = (((Invoke-WebRequest -Uri "$b/$Asset.sha256" -UseBasicParsing).Content) -split '\s+')[0]
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "checksum $Asset.sha256 could not be downloaded — refusing to install unverified. ($_)"
  }
  if (-not $want) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "checksum $Asset.sha256 was empty — refusing to install unverified."
  }
  $got = (Get-FileHash $tmp -Algorithm SHA256).Hash
  if ($want.ToLower() -ne $got.ToLower()) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "$Label sha256 mismatch (expected $want, got $got)"
  }
  Say "sha256 verified"

  # Swap into place, handling the exe being locked because it is running.
  try {
    Move-Item -Force $tmp $Target -ErrorAction Stop
  } catch {
    Move-Item -Force $Target $old -ErrorAction Stop
    Move-Item -Force $tmp $Target -ErrorAction Stop
    Say "existing $Label was in use — parked as $(Split-Path $old -Leaf) (cleaned up on next run)"
  }
  Ok "$Label installed → $Target"
}

$exe = Join-Path $dest "kannaka.exe"
if (-not $ClaimOnly) {
  Get-Manifest -Url $ManifestUrl
  Install-Pinned -Component "kannaka" -Repo $ReleaseRepo -Asset "kannaka-windows-x86_64.exe" -Target $exe -Label "kannaka"
}

# ───────────────────────────────────────────────────────────────────────────
# 2. PATH: make sure ~/.local/bin is reachable, or `kannaka` will look like it
#    "did nothing" on a fresh machine (the #1 silent-failure cause).
# ───────────────────────────────────────────────────────────────────────────
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ';') -notcontains $dest) {
  [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(';')) + ";" + $dest), "User")
  Say "Added $dest to your PATH — open a NEW terminal for `kannaka` to be found."
}
if (($env:Path -split ';') -notcontains $dest) { $env:Path = "$env:Path;$dest" }

# Verify the binary actually runs (surfaces a broken download instead of silence).
try {
  $ver = & $exe --version 2>$null | Select-Object -First 1
  if ($ver) { Ok "kannaka is working: $ver" }
} catch { Warn "kannaka installed but '--version' failed to run ($_)" }

# ───────────────────────────────────────────────────────────────────────────
# 2b. THE DASHBOARD: kannaka-tui.exe → ~/.local/bin
#
# Its own repo and releases since the binary was extracted at v0.5.12, with the
# same asset naming, so it rides the same verified download. NOT fatal: the
# engine is the product and a missing dashboard must not cost somebody an
# otherwise working install — hence the try/catch around a function that
# throws.
#
# (consciousness-core is deliberately absent. It is a LIBRARY — no [[bin]], no
# main.rs — compiled into kannaka.exe above, so anyone who has kannaka already
# has its physics. There is nothing separate to install.)
# ───────────────────────────────────────────────────────────────────────────
$tui = Join-Path $dest "kannaka-tui.exe"
if (-not $SkipTui -and -not $ClaimOnly) {
  try {
    Install-Pinned -Component "kannaka-tui" -Repo $TuiRepo -Asset "kannaka-tui-windows-x86_64.exe" -Target $tui -Label "kannaka-tui"
  } catch {
    Warn "kannaka-tui was not installed — the engine is fine; re-run to retry. ($_)"
  }
}

# ───────────────────────────────────────────────────────────────────────────
# 2b-ii. THE LANGUAGE: kannaka-hdl.exe → ~/.local/bin
#
# KannakaHDL grows an architecture against a registry of what a machine
# actually has and refuses when a part has no honest answer. It is what the
# `mind` app runs to ask "is this citizen whole?", so it ships with the engine
# rather than as a separate errand. Not fatal.
# ───────────────────────────────────────────────────────────────────────────
$hdl = Join-Path $dest "kannaka-hdl.exe"
if (-not $SkipHdl -and -not $ClaimOnly) {
  try {
    Install-Pinned -Component "kannaka-hdl" -Repo "kannaka-labs/kannaka-hdl" -Asset "kannaka-hdl-windows-x86_64.exe" -Target $hdl -Label "kannaka-hdl"
  } catch {
    Warn "kannaka-hdl was not installed — the engine is fine; re-run to retry. ($_)"
  }
}

# ───────────────────────────────────────────────────────────────────────────
# 2c. CONSTELLATION PASS: authenticated swarm credentials.
#
# `kannaka swarm serve` and `listen --auto-sync` need an AUTHENTICATED NATS
# connection; anonymous is read-only. The binary reads NATS_USER /
# NATS_PASSWORD from the ENVIRONMENT (src/nats.rs — precedence: explicit > env
# > url), and nothing ever put them there for a person.
#
# The POSIX installer writes ~/.kannaka-nats.env and teaches the shell rc to
# source it. Windows has no rc to source, so the native equivalent is a
# USER-level environment variable: it reaches PowerShell, cmd, AND Git Bash,
# because Git Bash inherits the Windows user environment rather than keeping
# its own. One mechanism covers all three terminals a Windows subscriber
# actually uses, which a dotfile in $HOME would not — nothing on Windows reads
# that file automatically.
#
# Persisted at "User" scope rather than "Machine": these are one person's
# credentials, and Machine scope would hand them to every account on the box
# and require elevation to write.
# ───────────────────────────────────────────────────────────────────────────
# Collect credentials without ever putting one on a command line.
#
# -NatsUser/-NatsPassword work and are kept, but they write both secrets into
# PSReadLine history and into the process table. -Claim asks the portal for a
# claim, shows a SHORT code, and waits while the subscriber approves it on
# their pass page. Nothing secret is typed and nothing secret is echoed.
#
# Best-effort: a portal that is down or a person who wanders off must not cost
# somebody a working engine, so every failure warns and falls through to the
# anonymous read-only swarm.
function Get-ClaimCredentials {
  param([string]$Api)
  try {
    $s = Invoke-RestMethod -Method Post -Uri "$Api/api/claim/start" -ContentType 'application/json' -Body '{}'
  } catch { Warn "could not reach $Api ($_)"; return $null }
  if (-not $s.claim_id -or -not $s.user_code) { Warn "the portal did not return a claim"; return $null }

  Write-Host ""
  Say "To link your Constellation Pass, open:"
  Say "    $(if ($s.verify_url) { $s.verify_url } else { "$Api/link" })"
  Say "and enter this code:"
  Write-Host ""
  Write-Host "        $($s.user_code)" -ForegroundColor White
  Write-Host ""
  Say "Waiting for approval (Ctrl-C to skip)…"

  # ~10 minutes at 5s, matching the claim's own TTL so the loop and the server
  # stop caring at the same moment.
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 5
    try {
      $p = Invoke-RestMethod -Method Post -Uri "$Api/api/claim/poll" -ContentType 'application/json' `
             -Body (@{ claim_id = $s.claim_id } | ConvertTo-Json -Compress)
    } catch { continue }   # a 404 means expired; handled by the timeout below
    if ($p.status -eq 'approved') {
      if (-not $p.nats_user -or -not $p.nats_password) { Warn "approval returned no credentials"; return $null }
      Ok "Pass linked as $($p.nats_user)"
      return @{ User = $p.nats_user; Password = $p.nats_password }
    }
  }
  Warn "no approval within ten minutes — re-run with -Claim to try again"
  return $null
}

if ($ClaimOnly) { $Claim = $true }
if ($Claim -and (-not $NatsUser -or -not $NatsPassword)) {
  $c = Get-ClaimCredentials -Api $PortalApi
  if ($c) { $NatsUser = $c.User; $NatsPassword = $c.Password }
}

if ($NatsUser -and $NatsPassword) {
  [Environment]::SetEnvironmentVariable("NATS_USER", $NatsUser, "User")
  [Environment]::SetEnvironmentVariable("NATS_PASSWORD", $NatsPassword, "User")
  # Also for THIS session, so the summary below reports the credentials rather
  # than which terminal we happen to be running in.
  $env:NATS_USER = $NatsUser
  $env:NATS_PASSWORD = $NatsPassword
  Ok "Constellation Pass credentials saved to your user environment"
  Say "Open a NEW terminal for them to take effect elsewhere."
} elseif ([Environment]::GetEnvironmentVariable("NATS_USER", "User")) {
  Say "Constellation Pass credentials already present in your user environment"
  if (-not $env:NATS_USER) {
    $env:NATS_USER = [Environment]::GetEnvironmentVariable("NATS_USER", "User")
  }
} elseif (-not $ClaimOnly) {
  # ── The double-clickable way to link a pass ────────────────────────────────
  #
  # The .msi runs this script from a custom action, where there is no console:
  # a claim shows a code and then polls, and neither can happen inside a
  # graphical installer. So the engine installs, and the LINKING is left as one
  # thing to double-click.
  #
  # A .cmd rather than a .ps1: double-clicking a .ps1 opens it in Notepad by
  # default (and ExecutionPolicy may refuse it anyway), while a .cmd just runs.
  # It removes itself once the pass is linked, so it is litter for exactly as
  # long as it is useful.
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = $HOME }
  $launcher = Join-Path $desk 'Link Kannaka.cmd'
  @"
@echo off
REM Links your Constellation Pass to this machine. Double-click me.
REM Deletes itself once the pass is linked.
echo.
echo   Linking your Constellation Pass...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm $InstallUrl))) -ClaimOnly"
if errorlevel 1 (
  echo.
  echo   That did not complete. You can double-click this again to retry.
) else (
  echo.
  echo   Done. You can close this window.
  del "%~f0"
)
pause
"@ | Set-Content -Path $launcher -Encoding ASCII
  Write-Host ""
  Ok "Engine installed. One step left: your Constellation Pass is not linked yet."
  Say "Double-click `"Link Kannaka.cmd`" on your Desktop to finish."
}


# ───────────────────────────────────────────────────────────────────────────
# 2d. THE BRAIN: what `kannaka ask` answers with.
#
#   -Brain local    the open weights under ollama. Free, offline, ~4.7 GB.
#   -Brain hosted   a budgeted key against ninja-portal.com/v1, mailed to
#                   -Email. The gateway meters it; nothing here can overspend.
#
# Neither happens unless asked for, and an existing [llm] section is left alone
# unless -Brain was passed, so a re-run cannot silently repoint a machine that
# was already configured.
# ───────────────────────────────────────────────────────────────────────────
$kconf = Join-Path $HOME ".kannaka\config.toml"

function Write-LlmConfig {
  param([string]$Provider, [string]$Model, [string]$Key, [string]$BaseUrl)
  $dir = Split-Path $kconf -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $kept = @()
  if (Test-Path $kconf) {
    $skip = $false
    foreach ($line in (Get-Content $kconf)) {
      if ($line -match '^\s*\[llm\]\s*$') { $skip = $true; continue }
      elseif ($line -match '^\s*\[') { $skip = $false }
      if (-not $skip) { $kept += $line }
    }
  }
  $kept += @("", "[llm]", "provider = `"$Provider`"", "model = `"$Model`"", "api_key = `"$Key`"", "base_url = `"$BaseUrl`"")
  Set-Content -Path $kconf -Value $kept -Encoding utf8
}

function Set-BrainLocal {
  if (-not (Have "ollama")) { Warn "-Brain local needs ollama (https://ollama.com/download); skipping."; return }
  $model = "kannaka-brain"; $from = "hf.co/flaukowski/kannaka-brain-7b-v1-GGUF"
  if ($script:Manifest) {
    $b = $script:Manifest.components | Where-Object { $_.kind -eq "model" } | Select-Object -First 1
    if ($b -and $b.local) { $model = $b.local.model; $from = $b.local.from }
  }
  $have = $false
  try { $have = ((& ollama list 2>$null) -join "`n") -match ("(?m)^" + [regex]::Escape($model) + ":") } catch {}
  if ($have) {
    Ok "ollama already has $model"
  } else {
    Say "Pulling $from as $model (about 4.7 GB — this takes a while)…"
    try {
      & ollama pull $from *> $null
      & ollama cp $from $model *> $null
      Ok "local brain ready: $model"
    } catch { Warn "ollama could not pull $from; skipping the local brain. ($_)"; return }
  }
  $host_url = if ($env:OLLAMA_HOST) { $env:OLLAMA_HOST } else { "http://127.0.0.1:11434" }
  Write-LlmConfig -Provider "openai" -Model $model -Key "ollama" -BaseUrl "$host_url/v1"
  Ok "kannaka ask → local $model"
}

function Set-BrainHosted {
  if (-not $Email) { Warn "-Brain hosted needs -Email you@example.com (the key is mailed there); skipping."; return }
  $baseUrl = "$PortalApi/v1"; $model = "kannaka-brain-7b-v1"
  if ($script:Manifest) {
    $b = $script:Manifest.components | Where-Object { $_.kind -eq "model" } | Select-Object -First 1
    if ($b -and $b.hosted) {
      if ($b.hosted.base_url) { $baseUrl = $b.hosted.base_url }
      if ($b.hosted.models -and $b.hosted.models.Count -gt 0) { $model = $b.hosted.models[-1] }
    }
  }
  Say "Requesting a hosted brain key for $Email…"
  try {
    $r = Invoke-RestMethod -Method Post -Uri "$PortalApi/api/brain/key" -ContentType 'application/json' `
           -Body (@{ email = $Email; purpose = "installer" } | ConvertTo-Json -Compress)
  } catch {
    Warn "The portal did not issue a key — get one at $PortalApi/brain. ($_)"
    return
  }
  if (-not $r.key) { Warn "The portal did not return a key. See $PortalApi/brain"; return }
  Write-LlmConfig -Provider "openai" -Model $model -Key $r.key -BaseUrl $baseUrl
  Ok "kannaka ask → hosted $model at $baseUrl"
  Say "The key is budgeted and rate-limited by the gateway; usage at $PortalApi/brain#key"
}

if (-not $ClaimOnly) {
  switch ($Brain) {
    "local"  { Set-BrainLocal }
    "hosted" { Set-BrainHosted }
    default  {
      if ((Test-Path $kconf) -and ((Get-Content $kconf -Raw) -match '(?m)^\s*\[llm\]')) {
        Say "Brain: leaving the [llm] section of $kconf as it is."
      } else {
        Write-Host ""
        Say "No brain configured yet. 'kannaka ask' needs one:"
        Say "    re-run with  -Brain local                  (open weights under ollama, free)"
        Say "    re-run with  -Brain hosted -Email you@…    (a budgeted key on our gateway)"
      }
    }
  }
}

# ───────────────────────────────────────────────────────────────────────────
# 3. OPTIONAL: Claude Code integration. Detect-and-enhance. Never fatal.
# ───────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Continue"   # nothing below should abort a done install

if (-not (Have claude) -and $WithClaude) {
  Say "-WithClaude set — installing Node.js + Claude Code…"
  if (-not (Have node)) {
    if (Have winget) {
      winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
      $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    } else {
      Warn "winget not available — install Node.js from https://nodejs.org/ then re-run with -WithClaude."
    }
  }
  if (Have npm) { npm install -g @anthropic-ai/claude-code }
}

if (Have claude) {
  Say "Claude Code detected — registering marketplace + installing plugin…"
  try {
    claude plugin marketplace add kannaka-labs/kannaka-plugin 2>$null | Out-Null
    claude plugin install kannaka@kannaka 2>$null | Out-Null
    Ok "kannaka plugin installed into Claude Code"
  } catch { Warn "plugin registration reported: $_" }

  if (-not $SkipStatusline) {
    $setup = Get-ChildItem -Path (Join-Path $HOME ".claude\plugins\cache\kannaka") -Recurse -Filter setup.sh -ErrorAction SilentlyContinue |
             Sort-Object -Property @{Expression={
               $v = $null
               if ($_.FullName -match '(\d+\.\d+(\.\d+)?(\.\d+)?)') { try { $v = [version]$Matches[1] } catch {} }
               if ($v) { $v } else { [version]"0.0" }
             }}, LastWriteTime | Select-Object -Last 1
    if ($setup -and (Have bash)) {
      Say "Enabling statusline…"
      bash ($setup.FullName -replace '\\','/') on
    } else {
      Say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."
    }
  }
} else {
  Write-Host ""
  Ok "Kannaka is installed and works standalone — no Claude Code required."
  Say "Try it:"
  Say "    kannaka remember `"wave interference is how memory computes`" --importance 0.8"
  Say "    kannaka recall `"how does memory work`""
  Say "    kannaka dream --mode deep"
  Write-Host ""
  Say "Want the Claude Code plugin + live statusline too? Install Claude Code, then re-run this"
  Say "installer (or pass -WithClaude), or inside Claude run:"
  Say "    claude plugin marketplace add kannaka-labs/kannaka-plugin"
  Say "    claude plugin install kannaka@kannaka"
}

Write-Host ""
Ok "Done. kannaka.exe → $exe"
if (Test-Path $tui) { Ok "     kannaka-tui.exe → $tui" }
if (Test-Path $hdl) { Ok "     kannaka-hdl.exe → $hdl" }
if ($script:ManifestState -ne "none") { Ok "     versions pinned by the constellation manifest" }
if ($env:NATS_USER) {
  Ok "     Constellation Pass: authenticated as $env:NATS_USER"
} else {
  Write-Host ""
  Say "Swarm access is ANONYMOUS (read-only). A Constellation Pass unlocks"
  Say "'kannaka swarm serve' and 'listen --auto-sync'. To link yours:"
  # `irm | iex` cannot take parameters — iex evaluates the text and the script's
  # param() block never sees the arguments. Rebuilding it as a scriptblock and
  # invoking THAT is the form that actually passes them.
  Say "    & ([scriptblock]::Create((irm $InstallUrl))) -Claim"
  Say "It shows a short code to approve on your pass page — no password typed"
  Say "into a terminal, and nothing secret left in your history."
}
