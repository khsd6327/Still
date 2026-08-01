# Compatibility results

Compatibility results describe the exact boundary reached by a specific
application and configuration. They are not general compatibility guarantees.

## 2026-07-31

Test configuration: Apple silicon, Wine Staging 11.14, MoltenVK 1.4.0, DXMT
revision `3525d41c71604ed07d796de5b58560e3cf6db944`, and Still's versioned direct
Wine Metal bridge without library injection.

| Application | Verified boundary | Result |
| --- | --- | --- |
| Supermarket Chaos | Loaded beyond the menus into the rendered 3D store scene and tutorial overlay | Passed rendering check |
| Cash Cleaner Simulator | Loaded an existing save into the rendered first-person workplace; movement produced a new frame | Passed rendering check |

These results do not validate sustained play, performance, audio, controllers,
save integrity, networking, multiplayer, anti-cheat, full-screen transitions,
sleep and resume, or clean termination.

## Known limitation

Steam currently creates a macOS window but does not produce usable interface
content with the tested open Wine and DXMT paths. This remains unresolved and
is a known alpha limitation, not a validated application result.
