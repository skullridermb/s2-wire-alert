# S2 Underground "The Wire" -> ntfy phone alert
# Checks the podcast RSS feed and pushes a notification for new episodes
# whose title contains Priority, Urgent or Flash.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1            # normal run
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1 -DryRun    # show matches, send nothing
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1 -Test      # send one test push

param(
    [switch]$DryRun,
    [switch]$Test
)

# --- Settings ---------------------------------------------------------------
# Topic comes from the NTFY_TOPIC secret (never hard-code it in a public repo).
$Topic    = $env:NTFY_TOPIC
if (-not $Topic) { throw "Set the NTFY_TOPIC environment variable / GitHub secret." }
$Server   = "https://ntfy.sh"
$FeedUrl  = "https://feeds.buzzsprout.com/868255.rss"
$Keywords = @("Priority", "Urgent", "Flash")
$StateFile = Join-Path $PSScriptRoot "s2-wire-seen.txt"
# ----------------------------------------------------------------------------

function Send-Ntfy($title, $body, $priority, $link) {
    $headers = @{ "Title" = $title; "Priority" = $priority; "Tags" = "rotating_light" }
    if ($link) { $headers["Click"] = $link }
    Invoke-RestMethod -Method Post -Uri "$Server/$Topic" -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

if ($Test) {
    Send-Ntfy "S2 Wire alert test" "If you see this, alerts are working." "high" $null
    Write-Output "Test notification sent to $Server/$Topic"
    return
}

[xml]$feed = (Invoke-WebRequest -Uri $FeedUrl -UseBasicParsing).Content
$items = $feed.rss.channel.item

$firstRun = -not (Test-Path $StateFile)
$seen = if ($firstRun) { @() } else { Get-Content $StateFile }

$pattern = "\b(" + ($Keywords -join "|") + ")\b"
$newSeen = @()

foreach ($item in $items) {
    $id = if ($item.guid.'#text') { $item.guid.'#text' } else { [string]$item.guid }
    $newSeen += $id
    if ($seen -contains $id) { continue }

    # Items carry both <title> and <itunes:title>; take the first.
    $title = [string](@($item.title)[0])
    if ($title -notmatch "^The Wire" -or $title -notmatch $pattern) { continue }

    $level = if ($title -match "\b(Flash|Urgent)\b") { "urgent" } else { "high" }
    $link  = [string]$item.link
    $desc  = ([string]$item.description) -replace "<[^>]+>", " " -replace "\s+", " "
    if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) + "..." }

    if ($DryRun) {
        Write-Output "[match] $title"
    } elseif ($firstRun) {
        # Don't blast old episodes the very first time; just remember them.
        Write-Output "[first run, skipped] $title"
    } else {
        Send-Ntfy $title $desc $level $link
        Write-Output "[sent] $title"
    }
}

if (-not $DryRun) {
    $newSeen | Select-Object -Unique | Set-Content $StateFile
}
