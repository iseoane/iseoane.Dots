# $PSScriptRoot is reliably set to this profile's own directory (Documents\WindowsPowerShell)
# since PS 3.0, even though the file is dot-sourced by the host at startup rather than run
# directly -- so a relative Join-Path off it is safe here.
$herdrWtScript = Join-Path $PSScriptRoot "Scripts\herdr-wt.ps1"
if (Test-Path $herdrWtScript) {
    . $herdrWtScript
}

# PowerShell aliases can't carry arguments like bash's `alias x='cmd --flag'`, so these thin
# wrapper functions stand in for the bash aliases (lswt/crwt/openwt/rmwt).
function lswt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtLs @rest }
function crwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtCr @rest }
function openwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtOpen @rest }
function rmwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtRm @rest }
function oc { param([Parameter(ValueFromRemainingArguments = $true)]$rest) & opencode --auto @rest }
