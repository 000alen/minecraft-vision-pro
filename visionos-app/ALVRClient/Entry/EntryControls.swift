/*
Abstract:
Controls that allow entry into the ALVR environment.
*/

import SwiftUI

/// Controls that allow entry into the ALVR environment.
struct EntryControls: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var eventHandler = EventHandler.shared
    @EnvironmentObject var gStore: GlobalSettingsStore
    
    @State private var immersiveSpaceIsShown = false
    @State private var entryMessage = "Start VisionCraftHost on the Mac, then wait for this client to connect."
    
    let saveAction: ()->Void

    var body: some View {
        @Bindable var model = model
        
        VStack(spacing: 8) {
            HStack(spacing: 17) {
                if eventHandler.connectionState == .connected {
                    Toggle(isOn: $model.isShowingClient) {
                        Label(model.isShowingClient ? "Exit" : "Enter", systemImage: "visionpro")
                            .labelStyle(.titleAndIcon)
                            .padding(15)
                    }
                } else {
                    Label("Waiting for VisionCraftHost", systemImage: "visionpro")
                        .labelStyle(.titleOnly)
                        .padding(15)
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .glassBackgroundEffect(in: .rect(cornerRadius: 50))

            Text(entryMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 520)
        }
        .onChange(of: eventHandler.connectionState) { _, state in
            entryMessage = state == .connected
                ? "Connected to VisionCraftHost. Press Enter to open the immersive stream."
                : "Waiting for VisionCraftHost. On the Mac, run scripts/vc.sh host --rebuild."
        }

        //Enable Client
        .onChange(of: model.isShowingClient) { _, isShowing in
            Task {
                if isShowing {

                    saveAction()
                    print("Opening Immersive Space")
                    if gStore.settings.realityKitRenderer {
                        if !DummyMetalRenderer.haveRenderInfo {
                            var dummySpaceIsOpened = false
                            while !dummySpaceIsOpened {
                                switch await openImmersiveSpace(id: "DummyImmersiveSpace") {
                                case .opened:
                                    dummySpaceIsOpened = true
                                case .userCancelled:
                                    entryMessage = "Immersive entry was cancelled. Press Enter when you are ready to try again."
                                    model.isShowingClient = false
                                    return
                                case .error:
                                    entryMessage = "Could not open the setup immersive space. Check visionOS permissions, then try again."
                                    model.isShowingClient = false
                                    return
                                @unknown default:
                                    entryMessage = "Could not open the setup immersive space. Try again after checking permissions."
                                    model.isShowingClient = false
                                    return
                                }
                            }
                            
                            while dummySpaceIsOpened && !DummyMetalRenderer.haveRenderInfo {
                                try? await Task.sleep(nanoseconds: 1_000_000)
                            }
                            
                            await dismissImmersiveSpace()
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        
                        if !DummyMetalRenderer.haveRenderInfo {
                            print("MISSING VIEW INFO!!")
                        }
                        
                        WorldTracker.shared.worldTrackingAddedOriginAnchor = false
                        
                        print("Open real immersive space")
                        
                        switch await openImmersiveSpace(id: "RealityKitClient") {
                        case .opened:
                            immersiveSpaceIsShown = true
                            entryMessage = "Full VR stream open. For ALVR-only test: Mac `scripts/vc.sh synthetic`. Stable = edge bars + checkerboard."
                        case .userCancelled:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Immersive entry was cancelled. Press Enter to try again."
                        case .error:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Could not open the immersive stream. Check permissions and run scripts/vc.sh doctor on the Mac."
                        @unknown default:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Could not open the immersive stream. Check permissions and try again."
                        }
                    }
                    else {
                        switch await openImmersiveSpace(id: "MetalClient") {
                        case .opened:
                            immersiveSpaceIsShown = true
                            entryMessage = "Full VR stream open. For ALVR-only test: Mac `scripts/vc.sh synthetic`. Stable = edge bars + checkerboard."
                        case .userCancelled:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Immersive entry was cancelled. Press Enter to try again."
                        case .error:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Could not open the immersive stream. Check permissions and run scripts/vc.sh doctor on the Mac."
                        @unknown default:
                            immersiveSpaceIsShown = false
                            model.isShowingClient = false
                            entryMessage = "Could not open the immersive stream. Check permissions and try again."
                        }
                    }
                    VideoHandler.applyRefreshRate(videoFormat: EventHandler.shared.videoFormat)
                    if gStore.settings.dismissWindowOnEnter {
                        dismissWindow(id: "Entry")
                    }
                } else if immersiveSpaceIsShown {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                    entryMessage = "Exited the immersive stream."
                }
            }
        }

    }
}
