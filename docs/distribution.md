# Distribution notes (local beta)

VisionCraft is intended as a **local developer / personal beta**, not an App Store product.

## What you may ship

| Artifact | Built by | Notes |
|----------|----------|-------|
| `VisionCraftHost.app` | `scripts/vc.sh package-beta` | macOS app; must be signed with **your** Developer ID or run from Xcode |
| `ALVRClient` on AVP | Xcode / `visionos-app/ALVRClient.xcodeproj` | visionOS signing + device provisioning required |
| Vivecraft mod JAR | `./gradlew` in `minecraft/VivecraftMod/` | GPL obligations from upstream Vivecraft apply |

## Signing

- Mac host: configure team in `mac-host/Config/Signing.xcconfig` (from `Signing.xcconfig.example`) or Xcode signing settings.
- Headset client: use the same Apple team as documented in `visionos-app/README.md` / `mac-host/README.md`.
- Do not commit provisioning profiles, `.p12` files, or API keys.

## Third-party compliance

- **ALVR** — MIT (see `visionos-app/ALVR/LICENSE`). Preserve license notice if redistributing ALVR-derived binaries.
- **Vivecraft** — GPL-family (verify in `minecraft/VivecraftMod/`). Source offer requirements may apply if you distribute mod binaries to others.
- **Minecraft** — Not included; users must own the game.

## Recommended distribution shape

1. Source repository (this repo) for builders.
2. Optional: private TestFlight / ad hoc AVP build + signed Mac host zip for a closed tester list.
3. Avoid publishing unsigned ALVR server binaries that impersonate official ALVR releases.
