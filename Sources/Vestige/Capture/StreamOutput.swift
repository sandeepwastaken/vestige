import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Bridges ScreenCaptureKit's Objective-C delegate callbacks to closures.
///
/// `SCStreamOutput` must be an `NSObject`, which cannot be an actor, so this
/// sits at the boundary: frames arrive on ScreenCaptureKit's queues and go
/// straight into thread-safe consumers with no actor hop. Keeping the path
/// allocation- and hop-free matters at 60–120 frames a second all session.
///
/// Audio is deliberately absent — `capturesAudio = false` and no audio output
/// is registered, because `SystemAudioStream` captures it separately.
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onVideo: @Sendable (CMSampleBuffer) -> Void
    private let onStop: @Sendable (Error?) -> Void

    init(
        onVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
        onStop: @escaping @Sendable (Error?) -> Void
    ) {
        self.onVideo = onVideo
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer)
        else { return }
        onVideo(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// ScreenCaptureKit delivers a frame on every vsync tick, marking those with
    /// no new content as `.idle`. Encoding those would burn power to produce
    /// duplicate frames, so only `.complete` frames are forwarded — the resulting
    /// variable frame rate is exactly what a screen recording should have.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return false }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFDictionary.self)

        let key = Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque()
        var value: UnsafeRawPointer?
        guard CFDictionaryGetValueIfPresent(dictionary, key, &value), let value else {
            return false
        }

        let number = unsafeBitCast(value, to: CFNumber.self)
        var rawStatus = 0
        guard CFNumberGetValue(number, .intType, &rawStatus) else { return false }

        return SCFrameStatus(rawValue: rawStatus) == .complete
    }
}
