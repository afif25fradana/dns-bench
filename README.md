# DNS Benchmark

A small PowerShell script that tells you which public DNS resolver is actually fastest from your connection — not from a data center on the other side of the planet.

It runs a warm-up pass to prime resolver caches, then tests each server in a round-robin rotation across 8 popular domains and gives you a ranked table with median latency, jitter, and packet loss. At the end it recommends the most stable pair and the raw fastest pair, compares them to whatever DNS you're currently using, and prints the exact command to switch.

Works on Windows PowerShell 5.1+. No admin rights needed to run the benchmark.

---

## What it measures

- **Min / Median / Average / Max latency** — in milliseconds, calculated on clean (< 1000 ms) samples so retry backoffs don't skew your baseline numbers.
- **P90 latency** — 90th percentile clean latency (using NIST / R-7 linear interpolation), showing what 90% of your lookups feel like.
- **Spikes** — queries that took >= 1000 ms due to packet loss and Windows DNS client retry backoffs.
- **Jitter** — within-domain mean absolute successive difference across clean (< 1000 ms) samples, averaged across domains. Spikes are excluded so an occasional packet drop doesn't distort stability.
- **Packet loss %** — queries that timed out completely after Windows exhausted its retry attempts.

Servers with > 10% loss sort to the bottom. `-1` in the CSV means no successful response was received for that server at all.

A note on what the numbers actually mean: after the warm-up pass, the resolver's own cache answers repeat queries. So you're measuring **warm-cache RTT to the provider's anycast edge**, not cold recursive resolution speed. That's the number that matters for your actual browsing anyway.

---

## Resolvers tested by default

| Provider | Primary | Secondary | Notes |
| :--- | :--- | :--- | :--- |
| **Your System DNS** | auto-detected | — | Whatever is configured on your active adapter |
| **Cloudflare** | `1.1.1.1` | `1.0.0.1` | Fast public resolver |
| **Cloudflare Malware** | `1.1.1.2` | `1.0.0.2` | Blocks known malware domains |
| **Google** | `8.8.8.8` | `8.8.4.4` | Standard public resolver |
| **Quad9** | `9.9.9.9` | `149.112.112.112` | Threat intelligence blocking |
| **OpenDNS** | `208.67.222.222` | `208.67.220.220` | Cisco Umbrella |
| **AdGuard** | `94.140.14.14` | `94.140.15.15` | Ad and tracker blocking |

---

## How to run

### Just double-click

Double-click `dns-bench.bat`. A window opens, runs the test, pauses so you can read the results, and closes when you press a key.

### PowerShell

```powershell
.\dns-bench.ps1
```

Or via explicit policy bypass if your system blocks unsigned scripts:
```powershell
powershell -ExecutionPolicy Bypass -File .\dns-bench.ps1
```

### Options

```powershell
# More passes = more data points, longer run
.\dns-bench.ps1 -Passes 8

# Quick check with 2 passes and 4 domains (~1 min)
.\dns-bench.ps1 -Quick

# Skip specific servers
.\dns-bench.ps1 -ExcludeServers '1.1.1.1','1.0.0.1'

# Test specific servers only
.\dns-bench.ps1 -Servers '9.9.9.9','149.112.112.112','208.67.222.222','208.67.220.220'

# Test against different domains
.\dns-bench.ps1 -Domains 'github.com','cloudflare.com','google.com'
```

`-Rounds` is accepted as an alias for `-Passes`.

---

## Reading the results

The table is sorted by median latency. Servers that failed too many queries appear at the bottom.

**Median, P90, and Spikes:** A resolver with a 45 ms median but frequent multi-second spikes will feel much worse than a steady 60 ms resolver capped under 80 ms. Look at `P90_ms`, `Spikes`, and `Jitter_ms` alongside `Med_ms`.

**Smart Recommendations & 15 ms Dead-Band:** Normal browsing rarely notices latency differences under 15–20 ms. When two providers are within 15 ms of each other, the script prioritizes security features (threat/malware filtering like Quad9 or Cloudflare Malware) over fractions of a millisecond in raw speed. If you prefer pure minimum ping regardless of filtering, the "Fastest Raw Median" option is always shown alongside it.

**Family pairing:** Recommendations always pair a resolver with its sibling from the same provider. That keeps security filtering consistent during a failover — mixing Quad9 (threat blocking) with Google (unfiltered) as primary/secondary means some traffic bypasses the filter.

---

## Results files

Every run saves two CSVs to the `results/` folder next to the script:

- `dns-bench-YYYYMMDD-HHmmss.csv` — aggregate stats, one row per server.
- `dns-bench-YYYYMMDD-HHmmss-samples.csv` — every individual query with timestamp, pass number, domain, server, and elapsed time. Useful for comparing daytime vs. peak-hour runs.

A value of `-1` in the CSV means that server returned no successful responses.

---

## Caveats worth knowing

**Spikes near 1 s, 3 s, or 7 s with 0% loss** usually mean a packet was dropped and Windows retransmitted it (it waits ~1 s, ~2 s, then ~4 s between attempts). The script can't see the retransmit directly, but the timing pattern is unmistakable. These delays are real and are what your browser would also experience.

**IPv4 / A records only.** IPv6 resolvers and AAAA queries aren't tested.

**VPN or virtual adapters active?** If Docker, Hyper-V, WSL, or an active VPN tunnel is up, its DNS addresses may appear as additional "System DNS" rows. That's expected — they're real resolvers your system could use.

**127.0.0.1 (local caching proxies) are excluded.** If you run a local DNS cache like Unbound or dnscrypt-proxy, it listens on loopback and is filtered out intentionally.

**Slow servers time out slowly.** When a server is unreachable, Windows takes roughly 10 seconds per query before giving up. Use `-ExcludeServers` to skip any server you know is blocked or down.
