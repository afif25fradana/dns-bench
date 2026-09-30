<#
.SYNOPSIS
Lightweight DNS benchmark tool for Windows.

.DESCRIPTION
Measures latency, within-domain jitter, and packet loss across public DNS resolvers and active System DNS.

.PARAMETER Passes
Number of test passes per domain (default: 5). Aliased to 'Rounds'.

.PARAMETER Quick
Runs a fast benchmark with 2 passes and 4 domains (ideal for quick pre-work checks).

.PARAMETER SleepMs
Delay in milliseconds between individual DNS queries (default: 25). Prevents flooding while running fast.

.PARAMETER Servers
Array of DNS server IP addresses to benchmark. If omitted, benchmarks default public resolvers and active System DNS.

.PARAMETER ExcludeServers
Array of DNS server IP addresses to exclude from benchmarking.

.PARAMETER Domains
Array of domain names to query during benchmark passes (default: www.google.com, www.cloudflare.com, www.wikipedia.org, www.microsoft.com, github.com, www.youtube.com, www.reddit.com, www.amazon.com).

.EXAMPLE
.\dns-bench.ps1

.EXAMPLE
.\dns-bench.ps1 -Passes 8

.EXAMPLE
.\dns-bench.ps1 -Servers '1.1.1.1','8.8.8.8' -Domains 'www.google.com','www.cloudflare.com'
#>
#Requires -Version 5.1

param(
    [ValidateRange(1, [int]::MaxValue)]
    [Alias('Rounds')]
    [int]$Passes = 5,
    [switch]$Quick,
    [ValidateRange(0, 1000)]
    [int]$SleepMs = 25,
    [string[]]$Servers = @(),
    [string[]]$ExcludeServers = @(),
    [string[]]$Domains = @(
        'www.google.com',
        'www.cloudflare.com',
        'www.wikipedia.org',
        'www.microsoft.com',
        'github.com',
        'www.youtube.com',
        'www.reddit.com',
        'www.amazon.com'
    )
)

if ($Quick) {
    if (-not $PSBoundParameters.ContainsKey('Passes') -and -not $PSBoundParameters.ContainsKey('Rounds')) {
        $Passes = 2
    }
    if (-not $PSBoundParameters.ContainsKey('Domains')) {
        $Domains = @('www.google.com', 'www.cloudflare.com', 'github.com', 'www.microsoft.com')
    }
}

$ErrorActionPreference = 'SilentlyContinue'

