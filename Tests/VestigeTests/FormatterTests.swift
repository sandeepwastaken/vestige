import Testing
@testable import Vestige

@MainActor
@Suite("Formatters")
struct FormatterTests {
    @Test("durations round and format as minutes and seconds")
    func durationFormatting() {
        #expect(Formatters.duration(0) == "0:00")
        #expect(Formatters.duration(64.4) == "1:04")
        #expect(Formatters.duration(64.5) == "1:05")
        #expect(Formatters.duration(.nan) == "--:--")
        #expect(Formatters.duration(-1) == "--:--")
    }
}
