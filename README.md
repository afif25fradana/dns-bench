# DNS Benchmark

A lightweight PowerShell script that measures which public DNS resolver is actually fastest and most reliable from your local connection — not from an upstream data center benchmark.

It runs an uncounted warm-up pass to prime resolver caches, tests each server in an interleaved round-robin rotation across 8 popular domains over 6 passes, and outputs a ranked table with median latency, P90, jitter, filtered queries, and packet loss. At the end, it recommends both a balanced security pair and the fastest raw median pair, compares them against your active System DNS, and prints the exact command to switch adapters.

Works on Windows PowerShell 5.1 and PowerShell 7+. No administrative privileges required to run the benchmark.

---

## How it works

1. **Pre-flight Connectivity Check:** Verifies that network interfaces are active and resolves a test domain before starting. If offline, the script returns cleanly without terminating your interactive terminal session.
2. **Adapter Discovery:** Identifies the active IPv4 default gateway route (`0.0.0.0/0`) on connected adapters (`Status = Up`), distinguishing physical WAN interfaces from virtual or VPN adapters (e.g. WSL, Hyper-V, WireGuard).
3. **Cache-Priming Warm-up:** Runs 1 uncounted pass across all domains. This primes the edge resolver's cache so subsequent passes measure **warm-cache round-trip time (RTT) to the provider's anycast edge**, rather than cold recursive resolution or authoritative nameserver latency.
4. **Interleaved Round-Robin with 6-Pass Lead Symmetry:** Tests servers in a rotating sequence domain-by-domain rather than querying one server repeatedly. With 12 default servers and 8 domains over 6 passes (48 scored sweeps), each server leads a sweep exactly 4 times ($48 / 12 = 4$), providing 100% lead rotation symmetry and eliminating positional burst bias.

---

## What it measures

| Column | Description |
| :--- | :--- |
| **Samples** | Count of successful DNS resolutions received. |
| **Spikes** | Queries taking $\ge 1000\text{ ms}$. In Windows, dropped UDP packets trigger Win32 DNS client retry backoffs (~1s, ~2s). These delays reflect real link drops, but are isolated to avoid distorting baseline latency. |
| **Filtered** | Queries intercepted by security policy (NXDOMAIN `DNS_ERROR_RCODE_NAME_ERROR`) or redirected to sinkhole addresses (`0.0.0.0/8`, `127.0.0.0/8`, RFC 1918 private, RFC 6598 CGNAT `100.64.0.0/10`, or RFC 3927 link-local). Segregated so security resolvers are not falsely penalized as packet loss. |
| **Fail** | Queries that timed out completely after Windows exhausted its retry attempts (`ERROR_TIMEOUT`). |
| **Loss_pct** | Genuine transport loss rate: $\frac{\text{Fail}}{\text{Samples} + \text{Fail} + \text{Filtered}} \times 100$. Filtered queries remain in the denominator as valid attempts, but do not count as lost packets. |
| **Min / Med / Avg / Max** | Clean latency in milliseconds, calculated strictly on samples $< 1000\text{ ms}$. |
| **P90_ms** | 90th percentile clean latency computed via NIST / R-7 linear interpolation, showing the latency ceiling for 90% of your queries. |
| **Jitter_ms** | Within-domain mean absolute successive difference (MASD) across clean samples, averaged across domains. Spikes are excluded so packet drops do not warp consistency metrics. Displays `-` when insufficient clean pairs exist. |

Servers with $> 10\%$ packet loss sort to the bottom. In CSV reports, `-1` indicates that no successful response was received.

---

## Resolvers tested by default

| Provider | Primary | Secondary | Category / Policy |
| :--- | :--- | :--- | :--- |
| **Your System DNS** | auto-detected | — | Active DNS configured on your default route adapter |
| **Cloudflare** | `1.1.1.1` | `1.0.0.1` | Unfiltered public resolver |
| **Cloudflare Malware** | `1.1.1.2` | `1.0.0.2` | Threat & malware blocking |
| **Google** | `8.8.8.8` | `8.8.4.4` | Unfiltered public resolver |
| **Quad9** | `9.9.9.9` | `149.112.112.112` | Threat intelligence blocking (malware & phishing) |
| **OpenDNS** | `208.67.222.222` | `208.67.220.220` | Cisco Umbrella basic filtering |
| **AdGuard** | `94.140.14.14` | `94.140.15.15` | Ad and tracker blocking |

---

## How to run

### Quick Launcher

Double-click `dns-bench.bat`. It launches the script via `-ExecutionPolicy Bypass`, runs the benchmark, pauses to let you inspect the results, and exits cleanly.

### PowerShell

```powershell
.\dns-bench.ps1
```

If your execution policy restricts scripts:
```powershell
powershell -ExecutionPolicy Bypass -File .\dns-bench.ps1
```