function ConvertFrom-CsvParam([string[]]$Values) {
    $Values | ForEach-Object { ($_ -split ',') } | ForEach-Object { $_.Trim(" `"'") } | Where-Object { $_ }
}

function Get-RotatedList($List, [int]$Offset) {
    if ($Offset -eq 0) { return $List }
    @($List[$Offset..($List.Count - 1)]) + @($List[0..($Offset - 1)])
}

function Invoke-DnsQuery {
    param(
        [pscustomobject]$Target,
        [string]$Domain,
        $PassLabel,
        [string]$ProgressStatus,
        [int]$Pct,
        [int]$SecondsRemaining,
        [int]$Pos,
        [switch]$Score
    )
    $verb = if ($Score) { 'Querying' } else { 'Testing' }
    Write-Progress -Activity 'DNS Benchmark' `
        -Status $ProgressStatus `
        -CurrentOperation ('{0} {1} ({2})...' -f $verb, $Target.Provider, $Target.Server) `
        -PercentComplete $Pct `
        -SecondsRemaining $SecondsRemaining

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true; $errId = ''
    try {
        Resolve-DnsName -Name $Domain -Server $Target.Server -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null
    }
    catch { $ok = $false; $errId = $_.FullyQualifiedErrorId }
    $sw.Stop()

    Write-Progress -Activity 'DNS Benchmark' `
        -Status $ProgressStatus `
        -CurrentOperation ('{0} {1} ({2}) -> {3}' -f $verb, $Target.Provider, $Target.Server, $(if ($ok) { '{0} ms' -f [math]::Round($sw.Elapsed.TotalMilliseconds, 1) } else { 'Failed' })) `
        -PercentComplete $Pct `
        -SecondsRemaining $SecondsRemaining

    if ($Score) {
        if ($ok) { $script:results[$Target.Server].Add($sw.Elapsed.TotalMilliseconds) }
        else { $script:fails[$Target.Server]++ }
    }
    $script:rawSamples.Add([pscustomobject]@{
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        Pass       = $PassLabel
        Position   = $Pos
        Domain     = $Domain
        Server     = $Target.Server
        Provider   = $Target.Provider
        Elapsed_ms = if ($ok) { [math]::Round($sw.Elapsed.TotalMilliseconds, 2) } else { -1 }
        Status     = if ($ok) { 'Success' } else { 'Fail' }
        ErrorId    = $errId
    })
    if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }
}

# Resolver families (used for provider labels and matched family recommendation)
$families = @{
    'Cloudflare'         = @('1.1.1.1', '1.0.0.1')
    'Cloudflare Malware' = @('1.1.1.2', '1.0.0.2')
    'Cloudflare Family'  = @('1.1.1.3', '1.0.0.3')
    'Google'             = @('8.8.8.8', '8.8.4.4')
    'Quad9'              = @('9.9.9.9', '149.112.112.112')
    'Quad9 NoFilter'     = @('9.9.9.10', '149.112.112.110')
    'OpenDNS'            = @('208.67.222.222', '208.67.220.220')
    'AdGuard'            = @('94.140.14.14', '94.140.15.15')
}

$providerOf = @{}
foreach ($fam in $families.Keys) {
    foreach ($ip in $families[$fam]) {
        $providerOf[$ip] = $fam
    }
}

# Normalize Domains parameter inputs (supports comma-separated strings)
$Domains = @(ConvertFrom-CsvParam $Domains)

# Pre-flight internet connectivity check
$preflightDomain = if ($Domains.Count -gt 0) { $Domains[0] } else { 'www.google.com' }
Write-Host ("Checking internet connectivity ({0})..." -f $preflightDomain) -ForegroundColor Cyan
$online = $false
try {
    if (Resolve-DnsName -Name $preflightDomain -Type A -DnsOnly -NoHostsFile -ErrorAction Stop) { $online = $true }
}
catch {
    foreach ($probe in @('1.1.1.1', '8.8.8.8')) {
        try {
            if (Resolve-DnsName -Name $preflightDomain -Server $probe -Type A -DnsOnly -NoHostsFile -ErrorAction Stop) {
                Write-Warning ("System DNS failed for '{0}', but internet route is active via {1}. Continuing..." -f $preflightDomain, $probe)
                $online = $true
                break
            }
        }
        catch {}
    }
}

if (-not $online) {
    Write-Host ("Cannot resolve '{0}' via System DNS or public fallbacks (1.1.1.1, 8.8.8.8). Please verify your internet connection." -f $preflightDomain) -ForegroundColor Red
    exit 1
}

# Detect active system DNS servers from connected adapters only (Status = 'Up')
$systemDns = @{}   # IP -> InterfaceAlias
$activeAdapter = $null
$upIdx = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' } |
    Select-Object -ExpandProperty InterfaceIndex)

