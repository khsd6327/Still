# Compatibility results

Compatibility results describe the exact boundary reached by a specific
application and configuration. They are not general compatibility guarantees.

## 2026-07-31

Test configuration: Apple silicon, Wine Staging 11.14, MoltenVK 1.4.0, DXMT
revision `3525d41c71604ed07d796de5b58560e3cf6db944`, and Still's versioned direct
Wine Metal bridge without library injection.

| Application | Verified boundary | Result |
| --- | --- | --- |
| Steam client | Rendered the sign-in interface through the Raw ANGLE Wine patch and DXMT | Passed UI rendering check |
| Supermarket Chaos | Loaded beyond the menus into the rendered 3D store scene and tutorial overlay | Passed rendering check |
| Cash Cleaner Simulator | Loaded an existing save into the rendered first-person workplace; movement produced a new frame | Passed rendering check |

These results do not validate sustained play, performance, audio, controllers,
save integrity, networking, multiplayer, anti-cheat, full-screen transitions,
sleep and resume, or clean termination.

## Engine availability

The Steam UI result requires the tested patched Wine and DXMT engine. The
normal engine catalog does not install that engine yet, so the result is not a
general guarantee for catalog engines or other Steam client builds.
