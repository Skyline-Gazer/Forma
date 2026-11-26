# Track B/C — DEVONthink Index + OneDrive physical verification (2026-11-26)

Host: macOS 27.2.1 (26B131), Apple M1 Pro · DEVONthink 4.4.2 · OneDrive 26.168.0830
(`~/Library/CloudStorage/OneDrive-个人`) · test database on local SSD, never inside OneDrive.

## What was actually possible
| Scenario | Verdict |
|---|---|
| B1 online-only fixtures in real OneDrive File Provider | **BLOCKED_WITH_EVIDENCE** |
| B2 logical vs allocated storage measurement | **PARTIAL** |
| B3 index / search / tags / custom metadata / smart groups | **PARTIAL** |
| B4 Free Up Space on test files | **BLOCKED_WITH_EVIDENCE** |
| B5 restart, re-search, preview, single-file open | **PARTIAL** |
| B6 metadata sync with indexed content disabled | **NOT_VERIFIED** |
| B7 fresh profile / second device restore | **NOT_VERIFIED** |
| C1 UUID, tags, custom-field read/write | **PASS** |
| C2 rename / move / parent rename / content update | **PASS** |
| C2b cross-device OneDrive change | **NOT_VERIFIED** |
| C2c per-file eviction / rehydration | **BLOCKED_WITH_EVIDENCE** |
| C3 Sorty interop, retry, idempotency | **PASS** |
| C4 file vs record vs path vs content-hash identity | **PASS** |

## Numbers
- Fixtures: 8 synthetic documents, logical **22 232 B**, allocated **49 152 B** (4 KiB blocks); 0 online-only files could be produced.
- First index: **0.95 s** for 8 files; DEVONthink test DB **159 744 B** allocated (156 KiB) after indexing, tags, custom metadata and two Sorty cases.
- Search after full DEVONthink restart: `PRJ-A-001` → 5 hits, `澄湾医院` → 4 hits; index survived restart.
- Identity retention: **5/5 testable operations kept the record UUID** (rename, same-volume move, parent rename, content update, Sorty-driven move); custom metadata and tag objects retained in all of them.
- Content hash changed only when bytes changed (`d2deeb26…` → `8b500efb…`); path never used as identity.
- Re-applying the same Sorty plan was refused by validation (destination exists / source missing) with **zero partial writes**.
- Cache/space: no hydration was induced (eviction blocked), so cache growth is the 156 KiB database only; reclaimable space **not measurable**.

## Why eviction was impossible
`brctl evict` targets CloudDocs/iCloud and rejects File Provider paths
(`BRCloudDocsErrorDomain 6 "Path is outside of any CloudDocs app library"`).
`fileproviderctl` exposes only `dump/diagnose/check/evaluate/obfuscate` on this build,
the OneDrive app has no CLI or AppleScript surface, and `onedrive.live.com` is unreachable
from this network, so no placeholder could be created or revived. This is a genuine
capability gap, not a skipped test.

## Gaps and residual risk
- Online-only behaviour, eviction recovery and hydration counts are **unverified** on this host; Track B's core storage claim cannot be scored.
- Custom-metadata *search by key* does not work (`project_code:HC26-041` → 0), so metadata can be stored but not queried like a first-class field through AppleScript.
- Smart Groups are not creatable through the DEVONthink 4.4.2 scripting dictionary; they remain a UI-only feature (NOT_SUPPORTED via automation).
- Tag-name readback via AppleScript fails; tag count and lookup by tag list are the only scriptable views.
- Sync behaviour, fresh-profile restore and cross-device identity remain untested; no sync location exists on this machine.

## Reuse-first implication (input for #216)
Native DEVONthink Index + AppleScript covers record identity and metadata durability for
renames/moves/content changes, including Sorty-driven reorganisations — the strongest
result here. It does not deliver: scriptable smart groups, metadata-key search, or any
measurable online-only/eviction story on this Mac. Those are configuration gaps (sync
location, UI-only features) plus one platform gap (File Provider eviction tooling), not
reasons to build Forma by themselves.