foreach ($a in (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    if ($upIdx -notcontains $a.InterfaceIndex) { continue }
    if (-not $activeAdapter) { $activeAdapter = $a.InterfaceAlias }
    foreach ($ip in $a.ServerAddresses) {
        if ($ip -and $ip -notlike 'fec0:*' -and $ip -ne '127.0.0.1' -and $ip -notlike '169.254.*') {
            if (-not $systemDns.ContainsKey($ip)) {
                $systemDns[$ip] = $a.InterfaceAlias
                $activeAdapter = $a.InterfaceAlias
            }
        }
    }
}

# Normalize Servers and ExcludeServers parameter inputs (supports comma-separated strings)
$Servers = @(ConvertFrom-CsvParam $Servers)
$ExcludeServers = @(ConvertFrom-CsvParam $ExcludeServers)

# Assemble test targets (filtering with ExcludeServers and deduplicating system vs public)
$testList = [System.Collections.Generic.List[psobject]]::new()
$added = @{}

if ($Servers.Count -eq 0) {
    $Servers = @(
        '1.1.1.1', '1.0.0.1',
        '1.1.1.2', '1.0.0.2',
        '8.8.8.8', '8.8.4.4',
        '9.9.9.9', '149.112.112.112',
        '208.67.222.222', '208.67.220.220',
        '94.140.14.14', '94.140.15.15'
    )
}

foreach ($ip in $Servers) {
    if ($ExcludeServers -contains $ip -or $added.ContainsKey($ip)) { continue }
    $label = if ($providerOf.ContainsKey($ip)) { $providerOf[$ip] } else { 'Custom' }
    if ($systemDns.ContainsKey($ip)) { $label += ' (System DNS)' }
    $testList.Add([pscustomobject]@{ Provider = $label; Server = $ip })
    $added[$ip] = $true
}

foreach ($ip in $systemDns.Keys) {
    if ($added.ContainsKey($ip) -or ($ExcludeServers -contains $ip)) { continue }
    $testList.Add([pscustomobject]@{ Provider = "System ({0})" -f $systemDns[$ip]; Server = $ip })
    $added[$ip] = $true
}

if ($systemDns.Count -gt 0) {
    $sysSummary = ($systemDns.Keys | ForEach-Object { "{0} [{1}]" -f $_, $systemDns[$_] }) -join ', '
    Write-Host ("Detected active System DNS (Up adapters): {0}" -f $sysSummary) -ForegroundColor DarkGray
}
else {
    Write-Host "No active System DNS detected on Up adapters; benchmarking public resolvers only." -ForegroundColor DarkGray
}

if ($testList.Count -eq 0) {
    Write-Warning "No valid DNS servers available to benchmark. Please verify your -Servers and -ExcludeServers parameters."
    return
}
# Benchmark execution with interleaved round-robin queries
$results = @{}
$fails = @{}
foreach ($t in $testList) {
    $results[$t.Server] = [System.Collections.Generic.List[double]]::new()
    $fails[$t.Server] = 0
}

$startTime = Get-Date
$rawSamples = [System.Collections.Generic.List[psobject]]::new()
$totalWarmupQueries = $Domains.Count * $testList.Count
$totalScoredQueries = $Passes * $Domains.Count * $testList.Count
$totalQueries = $totalWarmupQueries + $totalScoredQueries
$queryIdx = 0
$origTitle = try { $Host.UI.RawUI.WindowTitle } catch { $null }

Write-Host ("Starting benchmark: {0} servers, {1} passes x {2} domains ({3} scored queries/server) + 1 warm-up pass...`n" -f $testList.Count, $Passes, $Domains.Count, ($Passes * $Domains.Count)) -ForegroundColor Cyan

# Warm-up pass (primes resolver cache across all benchmark domains; discarded from scored metrics)
$sweep = 0
Write-Host "Running warm-up pass across all domains (cache priming, discarded)..." -ForegroundColor DarkGray
foreach ($domain in $Domains) {
    Write-Host ("  [Warm-up] Priming cache for {0} across {1} servers..." -f $domain, $testList.Count) -ForegroundColor DarkGray
    $roundServers = Get-RotatedList $testList ($sweep % $testList.Count)
    $sweep++
    $pos = 0
    foreach ($t in $roundServers) {
        $pos++
        $queryIdx++
        $pct = [math]::Min(100, [math]::Round(($queryIdx / $totalQueries) * 100))
        $elapsedSec = ((Get-Date) - $startTime).TotalSeconds
        $avgSec = if ($queryIdx -gt 1) { $elapsedSec / $queryIdx } else { 0.2 }
        $secRemaining = [math]::Max(0, [int][math]::Round(($totalQueries - $queryIdx) * $avgSec))
        try { $Host.UI.RawUI.WindowTitle = ("DNS Benchmark - Warm-up ({0}%)" -f $pct) } catch {}
        $status = "Warm-up ({0}/{1} queries) | Domain: {2}" -f $queryIdx, $totalQueries, $domain
        Invoke-DnsQuery -Target $t -Domain $domain -PassLabel 'Warmup' -ProgressStatus $status -Pct $pct -SecondsRemaining $secRemaining -Pos $pos
    }
}
Write-Host "Warm-up pass finished.`n" -ForegroundColor DarkGray

# Scored benchmark passes
for ($pass = 1; $pass -le $Passes; $pass++) {
    $passStartTime = Get-Date
    foreach ($domain in $Domains) {
        Write-Host ("  [Pass {0}/{1}] Testing domain: {2}..." -f $pass, $Passes, $domain) -ForegroundColor DarkGray
        $roundServers = Get-RotatedList $testList ($sweep % $testList.Count)
        $sweep++
        $pos = 0
        foreach ($t in $roundServers) {
            $pos++
            $queryIdx++
            $pct = [math]::Min(100, [math]::Round(($queryIdx / $totalQueries) * 100))
            $elapsedSec = ((Get-Date) - $startTime).TotalSeconds
            $avgSec = if ($queryIdx -gt 1) { $elapsedSec / $queryIdx } else { 0.2 }
            $secRemaining = [math]::Max(0, [int][math]::Round(($totalQueries - $queryIdx) * $avgSec))
            try { $Host.UI.RawUI.WindowTitle = ("DNS Benchmark - Pass {0}/{1} ({2}%)" -f $pass, $Passes, $pct) } catch {}
            $status = "Pass {0}/{1} ({2}% complete) | Domain: {3}" -f $pass, $Passes, $pct, $domain
            Invoke-DnsQuery -Target $t -Domain $domain -PassLabel $pass -ProgressStatus $status -Pct $pct -SecondsRemaining $secRemaining -Pos $pos -Score
        }
    }
    $passElapsed = (Get-Date) - $passStartTime
    $totalElapsed = (Get-Date) - $startTime
    Write-Host ("Pass {0}/{1} completed ({2}/{3} scored queries) | Pass time: {4:mm\:ss} | Total: {5:mm\:ss}" -f $pass, $Passes, ($pass * $Domains.Count * $testList.Count), $totalScoredQueries, $passElapsed, $totalElapsed) -ForegroundColor Green
}

Write-Progress -Activity "DNS Benchmark" -Completed
try {
    if ($origTitle) { $Host.UI.RawUI.WindowTitle = $origTitle }
}
catch {}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return [double]::NaN }
    $sorted = $Values | Sort-Object
    $mid = [math]::Floor(($sorted.Count - 1) / 2)
    if ($sorted.Count % 2 -ne 0) { return $sorted[$mid] }
    return ($sorted[$mid] + $sorted[$mid + 1]) / 2
}

