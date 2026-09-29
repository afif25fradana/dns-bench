#Requires -Version 5.1
<#
.SYNOPSIS
  Benchmark DNS resolver yang tahan jitter link FWA/ISP.
.DESCRIPTION
  - Mengirim query DNS secara interleaved (round-robin): tiap ronde semua
    server dites dengan domain yang sama, sehingga kondisi link yang
    berubah-ubah dialami merata oleh semua server.
  - Ronde pertama dibuang sebagai warm-up (cache dingin).
  - Melaporkan min/median/avg/max + jumlah gagal per server.
  - Merekomendasikan pasangan primary/secondary.
  - Menyimpan CSV untuk arsip/perbandingan jam berbeda.
.CARA PAKAI
  Klik dua kali dns-bench.bat, atau di PowerShell:
    powershell -ExecutionPolicy Bypass -File .\dns-bench.ps1
  Parameter opsional:
    .\dns-bench.ps1 -Rounds 12
    .\dns-bench.ps1 -Servers '1.1.1.1','9.9.9.9' -Domains 'www.google.com'
  Jalankan dari laptop yang terhubung ETHERNET, ulangi di jam berbeda
  (siang vs malam) karena link FWA berubah-ubah.
#>

param(
    [int]$Rounds = 8,
    [string[]]$Servers = @(
        '1.1.1.1',        # Cloudflare
        '1.0.0.1',        # Cloudflare sekunder
        '8.8.8.8',        # Google
        '8.8.4.4',        # Google sekunder
        '9.9.9.9',        # Quad9 (blokir malware)
        '149.112.112.112',# Quad9 sekunder
        '1.1.1.2',        # Cloudflare Family (malware)
        '1.0.0.2'         # Cloudflare Family sekunder
    ),
    [string[]]$Domains = @(
        'www.google.com',
        'www.youtube.com',
        'id.wikipedia.org',
        'www.tokopedia.com',
        'www.kompas.com',
        'wa.me'
    )
)

$ErrorActionPreference = 'SilentlyContinue'

$results = @{}
$fails   = @{}
foreach ($s in $Servers) {
    $results[$s] = [System.Collections.Generic.List[double]]::new()
    $fails[$s]   = 0
}

$totalRounds = $Rounds + 1   # ronde 1 = warm-up, dibuang
for ($r = 1; $r -le $totalRounds; $r++) {
    $domain = $Domains[($r - 1) % $Domains.Count]
    foreach ($s in $Servers) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $true
        try {
            Resolve-DnsName -Name $domain -Server $s -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null
        } catch {
            $ok = $false
        }
        $sw.Stop()
        if ($ok) {
            if ($r -gt 1) { $results[$s].Add($sw.Elapsed.TotalMilliseconds) }
        } else {
            $fails[$s]++
        }
    }
    Write-Host ("Ronde {0}/{1} selesai (domain: {2})" -f $r, $totalRounds, $domain)
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return [double]::NaN }
    $sorted = $Values | Sort-Object
    $mid = [math]::Floor(($sorted.Count - 1) / 2)
    if ($sorted.Count % 2 -ne 0) { return $sorted[$mid] }
    return ($sorted[$mid] + $sorted[$mid + 1]) / 2
}

$rows = foreach ($s in $Servers) {
    $arr = $results[$s].ToArray()
    if ($arr.Count -gt 0) {
        [pscustomobject]@{
            Server  = $s
            Samples = $arr.Count
            Fail    = $fails[$s]
            Min_ms  = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
            Med_ms  = [math]::Round((Get-Median -Values $arr), 1)
            Avg_ms  = [math]::Round(($arr | Measure-Object -Average).Average, 1)
            Max_ms  = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)
        }
    } else {
        [pscustomobject]@{
            Server  = $s
            Samples = 0
            Fail    = $fails[$s]
            Min_ms  = -1
            Med_ms  = -1
            Avg_ms  = -1
            Max_ms  = -1
        }
    }
}

$rows = $rows | Sort-Object Med_ms

Write-Host ""
Write-Host "=== HASIL (urutan median tercepat) ==="
$rows | Format-Table -AutoSize

$best = @($rows | Where-Object { $_.Fail -eq 0 -and $_.Samples -gt 0 } | Select-Object -First 2)
if ($best.Count -ge 2) {
    Write-Host ("Rekomendasi pasangan: primary {0} + secondary {1}" -f $best[0].Server, $best[1].Server)
    Write-Host "Catatan: kalau kamu memilih varian filtering (1.1.1.2/1.1.1.3 atau 9.9.9.9),"
    Write-Host "pasangkan dengan saudara satu keluarganya (1.0.0.2 / 1.0.0.3 / 149.112.112.112),"
    Write-Host "bukan dengan server keluarga lain, supaya filtering tidak bolong."
} elseif ($best.Count -eq 1) {
    Write-Host ("Hanya satu server tanpa gagal: {0}. Pertimbangkan ulang daftar server." -f $best[0].Server)
}

$csv = Join-Path $PSScriptRoot ("dns-bench-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("CSV tersimpan: {0}" -f $csv)
Write-Host "Tips: selisih median di bawah 20 ms praktis tidak terasa saat browsing."
Write-Host "Pilih berdasarkan fitur (filtering atau tidak) kecuali selisihnya jauh."
