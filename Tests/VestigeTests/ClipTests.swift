import Foundation
import Testing
@testable import Vestige

@Suite("Clip")
struct ClipTests {
    @Test("generated filenames use sanitized game names and stable timestamps")
    func generatedFilename() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/Chicago")
        components.year = 2026
        components.month = 7
        components.day = 10
        components.hour = 15
        components.minute = 42
        components.second = 13

        let date = try #require(components.date)
        let filename = Clip.filename(for: date, gameName: #"Cool/Game: "Final"?"#)

        #expect(filename == #"Cool-Game- -Final-- 2026-07-10 at 15.42.13.mp4"#)
    }

    @Test("unsafe or hidden clip names fall back to Vestige")
    func sanitizeNameFallbacks() {
        #expect(Clip.sanitizeName("") == "Vestige")
        #expect(Clip.sanitizeName("   ") == "Vestige")
        #expect(Clip.sanitizeName(".hidden") == "Vestige")
    }

    @Test("generated names are recognized for retention")
    func generatedNameDetection() {
        let generated = Clip(
            url: URL(fileURLWithPath: "/tmp/Vestige 2026-07-10 at 15.42.13.mp4"),
            createdAt: .now,
            fileSize: 1,
            duration: 1
        )
        let renamed = Clip(
            url: URL(fileURLWithPath: "/tmp/boss fight.mp4"),
            createdAt: .now,
            fileSize: 1,
            duration: 1
        )

        #expect(generated.hasGeneratedName)
        #expect(!renamed.hasGeneratedName)
    }
}