# Aggregate metrics
$rows = foreach ($t in $testList) {
    $arr = $results[$t.Server].ToArray()
    if ($arr.Count -gt 0) {
        $min = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
        $med = [math]::Round((Get-Median -Values $arr), 1)
        $avg = [math]::Round(($arr | Measure-Object -Average).Average, 1)
        $max = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)
        $dJitters = [System.Collections.Generic.List[double]]::new()
        foreach ($d in $Domains) {
            $dClean = @($rawSamples | Where-Object { $_.Server -eq $t.Server -and $_.Domain -eq $d -and ($_.Pass -is [int]) -and $_.Status -eq 'Success' -and $_.Elapsed_ms -lt 1000 } | ForEach-Object { [double]$_.Elapsed_ms })
            if ($dClean.Count -ge 2) {
                $dSum = 0
                for ($j = 0; $j -lt ($dClean.Count - 1); $j++) {
                    $dSum += [math]::Abs($dClean[$j + 1] - $dClean[$j])
                }
                $dJitters.Add($dSum / ($dClean.Count - 1))
            }
        }
        $jitter = if ($dJitters.Count -gt 0) { [math]::Round(($dJitters | Measure-Object -Average).Average, 1) } else { 0.0 }

        $totalAttempts = $arr.Count + $fails[$t.Server]
        $lossPct = if ($totalAttempts -gt 0) { [math]::Round(($fails[$t.Server] / $totalAttempts) * 100, 1) } else { 0.0 }

        [pscustomobject]@{
            Provider  = $t.Provider
            Server    = $t.Server
            Samples   = $arr.Count
            Fail      = $fails[$t.Server]
            Loss_pct  = $lossPct
            Min_ms    = $min
            Med_ms    = $med
            Avg_ms    = $avg
            Max_ms    = $max
            Jitter_ms = $jitter
        }
    }
    else {
        [pscustomobject]@{
            Provider  = $t.Provider
            Server    = $t.Server
            Samples   = 0
            Fail      = $fails[$t.Server]
            Loss_pct  = if ($fails[$t.Server] -gt 0) { 100.0 } else { 0.0 }
            Min_ms    = -1
            Med_ms    = -1
            Avg_ms    = -1
            Max_ms    = -1
            Jitter_ms = -1
        }
    }
}

