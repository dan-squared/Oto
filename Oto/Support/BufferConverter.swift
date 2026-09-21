//
//  BufferConverter.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation

/// Converts mic tap buffers to the analyzer's required format. The tap
/// delivers the input's hardware format (which varies: 48 kHz device vs
/// 44.1 kHz client on some Macs); the analyzer needs its own.
/// Port of the Yap reference technique (`BufferConverter.swift`, MIT) as
/// Oto-owned code: cached converter, `primeMethod = .none`, per-buffer
/// capacity from the sample-rate ratio. Only ever touched under
/// `AudioFeedBox`'s lock (realtime thread), so no internal locking here.
final class BufferConverter {
    enum ConversionError: Error, Sendable {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed
    }

    // Touched only under `AudioFeedBox`'s lock (the sole owner — see the
    // single instantiation site): `nonisolated(unsafe)` memory with a
    // checked `nonisolated` entry point (Swift 6, default MainActor
    // isolation). AVAudioConverter caches are not thread-safe on their own.
    private nonisolated(unsafe) var converter: AVAudioConverter?

    nonisolated func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        // The converter's input format is fixed at creation (readonly per
        // AVAudioConverter.h) — a device switch mid-session changes the
        // tap's format, so the input side must join the cache key or every
        // buffer after the switch throws and is silently dropped (audit F1).
        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw ConversionError.failedToCreateBuffer }

        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &conversionError) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error else { throw ConversionError.conversionFailed }
        return output
    }
}
