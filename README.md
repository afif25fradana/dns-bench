# DNS Benchmark Script

A lightweight, non-invasive DNS benchmark script for Windows designed to test DNS resolvers under real-world connection conditions (such as high-jitter FWA, 4G/5G, or fiber links).

Runs via double-click wrapper (`dns-bench.bat`) or directly in PowerShell, compares public resolvers against your current active network connection, and exports a CSV report.

---

## What it does

- **Current System Baseline:** Automatically detects and tests the active DNS configured on your current network adapter (ISP or router gateway) so you can compare whether public resolvers actually improve your latency.
- **Interleaved Testing:** Queries servers round-robin using identical domains per round, ensuring connection spikes or jitter affect all resolvers equally.
- **Cache Warm-Up Discard:** Discards the initial test round to eliminate cold-cache penalties and startup latency.
- **Comprehensive Metrics:** Measures and displays `Min`, `Median`, `Average`, `Max`, and failure count per resolver.
- **Smart Recommendations:** Suggests the fastest primary and secondary resolver pair, with family-pairing reminders for security-filtering variants.
- **CSV Export:** Automatically saves results with timestamps (`dns-bench-yyyyMMdd-HHmmss.csv`) for record keeping and time-of-day comparisons.
- **100% Safe & Read-Only:** Only sends standard DNS queries via native `Resolve-DnsName`. Does **not** modify adapter settings, flush cache, touch the registry, or require Administrator privileges.

---

## Tested Resolvers

| Provider | Primary IP | Secondary IP | Notes |
| :--- | :--- | :--- | :--- |
| **Current System** | *Auto-detected* | — | Your current active network DNS (ISP / local router) |
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

Or specify custom rounds, servers, or domains:
```powershell
# Run with 12 rounds
.\dns-bench.ps1 -Rounds 12

# Benchmark specific servers only
.\dns-bench.ps1 -Servers '1.1.1.1','8.8.8.8','9.9.9.9'

# Benchmark custom domains
.\dns-bench.ps1 -Domains 'github.com','cloudflare.com','google.com'
```

---

## Tips

- **Median vs. Average:** Always compare the **Med_ms** (median) column rather than the average, as median is immune to occasional network spikes.
- **Human Perception:** A difference under 15–20 ms is rarely noticeable during daily web browsing. Prioritize security features (e.g., Quad9 or Cloudflare 1.1.1.2) unless one resolver is significantly faster.
- **Matching Filtering Pairs:** If you choose a security or ad-blocking resolver, ensure both primary and secondary DNS use the same provider to avoid security leaks.
