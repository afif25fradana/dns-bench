#Requires -Version 5.1

param(
    [int]$Rounds = 8,
    [string[]]$Servers,
    [string[]]$Domains = @(
        'www.google.com',
        'www.cloudflare.com',
        'www.wikipedia.org',
        'github.com',
        'www.microsoft.com',
        'www.amazon.com',
        'www.youtube.com'
    )
)

$ErrorActionPreference = 'SilentlyContinue'

$knownProviders = @{
    '1.1.1.1'         = 'Cloudflare'
    '1.0.0.1'         = 'Cloudflare (Sec)'
    '1.1.1.2'         = 'Cloudflare Malware'
    '1.0.0.2'         = 'Cloudflare Malware (Sec)'
    '8.8.8.8'         = 'Google'
    '8.8.4.4'         = 'Google (Sec)'
    '9.9.9.9'         = 'Quad9 (Malware Block)'
    '149.112.112.112' = 'Quad9 (Sec)'
    '208.67.222.222'  = 'OpenDNS'
    '208.67.220.220'  = 'OpenDNS (Sec)'
    '94.140.14.14'    = 'AdGuard'
    '94.140.15.15'    = 'AdGuard (Sec)'
}

# Resolve target servers to benchmark
$targetList = [System.Collections.Generic.List[psobject]]::new()

if ($PSBoundParameters.ContainsKey('Servers') -and $Servers.Count -gt 0) {
    foreach ($s in $Servers) {
        $pName = if ($knownProviders.ContainsKey($s)) { $knownProviders[$s] } else { 'Custom' }
        $targetList.Add([pscustomobject]@{ Provider = $pName; IP = $s })
    }
} else {
    # Detect active system DNS servers from network adapter
    $systemDnsList = @()
    try {
        $systemDnsList = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            Select-Object -ExpandProperty ServerAddresses -Unique)
    } catch {}

    foreach ($sysIp in $systemDnsList) {
        if ($sysIp -and $sysIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
            $label = if ($knownProviders.ContainsKey($sysIp)) {
                "Current System ($($knownProviders[$sysIp]))"
            } else {
                "Current System (ISP/Local)"
            }
            $targetList.Add([pscustomobject]@{ Provider = $label; IP = $sysIp })
        }
    }

    $defaultPublic = @(
        [pscustomobject]@{ Provider = 'Cloudflare';                IP = '1.1.1.1' },
        [pscustomobject]@{ Provider = 'Cloudflare (Sec)';          IP = '1.0.0.1' },
        [pscustomobject]@{ Provider = 'Cloudflare Malware';        IP = '1.1.1.2' },
        [pscustomobject]@{ Provider = 'Google';                    IP = '8.8.8.8' },
        [pscustomobject]@{ Provider = 'Google (Sec)';              IP = '8.8.4.4' },
        [pscustomobject]@{ Provider = 'Quad9 (Malware Block)';     IP = '9.9.9.9' },
        [pscustomobject]@{ Provider = 'Quad9 (Sec)';               IP = '149.112.112.112' },
        [pscustomobject]@{ Provider = 'OpenDNS';                   IP = '208.67.222.222' },
        [pscustomobject]@{ Provider = 'OpenDNS (Sec)';             IP = '208.67.220.220' },
        [pscustomobject]@{ Provider = 'AdGuard';                   IP = '94.140.14.14' },
        [pscustomobject]@{ Provider = 'AdGuard (Sec)';             IP = '94.140.15.15' }
    )

    foreach ($pub in $defaultPublic) {
        if (-not ($targetList | Where-Object { $_.IP -eq $pub.IP })) {
            $targetList.Add($pub)
        }
    }
}

# Pre-flight internet connectivity check
Write-Host "Checking internet connectivity..." -ForegroundColor Cyan
$online = $false
try {
    $test = Resolve-DnsName -Name 'www.google.com' -Type A -DnsOnly -ErrorAction Stop
    if ($test) { $online = $true }
} catch {
    $online = $false
}

