// VisionCraft — OpenGL / IOSurface → Metal interop spike (M6)
// Build as part of libvisioncraft_bridge.dylib on macOS only.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

extern "C" {

/// Placeholder: create IOSurface-backed Metal texture from OpenGL texture name.
/// Returns 0 on success, negative on failure. Not used in MVP CPU transport path.
int visioncraft_iosurface_import_gl_texture(uint32_t glTextureId, void* _Nonnull metalDevicePtr) {
    (void)glTextureId;
    (void)metalDevicePtr;
    return -1; // NOT_IMPLEMENTED — see docs/frame-transport.md phase 3
}

const char* _Nonnull visioncraft_bridge_native_version(void) {
    return "visioncraft-bridge-native-0.1.0-mvp";
}

}
