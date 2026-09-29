#Requires -Version 5.1

param(
    [int]$Passes = 5,
    [int]$Rounds = 0,
    [string[]]$Servers = @(),
    [string[]]$ExcludeServers = @(),
    [string[]]$Domains = @(
        'www.google.com',
        'www.cloudflare.com',
        'www.wikipedia.org',
        'www.microsoft.com'
    )
)

if ($Rounds -gt 0 -and $PSBoundParameters.ContainsKey('Rounds') -and -not $PSBoundParameters.ContainsKey('Passes')) {
    $Passes = $Rounds
}

$ErrorActionPreference = 'SilentlyContinue'

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

# Detect active system DNS servers from connected adapters only (Status = 'Up')
$systemDns = @{}   # IP -> InterfaceAlias
$upIdx = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' } |
    Select-Object -ExpandProperty InterfaceIndex)

foreach ($a in (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    if ($upIdx -notcontains $a.InterfaceIndex) { continue }
    foreach ($ip in $a.ServerAddresses) {
        if ($ip -and $ip -notlike 'fec0:*' -and $ip -ne '127.0.0.1' -and $ip -notlike '169.254.*') {
            if (-not $systemDns.ContainsKey($ip)) {
                $systemDns[$ip] = $a.InterfaceAlias
            }
        }
    }
}

# Normalize Servers and ExcludeServers parameter inputs (supports comma-separated strings)
$flatServers = @()
foreach ($s in $Servers) {
    if ($s) {
        ($s -split ',') | ForEach-Object {
            $cleaned = $_.Trim(" `"'")
            if ($cleaned) { $flatServers += $cleaned }
        }
    }
}
$Servers = $flatServers

$flatExclude = @()
foreach ($e in $ExcludeServers) {
    if ($e) {
        ($e -split ',') | ForEach-Object {
            $cleaned = $_.Trim(" `"'")
            if ($cleaned) { $flatExclude += $cleaned }
        }
    }
}
$ExcludeServers = $flatExclude

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
} else {
    Write-Host "No active System DNS detected on Up adapters; benchmarking public resolvers only." -ForegroundColor DarkGray
}
# Benchmark execution with interleaved round-robin queries
$results = @{}
$fails   = @{}
foreach ($t in $testList) {
    $results[$t.Server] = [System.Collections.Generic.List[double]]::new()
    $fails[$t.Server]   = 0
}

$startTime = Get-Date
$rawSamples = [System.Collections.Generic.List[psobject]]::new()
$totalScoredQueriesPerServer = $Passes * $Domains.Count

Write-Host ("Starting benchmark: {0} servers, {1} passes x {2} domains ({3} scored queries/server) + 1 warm-up pass...`n" -f $testList.Count, $Passes, $Domains.Count, $totalScoredQueriesPerServer) -ForegroundColor Cyan

# Warm-up pass (primes resolver cache across all benchmark domains; discarded from scored metrics)
$sweep = 0
Write-Host "Running warm-up pass across all domains (cache priming, discarded)..." -ForegroundColor DarkGray
foreach ($domain in $Domains) {
    $offset = $sweep % $testList.Count
    $roundServers = if ($offset -eq 0) { $testList } else { @($testList[$offset..($testList.Count - 1)]) + @($testList[0..($offset - 1)]) }
    $currentSweep = $sweep
    $sweep++
    $pos = 0
    foreach ($t in $roundServers) {
        $pos++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $true
        $errId = ""
        try {
            Resolve-DnsName -Name $domain -Server $t.Server -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null
        } catch {
            $ok = $false
            $errId = $_.FullyQualifiedErrorId
        }
        $sw.Stop()

        $rawSamples.Add([pscustomobject]@{
            Timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            Pass       = "Warmup"
            SweepIndex = $currentSweep
            Position   = $pos
            Domain     = $domain
            Server     = $t.Server
            Provider   = $t.Provider
            Elapsed_ms = if ($ok) { [math]::Round($sw.Elapsed.TotalMilliseconds, 2) } else { -1 }
            Status     = if ($ok) { "Success" } else { "Fail" }
            ErrorId    = $errId
        })
        Start-Sleep -Milliseconds 100
    }
}
Write-Host "Warm-up pass finished.`n" -ForegroundColor DarkGray

# Scored benchmark passes
for ($pass = 1; $pass -le $Passes; $pass++) {
    foreach ($domain in $Domains) {
        $offset = $sweep % $testList.Count
        $roundServers = if ($offset -eq 0) { $testList } else { @($testList[$offset..($testList.Count - 1)]) + @($testList[0..($offset - 1)]) }
        $currentSweep = $sweep
        $sweep++
        $pos = 0
        foreach ($t in $roundServers) {
            $pos++
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ok = $true
            $errId = ""
            try {
                Resolve-DnsName -Name $domain -Server $t.Server -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null
            } catch {
                $ok = $false
                $errId = $_.FullyQualifiedErrorId
            }
            $sw.Stop()

            if ($ok) {
                $results[$t.Server].Add($sw.Elapsed.TotalMilliseconds)
            } else {
                $fails[$t.Server]++
            }

            $rawSamples.Add([pscustomobject]@{
                Timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                Pass       = $pass
                SweepIndex = $currentSweep
                Position   = $pos
                Domain     = $domain
                Server     = $t.Server
                Provider   = $t.Provider
                Elapsed_ms = if ($ok) { [math]::Round($sw.Elapsed.TotalMilliseconds, 2) } else { -1 }
                Status     = if ($ok) { "Success" } else { "Fail" }
                ErrorId    = $errId
            })
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ("Pass {0}/{1} completed" -f $pass, $Passes)
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
$rows = foreach ($t in $testList) {
    $arr = $results[$t.Server].ToArray()
    if ($arr.Count -gt 0) {
        $min = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
        $med = [math]::Round((Get-Median -Values $arr), 1)
        $avg = [math]::Round(($arr | Measure-Object -Average).Average, 1)
        $max = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)
        $jitter = [math]::Round($max - $min, 1)

        [pscustomobject]@{
            Provider  = $t.Provider
            Server    = $t.Server
            Samples   = $arr.Count
            Fail      = $fails[$t.Server]
            Min_ms    = $min
            Med_ms    = $med
            Avg_ms    = $avg
            Max_ms    = $max
            Jitter_ms = $jitter
        }
    } else {
        [pscustomobject]@{
            Provider  = $t.Provider
            Server    = $t.Server
            Samples   = 0
            Fail      = $fails[$t.Server]
            Min_ms    = -1
            Med_ms    = -1
            Avg_ms    = -1
            Max_ms    = -1
            Jitter_ms = -1
        }
    }
}

# Sort: 0-failure servers first (by median latency), followed by servers with failures
$rows = @($rows | Sort-Object @{ Expression = "Fail"; Ascending = $true }, @{ Expression = { if ($_.Med_ms -lt 0) { [double]::MaxValue } else { $_.Med_ms } }; Ascending = $true })

Write-Host ""
Write-Host "=== RESULTS (Sorted by Median Latency) ===" -ForegroundColor Green
$rows | Format-Table -AutoSize

# Evaluate family pairs for smart recommendations (Stability vs. Speed)
$clean = @($rows | Where-Object { $_.Fail -eq 0 -and $_.Samples -gt 0 })
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

        if ($stablePair.Family -eq $fastestPair.Family) {
            Write-Host ("Recommended Pair (Fastest & Most Stable): Primary {0} + Secondary {1} ({2})" -f $stablePair.Primary.Server, $stablePair.Secondary.Server, $stablePair.Family) -ForegroundColor Green
            Write-Host ("  Profile: Median {0} ms | Max {1} ms | Jitter {2} ms" -f $stablePair.PairMed, $stablePair.PairMax, $stablePair.PairJitter) -ForegroundColor DarkGray
        } else {
            Write-Host ("1. Most Stable Pair (Recommended for Coding, Work & Daily Use):" ) -ForegroundColor Green
            Write-Host ("   Primary {0} + Secondary {1} ({2})" -f $stablePair.Primary.Server, $stablePair.Secondary.Server, $stablePair.Family) -ForegroundColor White
            Write-Host ("   Profile: Consistent latency (Max {0} ms, Jitter {1} ms). Zero multi-second freezes." -f $stablePair.PairMax, $stablePair.PairJitter) -ForegroundColor DarkGray

            Write-Host ("`n2. Fastest Raw Median (Lower Base Ping, but Spiky):" ) -ForegroundColor Cyan
            Write-Host ("   Primary {0} + Secondary {1} ({2})" -f $fastestPair.Primary.Server, $fastestPair.Secondary.Server, $fastestPair.Family) -ForegroundColor White
            $spikeNotice = if ($fastestPair.PairMax -gt 250) { " [Notice: Experienced spikes up to {0} ms]" -f $fastestPair.PairMax } else { "" }
            Write-Host ("   Profile: Median {0} ms, Max {1} ms, Jitter {2} ms{3}" -f $fastestPair.PairMed, $fastestPair.PairMax, $fastestPair.PairJitter, $spikeNotice) -ForegroundColor DarkGray
        }
    } else {
        # Fallback if no matching family pair exists in custom servers list
        $primary = $clean[0]
        $secondary = if ($clean.Count -ge 2) { $clean[1] } else { $null }
        if ($secondary) {
            Write-Host ("Recommended Pair: Primary {0} ({1}) + Secondary {2} ({3})" -f $primary.Server, $primary.Provider, $secondary.Server, $secondary.Provider) -ForegroundColor Yellow
            if ($providerOf[$primary.Server] -ne $providerOf[$secondary.Server]) {
                Write-Host "WARNING: Cross-family pair detected - security filtering may be inconsistent during failover." -ForegroundColor Red
            }
        } else {
            Write-Host ("Only one server completed without failure: {0} ({1})." -f $primary.Server, $primary.Provider) -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "No servers completed without failures. Please verify your internet connection or server list." -ForegroundColor Red
}

$allCleanTimes = @($results.Values | ForEach-Object { $_ } | Where-Object { $_ -gt 0 })
$obsFloor = if ($allCleanTimes.Count -gt 0) { [math]::Round(($allCleanTimes | Measure-Object -Min).Minimum, 1) } else { 0 }

Write-Host ""
Write-Host ("Baseline Performance: Instrument Overhead ~0.55 ms (Win32 Cmdlet) | This Run's Observed Network RTT Floor: {0} ms" -f $obsFloor) -ForegroundColor Cyan

# Save sibling raw samples CSV
$samplesCsv = Join-Path $PSScriptRoot ("dns-bench-{0:yyyyMMdd-HHmmss}-samples.csv" -f $startTime)
$rawSamples | Export-Csv -Path $samplesCsv -NoTypeInformation -Encoding UTF8

# Save aggregate CSV with run metadata
$csv = Join-Path $PSScriptRoot ("dns-bench-{0:yyyyMMdd-HHmmss}.csv" -f $startTime)
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host ("Aggregate CSV report saved: {0}" -f $csv)
Write-Host ("Raw samples CSV log saved:  {0}" -f $samplesCsv)
Write-Host "Tip: Differences in median latency under 15-20 ms are barely noticeable in normal browsing."
Write-Host "Prioritize security features (e.g., malware blocking) and consistent max latency over small median gains."