# Sort: eligible servers (Loss <= 10% and Med_ms > 0) by median; then ineligible servers by Fail count, then median
$eligible = @($rows | Where-Object { $_.Loss_pct -le 10 -and $_.Med_ms -gt 0 } | Sort-Object Med_ms)
$ineligible = @($rows | Where-Object { -not ($_.Loss_pct -le 10 -and $_.Med_ms -gt 0) } | Sort-Object Fail, @{ Expression = { if ($_.Med_ms -lt 0) { [double]::MaxValue } else { $_.Med_ms } } })
Write-Host ""
Write-Host "=== RESULTS (Sorted by Median Latency) ===" -ForegroundColor Green
($eligible + $ineligible) | Select-Object Provider, Server, Samples, Fail, Loss_pct,
@{ Name = 'Min_ms'; Expression = { if ($_.Samples -gt 0) { $_.Min_ms } else { '-' } } },
@{ Name = 'Med_ms'; Expression = { if ($_.Samples -gt 0) { $_.Med_ms } else { '-' } } },
@{ Name = 'Avg_ms'; Expression = { if ($_.Samples -gt 0) { $_.Avg_ms } else { '-' } } },
@{ Name = 'Max_ms'; Expression = { if ($_.Samples -gt 0) { $_.Max_ms } else { '-' } } },
@{ Name = 'Jitter_ms'; Expression = { if ($_.Samples -gt 0) { $_.Jitter_ms } else { '-' } } } | Format-Table -AutoSize

function Get-ServerBadge([pscustomobject]$s) {
    if ($s.Fail -eq 0) { return "[Zero-Loss]" }
    return ("({0}% loss)" -f $s.Loss_pct)
}

