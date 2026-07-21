# Play a notification sound on agent state changes (done / blocked).
# Invoked by herdr as a `pane.agent_status_changed` event handler. The event
# payload arrives in $env:HERDR_PLUGIN_EVENT_JSON; the plugin dir is
# $env:HERDR_PLUGIN_ROOT.
#
# Why this exists: herdr's built-in Windows player (src/sound.rs) invokes its
# WPF script with -Command and a trailing positional arg, which PowerShell does
# NOT bind to param($Path), so the native sound never plays (issue #1657). Here
# we control the invocation (-File) and read the path ourselves, so it works.

$ErrorActionPreference = 'Stop'

$json = $env:HERDR_PLUGIN_EVENT_JSON
if ([string]::IsNullOrWhiteSpace($json)) { exit 0 }

try { $evt = $json | ConvertFrom-Json } catch { exit 0 }

$status = "$($evt.agent_status)".ToLowerInvariant()
switch ($status) {
    'done'    { $file = 'done.mp3' }
    'blocked' { $file = 'request.mp3' }
    default   { exit 0 }   # ignore idle / working / unknown transitions
}

$root = $env:HERDR_PLUGIN_ROOT
if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $PSScriptRoot }
$path = Join-Path (Join-Path $root 'sounds') $file
if (-not (Test-Path -LiteralPath $path)) { exit 0 }

Add-Type -AssemblyName PresentationCore
$player = [System.Windows.Media.MediaPlayer]::new()
$player.Open([Uri]::new((Resolve-Path -LiteralPath $path).ProviderPath))

# Wait until the media is loaded so we know its duration, then play for exactly
# that long. Using NaturalDuration instead of the MediaEnded event avoids the
# console-mode "timed out" hang the native script hits.
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not $player.NaturalDuration.HasTimeSpan -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 20
}
$player.Play()
if ($player.NaturalDuration.HasTimeSpan) {
    $ms = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds + 250
    Start-Sleep -Milliseconds ([Math]::Min($ms, 10000))
} else {
    Start-Sleep -Milliseconds 1500
}
$player.Close()
