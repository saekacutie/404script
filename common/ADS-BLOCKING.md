# Ad-blocking policy reference

`ADS_MODE=noads` enables domain routing to Xray's `block` outbound. `ADS_MODE=ads`
uses the unrestricted profile.

| Level | Policy | Trade-off |
|---|---|---|
| `light` | Common ad domains (`category-ads`) | Lowest breakage; misses some trackers |
| `standard` | Full ad lists (`category-ads-all`) | Recommended default |
| `strict` | Ads plus tracking (`category-tracking`) | More privacy; analytics may stop working |
| `extreme` | Ads, tracking, and social/telemetry categories | Highest blocking; legitimate widgets and sign-in flows may break |

This is domain-based proxy filtering, not a browser content blocker. It cannot
promise 100% removal of ads, especially first-party ads, ads embedded in content,
hard-coded IPs, QUIC/UDP bypasses, or domains not present in the rule database.

The image build downloads `geosite.dat` and the entrypoint runs `xray run -test`
before starting the proxy. If the asset or generated policy is invalid, the
container exits instead of silently running without filtering.
