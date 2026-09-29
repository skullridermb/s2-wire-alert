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

$Channels = @()
if ($UsePushover) { $Channels += "pushover" }
if ($UseNtfy)     { $Channels += "ntfy" }

# Tries one channel; a failure is reported but never stops the other channels.
function Try-Send($name, $title, $body, $level, $link) {
    $ErrorActionPreference = "Stop"
    try {
        switch ($name) {
            "pushover" { Send-Pushover $title $body $level $link }
            "ntfy"     { Send-Ntfy     $title $body $level $link }
        }
        return $true
    } catch {
        # Write-Host, not Write-Output: output would become part of the return value.
        Write-Host "::warning::$name failed for '$title': $($_.Exception.Message)"
        return $false
    }
}

if ($Test) {
    $level = if ($Urgent) { "urgent" } else { "high" }
    $failed = @()
    foreach ($name in $Channels) {
        if (Try-Send $name "S2 Wire alert test" "If you see this, alerts are working." $level $null) {
            Write-Output "Test sent via $name"
        } else { $failed += $name }
    }
    if ($failed) { exit 1 }
    return
}

[xml]$feed = (Invoke-WebRequest -Uri $FeedUrl -UseBasicParsing).Content
$items = $feed.rss.channel.item

# State file: one line per record, kept forever (never rebuilt from the feed).
#   <guid>            episode fully handled (sent on every channel, or not a match)
#   <channel>|<guid>  episode delivered on that channel, others still pending
$firstRun = -not (Test-Path $StateFile)
$state = [System.Collections.Generic.List[string]]::new()
if (-not $firstRun) { Get-Content $StateFile | Where-Object { $_ } | ForEach-Object { $state.Add($_) } }
$known = [System.Collections.Generic.HashSet[string]]::new([string[]]$state)

function Remember($line) { if ($known.Add($line)) { $state.Add($line) } }

$pattern = "\b(" + ($Keywords -join "|") + ")\b"
$giveUpAfter = [TimeSpan]::FromHours(24)
$anyFailed = $false

foreach ($item in $items) {
    $id = if ($item.guid.'#text') { $item.guid.'#text' } else { [string]$item.guid }
    if (-not $id -or $known.Contains($id)) { continue }

    # Items carry both <title> and <itunes:title>; take the first.
    $title = [string](@($item.title)[0])
    if ($title -notmatch "^The Wire" -or $title -notmatch $pattern) {
        if (-not $DryRun) { Remember $id }
        continue
    }

    $level = if ($title -match "\b(Flash|Urgent)\b") { "urgent" } else { "high" }
    $link  = [string]$item.link
    $desc  = ([string]$item.description) -replace "<[^>]+>", " " -replace "\s+", " "
    if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) + "..." }

    if ($DryRun) { Write-Output "[match] $title"; continue }
    if ($firstRun) {
        # Don't blast old episodes the very first time; just remember them.
        Write-Output "[first run, skipped] $title"
        Remember $id
        continue
    }

    # Send on each channel that hasn't delivered this episode yet.
    $pending = @($Channels | Where-Object { -not $known.Contains("$_|$id") })
    foreach ($name in $pending) {
        if (Try-Send $name $title $desc $level $link) {
            Write-Output "[sent via $name] $title"
            Remember "$name|$id"
        }
    }

    $stillPending = @($Channels | Where-Object { -not $known.Contains("$_|$id") })
    if (-not $stillPending) {
        Remember $id
    } else {
        # Retry on the next run, but stop retrying a day after the episode came out.
        $published = try { [DateTimeOffset]::Parse([string]$item.pubDate) } catch { [DateTimeOffset]::MinValue }
        if ([DateTimeOffset]::UtcNow - $published -gt $giveUpAfter) {
            Write-Output "::warning::Giving up on $($stillPending -join ', ') for '$title' (older than 24h)"
            Remember $id
        } else {
            $anyFailed = $true
        }
    }
}

if (-not $DryRun) {
    # Monthly heartbeat line keeps the repo active even if S2 stops posting,
    # so GitHub never pauses the schedule for 60 days of inactivity.
    Remember ("heartbeat|" + [DateTime]::UtcNow.ToString("yyyy-MM"))
    $state | Set-Content $StateFile
}

# Fail the run (GitHub emails you) if any alert is still waiting to be retried.
if ($anyFailed) { exit 1 }
