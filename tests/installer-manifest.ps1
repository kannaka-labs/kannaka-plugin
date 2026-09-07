# installer-manifest.ps1 — exercise install.ps1's manifest and brain-config
# logic without running an install.
#
# The functions are lifted out of the real installer (not copied into this
# file) so the test cannot drift from the script it is testing: a change to
# Get-PinnedAsset or Write-LlmConfig is a change to what runs here.
#
#   pwsh -NoProfile -File tests/installer-manifest.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$src = Get-Content (Join-Path $root "install/install.ps1") -Raw

$fails = 0
function Check($name, $cond) {
  if ($cond) { Write-Host "  ok   $name" -ForegroundColor Green }
  else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fails++ }
}

# Pull the function definitions out by brace matching from `function <name> {`.
function Get-Fn($text, $name) {
  $i = $text.IndexOf("function $name")
  if ($i -lt 0) { throw "function $name not found in install.ps1" }
  $open = $text.IndexOf("{", $i)
  $depth = 0
  for ($j = $open; $j -lt $text.Length; $j++) {
    if ($text[$j] -eq '{') { $depth++ }
    elseif ($text[$j] -eq '}') { $depth--; if ($depth -eq 0) { return $text.Substring($i, $j - $i + 1) } }
  }
  throw "unbalanced braces in $name"
}

foreach ($fn in @("Get-PinnedAsset", "Write-LlmConfig")) {
  Invoke-Expression (Get-Fn $src $fn)
}

# ---- Get-PinnedAsset ------------------------------------------------------
$script:Manifest = @'
{ "schema": "kannaka-constellation/1", "components": [
  { "id": "kannaka", "release": { "version": "v9.9.9" }, "assets": [
      { "name": "kannaka-windows-x86_64.exe", "target": "windows-x86_64", "url": "https://example/win", "sha256": "aa" },
      { "name": "kannaka-linux-x86_64", "target": "linux-x86_64", "url": "https://example/lin", "sha256": "bb" } ] },
  { "id": "nohash", "release": { "version": "v1" }, "assets": [
      { "name": "x", "target": "windows-x86_64", "url": "https://example/x", "sha256": null } ] } ] }
'@ | ConvertFrom-Json

$pin = Get-PinnedAsset -Component "kannaka" -Target "windows-x86_64"
Check "pins the windows asset" ($pin.url -eq "https://example/win" -and $pin.sha256 -eq "aa" -and $pin.version -eq "v9.9.9")
Check "unknown component is unpinned" ($null -eq (Get-PinnedAsset -Component "absent" -Target "windows-x86_64"))
# An asset with no digest must NOT be treated as pinned: falling through to the
# latest-release path (which demands a .sha256 sidecar) is the safe answer.
Check "asset without sha256 is unpinned" ($null -eq (Get-PinnedAsset -Component "nohash" -Target "windows-x86_64"))
$script:Manifest = $null
Check "no manifest means unpinned" ($null -eq (Get-PinnedAsset -Component "kannaka" -Target "windows-x86_64"))

# ---- Write-LlmConfig ------------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kannaka-cfg-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
$kconf = Join-Path $tmp "config.toml"
Set-Content -Path $kconf -Encoding utf8 -Value @(
  '[agent]', 'id = "mine"', '', '[llm]', 'provider = "openai"', 'model = "OLD"', 'api_key = "OLDKEY"', '', '[swarm]', 'enabled = true')
Write-LlmConfig -Provider "openai" -Model "kannaka-brain" -Key "ollama" -BaseUrl "http://127.0.0.1:11434/v1"
$after = Get-Content $kconf -Raw
Check "keeps other sections" (($after -match '(?m)^\[agent\]') -and ($after -match '(?m)^\[swarm\]') -and ($after -match 'enabled = true'))
Check "drops the old llm values" (-not ($after -match "OLD") -and -not ($after -match "OLDKEY"))
Check "writes the new llm table once" (([regex]::Matches($after, '(?m)^\[llm\]')).Count -eq 1)
Check "writes the new model" (($after -match 'model = "kannaka-brain"') -and ($after -match 'base_url = "http://127.0.0.1:11434/v1"'))

# A config that has no [llm] at all must gain one without losing anything.
Set-Content -Path $kconf -Encoding utf8 -Value @('[agent]', 'id = "solo"')
Write-LlmConfig -Provider "openai" -Model "m" -Key "k" -BaseUrl "u"
$after2 = Get-Content $kconf -Raw
Check "appends llm when absent" (($after2 -match '(?m)^\[agent\]') -and ($after2 -match 'id = "solo"') -and ($after2 -match '(?m)^\[llm\]'))
Remove-Item $tmp -Recurse -Force

if ($fails) { Write-Host "$fails check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "installer manifest/brain checks passed" -ForegroundColor Green
