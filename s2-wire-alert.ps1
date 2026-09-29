# S2 Underground "The Wire" -> Pushover / ntfy phone alert
# Checks the podcast RSS feed and pushes a notification for new episodes
# whose title contains Priority, Urgent or Flash.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1                # normal run
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1 -DryRun        # show matches, send nothing
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1 -Test          # send a Priority-style test
#   powershell -ExecutionPolicy Bypass -File s2-wire-alert.ps1 -Test -Urgent  # send an Urgent/Flash-style test

param(
    [switch]$DryRun,
    [switch]$Test,
    [switch]$Urgent
)

# --- Settings ---------------------------------------------------------------
# Keys come from environment variables / GitHub secrets (never hard-code them
# in a public repo). Pushover is used when its token and user key are set;
# ntfy is used when NTFY_TOPIC is set. Both can be on at once.
$PushoverToken = $env:PUSHOVER_TOKEN
$PushoverUser  = $env:PUSHOVER_USER
# Sound names from https://pushover.net/api#sounds, or the name of a custom sound you uploaded.
$SoundPriority = if ($env:PUSHOVER_SOUND)        { $env:PUSHOVER_SOUND }        else { "siren" }
$SoundUrgent   = if ($env:PUSHOVER_SOUND_URGENT) { $env:PUSHOVER_SOUND_URGENT } else { "persistent" }
$Topic    = $env:NTFY_TOPIC
$Server   = "https://ntfy.sh"
$FeedUrl  = "https://feeds.buzzsprout.com/868255.rss"
$Keywords = @("Priority", "Urgent", "Flash")
$StateFile = Join-Path $PSScriptRoot "s2-wire-seen.txt"
# ----------------------------------------------------------------------------

$UsePushover = [bool]($PushoverToken -and $PushoverUser)
$UseNtfy     = [bool]$Topic
if (-not ($UsePushover -or $UseNtfy)) {
    throw "Set PUSHOVER_TOKEN + PUSHOVER_USER and/or NTFY_TOPIC."
}

function Send-Ntfy($title, $body, $level, $link) {
    $headers = @{ "Title" = $title; "Priority" = $level; "Tags" = "rotating_light" }
    if ($link) { $headers["Click"] = $link }
    Invoke-RestMethod -Method Post -Uri "$Server/$Topic" -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

function Send-Pushover($title, $body, $level, $link) {
    $form = @{
        token   = $PushoverToken
        user    = $PushoverUser
        title   = $title
        message = $body
    }
    if ($level -eq "urgent") {
        # Emergency: repeats every 60s until acknowledged, for up to 30 minutes.
        $form.priority = 2; $form.retry = 60; $form.expire = 1800
        $form.sound = $SoundUrgent
    } else {
        $form.priority = 1
        $form.sound = $SoundPriority
    }
    if ($link) { $form.url = $link; $form.url_title = "Open episode" }
    Invoke-RestMethod -Method Post -Uri "https://api.pushover.net/1/messages.json" -Body $form | Out-Null
}

function Send-Alert($title, $body, $level, $link) {
    if ($UsePushover) { Send-Pushover $title $body $level $link }
    if ($UseNtfy)     { Send-Ntfy     $title $body $level $link }
}

if ($Test) {
    $level = if ($Urgent) { "urgent" } else { "high" }
    Send-Alert "S2 Wire alert test" "If you see this, alerts are working." $level $null
    Write-Output "Test sent via: $(@(if ($UsePushover) {'Pushover'}; if ($UseNtfy) {'ntfy'}) -join ', ')"
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
        Send-Alert $title $desc $level $link
        Write-Output "[sent] $title"
    }
}

if (-not $DryRun) {
    $newSeen | Select-Object -Unique | Set-Content $StateFile
}