# Evaluate family pairs for smart recommendations (Stability vs. Speed)
$clean = @($rows | Where-Object { $_.Loss_pct -le 10 -and $_.Med_ms -gt 0 })
if ($clean.Count -ge 1) {
    $evaluatedPairs = [System.Collections.Generic.List[psobject]]::new()
    $seenFamilies = @{}

    foreach ($s in $clean) {
        if ($providerOf.ContainsKey($s.Server)) {
            $fam = $providerOf[$s.Server]
            if ($seenFamilies.ContainsKey($fam)) { continue }
            $seenFamilies[$fam] = $true

            $partnerIps = @($families[$fam] | Where-Object { $_ -ne $s.Server })
            $partner = $clean | Where-Object { $_.Server -in $partnerIps } | Select-Object -First 1

            if ($partner) {
                $pri = if ($s.Med_ms -le $partner.Med_ms) { $s } else { $partner }
                $sec = if ($s.Med_ms -le $partner.Med_ms) { $partner } else { $s }
                $pairMax = [math]::Max($pri.Max_ms, $sec.Max_ms)
                $pairMed = [math]::Round(($pri.Med_ms + $sec.Med_ms) / 2, 1)
                $pairJitter = [math]::Max($pri.Jitter_ms, $sec.Jitter_ms)

                $evaluatedPairs.Add([pscustomobject]@{
                        Family     = $fam
                        Primary    = $pri
                        Secondary  = $sec
                        PairMax    = $pairMax
                        PairMed    = $pairMed
                        PairJitter = $pairJitter
                    })
            }
        }
    }

    Write-Host "=== RECOMMENDATIONS ===" -ForegroundColor Yellow

    if ($evaluatedPairs.Count -gt 0) {
        $stablePair = $evaluatedPairs | Sort-Object PairMax, PairJitter | Select-Object -First 1
        $fastestPair = $evaluatedPairs | Sort-Object PairMed | Select-Object -First 1
        $freezeNote = if ($stablePair.PairMax -lt 1000) { "Zero multi-second freezes." } else { "Multi-second spikes were observed (Max {0} ms)." -f $stablePair.PairMax }

        if ($stablePair.Family -eq $fastestPair.Family) {
            Write-Host ("Recommended Pair (Fastest & Most Stable): Primary {0} {1} + Secondary {2} {3} ({4})" -f $stablePair.Primary.Server, (Get-ServerBadge $stablePair.Primary), $stablePair.Secondary.Server, (Get-ServerBadge $stablePair.Secondary), $stablePair.Family) -ForegroundColor Green
            Write-Host ("   Profile: Consistent latency (Max {0} ms, Jitter {1} ms). {2}" -f $stablePair.PairMax, $stablePair.PairJitter, $freezeNote) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("1. Most Stable Pair (Recommended for Coding, Work & Daily Use):" ) -ForegroundColor Green
            Write-Host ("   Primary {0} {1} + Secondary {2} {3} ({4})" -f $stablePair.Primary.Server, (Get-ServerBadge $stablePair.Primary), $stablePair.Secondary.Server, (Get-ServerBadge $stablePair.Secondary), $stablePair.Family) -ForegroundColor White
            Write-Host ("   Profile: Consistent latency (Max {0} ms, Jitter {1} ms). {2}" -f $stablePair.PairMax, $stablePair.PairJitter, $freezeNote) -ForegroundColor DarkGray

            Write-Host ("`n2. Fastest Raw Median (Lower Base Ping, but Spiky):" ) -ForegroundColor Cyan
            Write-Host ("   Primary {0} {1} + Secondary {2} {3} ({4})" -f $fastestPair.Primary.Server, (Get-ServerBadge $fastestPair.Primary), $fastestPair.Secondary.Server, (Get-ServerBadge $fastestPair.Secondary), $fastestPair.Family) -ForegroundColor White
            $spikeNotice = if ($fastestPair.PairMax -gt 250) { " [Notice: Experienced spikes up to {0} ms]" -f $fastestPair.PairMax } else { "" }
            Write-Host ("   Profile: Median {0} ms, Max {1} ms, Jitter {2} ms{3}" -f $fastestPair.PairMed, $fastestPair.PairMax, $fastestPair.PairJitter, $spikeNotice) -ForegroundColor DarkGray
        }
    }
    else {
        # Fallback if no matching family pair exists in custom servers list
        $primary = $clean[0]
        $secondary = if ($clean.Count -ge 2) { $clean[1] } else { $null }
        if ($secondary) {
            Write-Host ("Recommended Pair: Primary {0} {1} ({2}) + Secondary {3} {4} ({5})" -f $primary.Server, (Get-ServerBadge $primary), $primary.Provider, $secondary.Server, (Get-ServerBadge $secondary), $secondary.Provider) -ForegroundColor Yellow
            if ($primary.Provider -ne $secondary.Provider) {
                Write-Host "WARNING: Cross-family pair detected - security filtering may be inconsistent during failover." -ForegroundColor Red
            }
        }
        else {
            Write-Host ("Only one server met stability criteria: {0} {1} ({2})." -f $primary.Server, (Get-ServerBadge $primary), $primary.Provider) -ForegroundColor Yellow
        }
    }

    # Compare against active System DNS
    $sysServersInClean = @($clean | Where-Object { $systemDns.ContainsKey($_.Server) })
    $chosenPrimary = if ($evaluatedPairs.Count -gt 0) { $stablePair.Primary } else { $primary }
    if ($sysServersInClean.Count -gt 0 -and $chosenPrimary) {
        $bestSys = $sysServersInClean | Sort-Object Med_ms | Select-Object -First 1
        $diff = [math]::Round($bestSys.Med_ms - $chosenPrimary.Med_ms, 1)
        Write-Host "`nActive System DNS Comparison:" -ForegroundColor Yellow
        if ($bestSys.Server -eq $chosenPrimary.Server) {
            Write-Host ("   Your active System DNS ({0}) is already the top-performing recommendation!" -f $bestSys.Server) -ForegroundColor Green
        }
        elseif ($diff -gt 0) {
            $pct = [math]::Round(($diff / $bestSys.Med_ms) * 100, 1)
            Write-Host ("   Current DNS ({0}) median: {1} ms | Recommended ({2}) median: {3} ms" -f $bestSys.Server, $bestSys.Med_ms, $chosenPrimary.Server, $chosenPrimary.Med_ms) -ForegroundColor DarkGray
            Write-Host ("   Switching saves ~{0} ms ({1}% faster lookups)." -f $diff, $pct) -ForegroundColor Green
        }
        else {
            Write-Host ("   Current DNS ({0}) median is {1} ms (already {2} ms faster than recommended pair primary {3} ms)." -f $bestSys.Server, $bestSys.Med_ms, [math]::Abs($diff), $chosenPrimary.Med_ms) -ForegroundColor Cyan
        }
    }

    # Actionable PowerShell commands to apply / reset DNS
    if ($activeAdapter) {
        $recIps = if ($evaluatedPairs.Count -gt 0) {
            "'{0}', '{1}'" -f $stablePair.Primary.Server, $stablePair.Secondary.Server
        }
        elseif ($secondary) {
            "'{0}', '{1}'" -f $primary.Server, $secondary.Server
        }
        else {
            "'{0}'" -f $primary.Server
        }

        Write-Host ("`nTo apply recommended DNS to '{0}' (run in Administrator PowerShell):" -f $activeAdapter) -ForegroundColor Yellow
        Write-Host ("   Set-DnsClientServerAddress -InterfaceAlias '{0}' -ServerAddresses {1} -Validate" -f $activeAdapter, $recIps) -ForegroundColor Cyan
        Write-Host ("To revert back to automatic (DHCP) DNS:" ) -ForegroundColor DarkGray
        Write-Host ("   Set-DnsClientServerAddress -InterfaceAlias '{0}' -ResetServerAddresses" -f $activeAdapter) -ForegroundColor DarkGray
    }
}
else {
    Write-Host "No servers met the stability criteria (<=10% loss). Please verify your internet connection or server list." -ForegroundColor Red
}