if (-not $online) {
    Write-Warning "Could not resolve test domain. Please verify your internet connection."
    return
}

# Initialize data stores
$results = @{}
$fails   = @{}
foreach ($t in $targetList) {
    $results[$t.IP] = [System.Collections.Generic.List[double]]::new()
    $fails[$t.IP]   = 0
}

Write-Host ("Starting benchmark: {0} servers, {1} test rounds (+ 1 warm-up round)...`n" -f $targetList.Count, $Rounds) -ForegroundColor Cyan

# Run benchmark with interleaved queries (round-robin)
$totalRounds = $Rounds + 1
for ($r = 1; $r -le $totalRounds; $r++) {
    $domain = $Domains[($r - 1) % $Domains.Count]
    foreach ($t in $targetList) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $true
        try {
            Resolve-DnsName -Name $domain -Server $t.IP -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null
        } catch {
            $ok = $false
        }
        $sw.Stop()

        if ($ok) {
            if ($r -gt 1) { $results[$t.IP].Add($sw.Elapsed.TotalMilliseconds) }
        } else {
            $fails[$t.IP]++
        }
    }

    if ($r -eq 1) {
        Write-Host "Warm-up round finished (cache primed, discarded)" -ForegroundColor DarkGray
    } else {
        Write-Host ("Round {0}/{1} completed (domain: {2})" -f ($r - 1), $Rounds, $domain)
    }
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return [double]::NaN }
    $sorted = $Values | Sort-Object
    $mid = [math]::Floor(($sorted.Count - 1) / 2)
    if ($sorted.Count % 2 -ne 0) { return $sorted[$mid] }
    return ($sorted[$mid] + $sorted[$mid + 1]) / 2
}

# Aggregate metrics
$rows = foreach ($t in $targetList) {
    $arr = $results[$t.IP].ToArray()
    if ($arr.Count -gt 0) {
        [pscustomobject]@{
            Provider = $t.Provider
            Server   = $t.IP
            Samples  = $arr.Count
            Fail     = $fails[$t.IP]
            Min_ms   = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
            Med_ms   = [math]::Round((Get-Median -Values $arr), 1)
            Avg_ms   = [math]::Round(($arr | Measure-Object -Average).Average, 1)
            Max_ms   = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)
        }
    } else {
        [pscustomobject]@{
            Provider = $t.Provider
            Server   = $t.IP
            Samples  = 0
            Fail     = $fails[$t.IP]
            Min_ms   = -1
            Med_ms   = -1
            Avg_ms   = -1
            Max_ms   = -1
        }
    }
}

$rows = $rows | Sort-Object @{
    Expression = { if ($_.Samples -eq 0 -or $_.Med_ms -lt 0) { [double]::MaxValue } else { $_.Med_ms } }
    Ascending  = $true
}

Write-Host ""
Write-Host "=== RESULTS (Sorted by Median Latency) ===" -ForegroundColor Green
$rows | Format-Table -AutoSize

$best = @($rows | Where-Object { $_.Fail -eq 0 -and $_.Samples -gt 0 } | Select-Object -First 2)
if ($best.Count -ge 2) {
    Write-Host ("Recommended pair: Primary {0} ({1}) + Secondary {2} ({3})" -f $best[0].Server, $best[0].Provider, $best[1].Server, $best[1].Provider) -ForegroundColor Yellow
    Write-Host "Note: If you select a filtering provider (e.g. Quad9, Cloudflare Malware, AdGuard),"
    Write-Host "pair it with the secondary server from the same provider family to ensure consistent filtering."
} elseif ($best.Count -eq 1) {
    Write-Host ("Only one server completed without failure: {0} ({1}). Consider reviewing server availability." -f $best[0].Server, $best[0].Provider) -ForegroundColor Yellow
}

$csv = Join-Path $PSScriptRoot ("dns-bench-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("CSV report saved: {0}" -f $csv)
Write-Host "Tip: Differences in median latency under 15-20 ms are barely noticeable in normal browsing."
Write-Host "Choose based on features (malware blocking/privacy) unless latency differences are significant."
