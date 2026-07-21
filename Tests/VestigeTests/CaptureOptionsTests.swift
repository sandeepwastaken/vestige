import CoreGraphics
import Testing
@testable import Vestige

@Suite("Capture options")
struct CaptureOptionsTests {
    @Test("replay duration is clamped to supported bounds")
    func replayDurationClamping() {
        #expect(ReplayDuration(1).rawValue == ReplayDuration.minimumSeconds)
        #expect(ReplayDuration(9_999).rawValue == ReplayDuration.maximumSeconds)
        #expect(ReplayDuration(90).rawValue == 90)
    }

    @Test("replay duration labels are human readable")
    func replayDurationLabels() {
        #expect(ReplayDuration(30).label == "30 seconds")
        #expect(ReplayDuration(60).label == "1 minute")
        #expect(ReplayDuration(90).label == "1 min 30 sec")
        #expect(ReplayDuration(120).shortLabel == "2m")
    }

    @Test("output sizes preserve aspect ratio and use even dimensions")
    func outputSize() {
        let source = CGSize(width: 2561, height: 1441)

        #expect(VideoResolution.native.outputSize(for: source) == CGSize(width: 2560, height: 1440))
        #expect(VideoResolution.p1080.outputSize(for: source) == CGSize(width: 1918, height: 1080))
        #expect(VideoResolution.p720.outputSize(for: CGSize(width: 640, height: 360)) == CGSize(width: 640, height: 360))
    }
}