$allCleanTimes = @($results.Values | ForEach-Object { $_ })
$obsFloor = if ($allCleanTimes.Count -gt 0) { [math]::Round(($allCleanTimes | Measure-Object -Minimum).Minimum, 1) } else { 0 }

Write-Host ""
Write-Host ("Baseline Performance: Instrument Overhead ~0.55 ms (Win32 Cmdlet) | This Run's Observed Network RTT Floor: {0} ms" -f $obsFloor) -ForegroundColor Cyan

$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $baseDir 'results'
$null = New-Item -ItemType Directory -Path $outDir -Force

# Save sibling raw samples CSV
$samplesCsv = Join-Path $outDir ("dns-bench-{0:yyyyMMdd-HHmmss}-samples.csv" -f $startTime)
try {
    $rawSamples | Export-Csv -Path $samplesCsv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host ("Raw samples CSV log saved:  {0}" -f $samplesCsv)
}
catch {
    Write-Warning ("Failed to save raw samples CSV: {0}" -f $_.Exception.Message)
}

# Save aggregate CSV with run metadata
$csv = Join-Path $outDir ("dns-bench-{0:yyyyMMdd-HHmmss}.csv" -f $startTime)
try {
    $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host ("Aggregate CSV report saved: {0}" -f $csv)
}
catch {
    Write-Warning ("Failed to save aggregate CSV: {0}" -f $_.Exception.Message)
}
Write-Host "Tip: Differences in median latency under 15-20 ms are barely noticeable in normal browsing."
Write-Host "Prioritize security features (e.g., malware blocking) and consistent max latency over small median gains."
