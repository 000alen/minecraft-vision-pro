# Native bridge library

MVP frame transport uses **TCP + RGBA8** from Java; no dylib required at runtime.

`MetalInterop.mm` is a stub for M6 IOSurface import. Build on macOS:

```bash
clang++ -std=c++17 -fobjc-arc -shared -o libvisioncraft_bridge.dylib MetalInterop.mm \
  -framework Foundation -framework IOSurface -framework Metal
```

Install next to `VisionCraftHost.app` when interop is implemented.
