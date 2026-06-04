// Headless self-test for the Mac-side frame-capture pipeline.
//
// Drives the REAL production Swift code — `StereoFrameEncoder` (SBS pack + HEVC encode) and
// `FrameCapture` (recv/sbs/decoded PNG writers + HEVC self-decode roundtrip) — with synthetic
// per-eye RGBA8 buffers. No GUI, no ALVR, no Apple Vision Pro required.
//
// Build + run via `mac-host/Tests/run-capture-selftest.sh`, which compiles this together with the
// two production sources (they depend only on system frameworks, not the ALVR shim/dylib).
//
// Output bundle: <outRoot>/.run/captures/<ts>/{recv,sbs,decoded}/*.png + header.json + manifest.
// The synthetic stereo pair is generated bottom-left origin (OpenGL convention) so:
//   - recv/*.png  (FrameCapture flips) come out UPRIGHT,
//   - sbs/*.png   (no flip; matches the encoder contract) come out vertically MIRRORED of recv,
//     with the LEFT half = left eye and the RIGHT half = right eye,
//   - decoded/*.png should match sbs within HEVC tolerance.

import Foundation

let args = CommandLine.arguments
let outRoot = args.count > 1 ? args[1] : NSTemporaryDirectory() + "vc-selftest"
let eyeW = args.count > 2 ? (Int(args[2]) ?? 512) : 512
let eyeH = args.count > 3 ? (Int(args[3]) ?? 512) : 512
let frames = args.count > 4 ? (Int(args[4]) ?? 3) : 3

/// Build a distinct, checkable RGBA8 pair (row 0 = bottom). Left eye is red-based with a green
/// vertical bar at x=W/4; right eye is blue-based with a yellow bar at x=3W/4. A white block marks
/// the visual TOP-LEFT of each eye, and brightness rises toward the top, so orientation and the
/// left/right-half packing are both visually verifiable in the output PNGs.
func makeStereoPair(width: Int, height: Int, frame: Int) -> (Data, Data) {
    var left = [UInt8](repeating: 0, count: width * height * 4)
    var right = [UInt8](repeating: 0, count: width * height * 4)
    let barW = max(4, width / 40)
    let leftBarX = width / 4
    let rightBarX = (3 * width) / 4
    let markH = max(8, height / 8)
    let markW = max(8, width / 8)
    // Small per-frame shift of the bars so successive frames differ (exercises delta frames).
    let shift = (frame - 1) * max(2, width / 64)
    for r in 0..<height {
        let bright = Double(r) / Double(max(1, height - 1)) // row 0 = bottom => top brighter
        let topRegion = r > (height - 1 - markH)
        for c in 0..<width {
            let i = (r * width + c) * 4
            var lr = UInt8(min(255.0, 40.0 + 160.0 * bright)); var lg: UInt8 = 30; var lb: UInt8 = 30
            if c >= leftBarX + shift && c < leftBarX + shift + barW { lr = 40; lg = 220; lb = 40 }
            if topRegion && c < markW { lr = 255; lg = 255; lb = 255 }
            left[i] = lr; left[i + 1] = lg; left[i + 2] = lb; left[i + 3] = 255
            var rr: UInt8 = 30; var rg: UInt8 = 30; var rb = UInt8(min(255.0, 40.0 + 160.0 * bright))
            if c >= rightBarX - shift && c < rightBarX - shift + barW { rr = 220; rg = 220; rb = 40 }
            if topRegion && c < markW { rr = 255; rg = 255; rb = 255 }
            right[i] = rr; right[i + 1] = rg; right[i + 2] = rb; right[i + 3] = 255
        }
    }
    return (Data(left), Data(right))
}

let header = "{\"selftest\":true,\"eye_width\":\(eyeW),\"eye_height\":\(eyeH),\"frames\":\(frames)}"
let bundle = FrameCapture.shared.arm(frames: frames, repoRoot: outRoot, header: header)
guard !bundle.isEmpty else {
    FileHandle.standardError.write(Data("self-test: failed to arm capture\n".utf8))
    exit(1)
}
print("self-test bundle: \(bundle)")

let encoder = StereoFrameEncoder()
let auLock = NSLock()
var accessUnits = 0
encoder.onAccessUnit = { au in
    auLock.lock(); accessUnits += 1; auLock.unlock()
    print("access unit: frame=\(au.frameId) keyframe=\(au.keyframe) bytes=\(au.data.count)")
}
encoder.configure(eyeWidth: eyeW, eyeHeight: eyeH, fps: 90)
encoder.requestKeyframe() // first frame is an IDR so the self-decode chain starts clean

for f in 1...frames {
    let (left, right) = makeStereoPair(width: eyeW, height: eyeH, frame: f)
    FrameCapture.shared.captureReceived(left: left, right: right, width: eyeW, height: eyeH,
                                        frameId: UInt64(f))
    encoder.encode(left: left, right: right, eyeWidth: eyeW, eyeHeight: eyeH,
                   frameId: UInt64(f), targetTimestampNs: UInt64(f) * 1_000_000)
    // Space frames so the latest-frame-wins encoder does not drop any (we want all N).
    Thread.sleep(forTimeInterval: 0.2)
}

var waited = 0.0
while FrameCapture.shared.isActive && waited < 10.0 {
    Thread.sleep(forTimeInterval: 0.1)
    waited += 0.1
}
encoder.stop()
Thread.sleep(forTimeInterval: 0.3)

auLock.lock(); let total = accessUnits; auLock.unlock()
print("self-test done: accessUnits=\(total) captureActive=\(FrameCapture.shared.isActive) bundle=\(bundle)")
