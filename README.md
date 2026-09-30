# DNS Benchmark Script

A lightweight, non-invasive DNS benchmark script for Windows designed to test DNS resolvers under real-world connection conditions (such as high-jitter FWA, 4G/5G, or fiber links).

Runs via double-click wrapper (`dns-bench.bat`) or directly in PowerShell, compares public resolvers against your current active network connection, and exports a CSV report.

---

## What It Does

- **Active System DNS Baseline:** Automatically detects and benchmarks DNS resolvers configured on currently connected network adapters (`Status = 'Up'`). Inactive or disconnected adapters (e.g. stale Wi-Fi or VPN profiles) are ignored.
- **Interleaved Testing:** Queries servers round-robin using identical domains per pass, ensuring connection spikes or jitter affect all resolvers equally.
- **Cache Warm-Up Discard:** Discards the warm-up pass to eliminate cold-cache penalties and startup latency.
- **Comprehensive Metrics:** Measures and displays `Min`, `Median`, `Average`, `Max`, `Jitter` (spread), and failure count per resolver. Failed or unreachable servers sort cleanly to the bottom.
- **Dual Smart Recommendations (Stability vs. Speed):**
  - **Most Stable Pair:** Recommends the family pair with the lowest maximum latency and minimal jitter (best for coding, work, streaming, and daily browsing without lag spikes).
  - **Fastest Raw Median:** Identifies the lowest base ping pair while flagging multi-second latency spikes if detected.
- **Family-Aware Pairing:** Always pairs a primary resolver with its sibling secondary resolver from the same provider family, preventing filtering leaks during failovers.
- **CSV Logging:** Automatically saves results with timestamps (`dns-bench-yyyyMMdd-HHmmss.csv`) for record keeping. Historical baseline runs can be archived in the `results/` folder for daytime vs. peak-hour comparisons.
- **100% Safe & Read-Only:** Only sends standard DNS queries via native `Resolve-DnsName`. Does **not** modify adapter settings, flush cache, touch the registry, or require Administrator privileges.

---

## Tested Resolvers

| Provider | Primary IP | Secondary IP | Notes |
| :--- | :--- | :--- | :--- |
| **Current System** | *Auto-detected* | — | Active network DNS on connected adapter (`Status = 'Up'`) |
| **Cloudflare** | `1.1.1.1` | `1.0.0.1` | Standard fast public resolver |
| **Cloudflare Malware** | `1.1.1.2` | `1.0.0.2` | Blocks known malware |
| **Google** | `8.8.8.8` | `8.8.4.4` | Standard public resolver |
| **Quad9** | `9.9.9.9` | `149.112.112.112` | Threat intelligence and malware blocking |
| **OpenDNS** | `208.67.222.222` | `208.67.220.220` | Cisco Umbrella family |
| **AdGuard** | `94.140.14.14` | `94.140.15.15` | Default ad and tracker blocking |

---

## How to Use

### Method 1: Double-Click (Recommended)
1. Double-click `dns-bench.bat`.
2. Wait for the test passes to complete.
3. Review the results table and recommendation in the command window.

### Method 2: PowerShell CLI
Run directly in PowerShell with default settings (5 passes = 20 scored queries per server plus 1 warm-up pass):
```powershell
powershell -ExecutionPolicy Bypass -File .\dns-bench.ps1
```

Optional parameters:
```powershell
# Run with 8 passes
.\dns-bench.ps1 -Passes 8

# Exclude specific servers from testing
.\dns-bench.ps1 -ExcludeServers '1.1.1.1','1.0.0.1'

# Benchmark specific servers only
.\dns-bench.ps1 -Servers '9.9.9.9','149.112.112.112','208.67.222.222','208.67.220.220'

# Benchmark custom domains
.\dns-bench.ps1 -Domains 'github.com','cloudflare.com','google.com'
```

---

## Analysis Tips

- **Median vs. Jitter:** Always check both **Med_ms** (typical speed) and **Jitter_ms** / **Max_ms** (consistency). A resolver with a 45 ms median but a 7,000 ms spike will feel much worse than a steady 60 ms resolver with a 75 ms max.
- **Human Perception:** A difference under 15–20 ms is rarely noticeable during daily web browsing. Prioritize stability and security features over negligible median gains.
- **Family Pairing:** If you use a security or ad-blocking resolver, ensure both primary and secondary DNS use the same provider to avoid security leaks during failovers.

---

## Known Limitations

- **Warm-Cache Edge Latency:** Queries use popular domains primed by a warm-up pass, measuring network transit RTT to each provider's Anycast edge location rather than cold recursive resolution performance.
- **IPv4 and A Records Only:** Benchmarks IPv4 DNS resolvers and queries `A` records only; IPv6 addresses and `AAAA` records are not tested.
- **Loopback Resolvers (127.0.0.1):** Local caching daemons or proxies listening strictly on `127.0.0.1` are not auto-detected as System DNS.
- **Adapter Scope:** System DNS detection inspects all connected network adapters (`Status = 'Up'`). If VPN connections or virtual adapters (e.g. WSL/Hyper-V) are active, their configured DNS addresses will appear as additional System rows.
- **Unreachable Servers & Runtime:** When a target server is unreachable or offline, Windows DNS client retry backoff takes roughly 10 seconds per query against that server before timing out. To avoid long runs, use `-ExcludeServers` to omit dead or blocked servers.
- **CSV Missing Data:** A value of `-1` in the exported CSV metrics indicates that no successful response was received for that server.
- **Loss Counting:** `Loss_pct` counts only queries that fail completely after the Windows DNS client has finished its own retries. A query whose first packet was lost but which succeeds on a resend is counted as a success.
- **Latency Spikes from Retries:** Because of those retries, a `Max_ms` near 1, 3, or 7 seconds with 0% loss typically means a packet was resent (Windows waits about 1, 2, then 4 seconds between attempts). The script cannot see the resend directly; this is inferred from the timing pattern.
- **Jitter Filtering:** `Jitter_ms` is computed only from successful samples under 1,000 ms, so very long spikes are shown in `Max_ms` but not in `Jitter_ms`.
- **Recommendation Logic:** The "Most Stable" pick avoids servers with multi-second spikes while "Fastest Raw" may include them, as the console output labels it.
