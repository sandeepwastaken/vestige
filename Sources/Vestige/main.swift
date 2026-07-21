import Foundation

// A `main.swift` rather than `@main` on the App type, so command-line flags are
// handled before AppKit or SwiftUI initialise anything: running a diagnostic
// must not create a menu bar item.

switch CommandLine.arguments.dropFirst().first {
case "--self-test":
    SelfTest.runAndExit()

case "--pipeline-test":
    // Runs the real capture pipeline and reports the ring buffer's contents.
    PipelineTest.runAndExit()

case "--audio-test":
    // Measures ScreenCaptureKit's audio delivery with nothing else involved.
    AudioTest.runAndExit()

case "--permissions":
    // Reports permission state without any chance of raising a dialog, and
    // exercises the polling path 5 times to prove it stays silent.
    PermissionReport.runAndExit()

case "--version":
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    print("Vestige \(version)")
    exit(0)

case "--help", "-h":
    print("""
    Vestige — a replay buffer for macOS.

    Vestige normally runs as a menu bar app with no arguments.

    Options:
      --self-test      Verify that this Mac can encode and write clips
      --audio-test     Measure system audio capture for 15 seconds
      --pipeline-test  Run the real capture pipeline and report the buffer
      --permissions    Report Screen Recording status without prompting
      --version        Print the version
      --help           Show this message
    """)
    exit(0)

default:
    SingleInstance.enforce()
    VestigeApp.main()
}
