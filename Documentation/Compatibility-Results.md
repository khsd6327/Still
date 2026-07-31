# Compatibility results

Compatibility results describe the exact boundary reached by a specific
application and configuration. They are not general compatibility guarantees.

## 2026-07-31

Test configuration: Apple silicon, Wine Staging 11.14, MoltenVK 1.4.0, DXMT,
and Still's Wine Metal bridge.

| Application | Verified boundary | Result |
| --- | --- | --- |
| Supermarket Chaos | Loaded beyond the menus into the rendered 3D store scene and tutorial overlay | Passed rendering check |
| Cash Cleaner Simulator | Loaded an existing save into the rendered first-person workplace; movement produced a new frame | Passed rendering check |

These results do not validate sustained play, performance, audio, controllers,
save integrity, networking, multiplayer, anti-cheat, full-screen transitions,
sleep and resume, or clean termination.
