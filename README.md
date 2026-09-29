# DNS Benchmark Script

A lightweight, non-invasive DNS benchmark script for Windows designed to test DNS resolvers under real-world connection conditions (such as high-jitter FWA, 4G/5G, or fiber links).

Runs via double-click wrapper (`dns-bench.bat`) or directly in PowerShell, compares public resolvers against your current active network connection, and exports a CSV report.

---

## What It Does

- **Active System DNS Baseline:** Automatically detects and benchmarks DNS resolvers configured on currently connected network adapters (`Status = 'Up'`). Inactive or disconnected adapters (e.g. stale Wi-Fi or VPN profiles) are ignored.
- **Interleaved Testing:** Queries servers round-robin using identical domains per round, ensuring connection spikes or jitter affect all resolvers equally.
- **Cache Warm-Up Discard:** Discards the initial test round to eliminate cold-cache penalties and startup latency.
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
2. Wait for the test rounds to complete.
3. Review the results table and recommendation in the command window.

### Method 2: PowerShell CLI
Run directly in PowerShell with default settings (8 rounds):
```powershell
powershell -ExecutionPolicy Bypass -File .\dns-bench.ps1
```

Optional parameters:
```powershell
# Run with 12 rounds
.\dns-bench.ps1 -Rounds 12

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