### Common Options

```powershell
# Quick smoke test with 2 passes across 4 domains (~17-30 seconds)
.\dns-bench.ps1 -Quick

# Custom pass count (aliased to -Rounds)
.\dns-bench.ps1 -Passes 8

# Adjust delay between queries in milliseconds (default: 25)
.\dns-bench.ps1 -SleepMs 50

# Skip specific resolvers
.\dns-bench.ps1 -ExcludeServers '1.1.1.1','1.0.0.1'

# Test specific resolvers only
.\dns-bench.ps1 -Servers '9.9.9.9','149.112.112.112','1.1.1.1','1.0.0.1'

# Test custom domains
.\dns-bench.ps1 -Domains 'github.com','cloudflare.com','google.com','wikipedia.org'
```

---

## Reading the results

The table is sorted by median latency. Resolvers exceeding 10% packet loss are placed at the bottom.

- **Median, P90, and Spikes:** A resolver with a 35 ms median but frequent multi-second spikes will feel noticeably slower in practice than a steady 45 ms resolver capped under 60 ms. Evaluate `P90_ms`, `Spikes`, and `Jitter_ms` alongside `Med_ms`.
- **Smart Recommendations & 15 ms Dead-Band:** Latency differences under 15–20 ms are negligible in day-to-day browsing. When multiple providers fall within 15 ms of the fastest pair median, the benchmark recommends the pair with the strongest security filtering tier (Tier 1: Malware blocking like Quad9 or Cloudflare Malware; Tier 2: Ad/tracker blocking like AdGuard; Tier 3: Unfiltered like Google or Cloudflare).
- **Fastest Raw Median:** The absolute lowest-latency pair is always displayed as an alternative if you prefer minimum ping regardless of filtering.
- **Matched Family Pairing:** Primary and secondary resolvers are always matched from the same provider. This guarantees consistent filtering behavior if Windows fails over to the secondary resolver.

---

## Results files

Every run automatically writes two UTF-8 CSV files to the `results/` folder:

### 1. Aggregate Report (`dns-bench-YYYYMMDD-HHmmss.csv`)
Contains summary rows for every tested resolver, plus run-level metadata columns appended to each row:
- **Resolver Metrics:** `Provider`, `Server`, `Samples`, `Spikes`, `Filtered`, `Fail`, `Loss_pct`, `Min_ms`, `Med_ms`, `Avg_ms`, `P90_ms`, `Max_ms`, `Jitter_ms`.
- **Run Metadata:**
  - `Adapter` — Active interface alias used for routing (e.g. `Wi-Fi`, `Ethernet`).
  - `Passes` — Number of completed passes.
  - `DomainCount` — Number of domains queried per pass.
  - `ObservedFloor_ms` — Minimum network RTT observed across any resolver during the run.
  - `TotalDuration_s` — Overall benchmark elapsed time in seconds.

### 2. Query Samples Log (`dns-bench-YYYYMMDD-HHmmss-samples.csv`)
Records every individual query across warm-up and scored passes with `Timestamp`, `Pass`, `Position` in sweep, `Domain`, `Server`, `Provider`, `Elapsed_ms` (or `-1` on failure), `Status` (`Success`, `Sinkhole`, `NXDOMAIN`, `Fail`), and Win32 `ErrorId`.

---

## Caveats & Details

- **Win32 Retransmit Backoffs:** When UDP packet drops occur on WAN links, Windows waits ~1 s, then ~2 s before retrying. Queries landing near ~1000 ms or ~3000 ms with 0% total loss reflect dropped packets recovered by retransmissions. These delays are real and will be experienced by browsers and applications.
- **IPv4 / A Records:** The benchmark queries IPv4 A records over UDP. IPv6 (AAAA) resolution is not currently tested.
- **Sinkhole & ISP Hijack Handling:** Resolvers returning `0.0.0.0`, `127.0.0.1`, RFC 1918 private space, or RFC 6598 CGNAT (`100.64.0.0/10`) are marked as `Filtered` and excluded from latency calculations, preventing fake < 5 ms redirect responses from masquerading as fast resolutions.
- **Local Caching Proxies:** Addresses in `127.0.0.0/8` are filtered out of active adapter discovery, as benchmarking a local cache daemon (like Unbound or Acrylic) does not measure upstream WAN transit.
- **Unreachable Resolvers:** Windows takes ~10 seconds to fully time out an unreachable resolver across all retry stages. If an ISP blocks specific public DNS addresses, use `-ExcludeServers` to skip them and prevent benchmark stalls.
- **Terminal Session Safety:** Pre-flight checks use `return` instead of `exit 1` so that launching the script in an active PowerShell window or VS Code terminal will not close the shell if a network check fails.
