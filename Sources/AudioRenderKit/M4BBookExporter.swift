import AVFoundation
import AudioCore
import CoreMedia
import Foundation

public struct VerifiedM4BChapter: Codable, Equatable, Sendable {
    public let title: String
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(title: String, startSeconds: Double, durationSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case title
        case startSeconds = "start_seconds"
        case durationSeconds = "duration_seconds"
    }
}

public struct M4BVerificationReport: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let chapters: [VerifiedM4BChapter]

    public init(durationSeconds: Double, chapters: [VerifiedM4BChapter]) {
        self.durationSeconds = durationSeconds
        self.chapters = chapters
    }

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case chapters
    }
}

/// Native Apple AVFoundation audiobook exporter supporting WAV, M4A, and M4B with QuickTime `chap`
/// `tx3g` UTF-8 chapter markers (zero external tools such as ffmpeg required).
public enum BookExporter: Sendable {
    public static func export(
        samples: [Float],
        sampleRate: Int,
        format: ExportFormat,
        markers: [ChapterMarker],
        metadata: BookExportMetadata,
        to destinationURL: URL
    ) async throws {
        guard sampleRate > 0, !samples.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }
        switch format {
        case .wav:
            try PCMCodec.writeWAV(samples: samples, sampleRate: sampleRate, to: destinationURL)
        case .m4a:
            try PCMCodec.writeM4A(samples: samples, sampleRate: sampleRate, to: destinationURL)
        case .m4b:
            try await writeM4BWithChapters(
                samples: samples,
                sampleRate: sampleRate,
                markers: markers,
                metadata: metadata,
                to: destinationURL
            )
        }
    }

    /// Writes a standards-compliant Apple Books / QuickTime `.m4b` container (`.m4a` MPEG-4 audio
    /// + disabled `tx3g` text track associated to the AAC audio track as `chapterList`).
    public static func writeM4BWithChapters(
        samples: [Float],
        sampleRate: Int,
        markers: [ChapterMarker],
        metadata: BookExportMetadata,
        to destinationURL: URL
    ) async throws {
        guard sampleRate > 0, !samples.isEmpty else {
            throw AudioRenderError.emptyBookExport
        }
        let dir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // AVAssetWriter requires .m4a extension for AVFileType.m4a; move atomically to final .m4b upon completion.
        let tmpURL = dir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tmpURL, fileType: .m4a)
        } catch {
            throw AudioRenderError.m4bEncodingFailed("Cannot create AVAssetWriter: \(error.localizedDescription)")
        }

        writer.metadata = buildTopLevelMetadata(metadata)

        let targetBitRate = sampleRate <= 24_000 ? 64_000 : 128_000
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate
        ]
        let pcmSourceFormat = try makePCMFormatDescription(sampleRate: sampleRate)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings, sourceFormatHint: pcmSourceFormat)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw AudioRenderError.m4bEncodingFailed("Cannot add AAC audio input to AVAssetWriter")
        }
        writer.add(audioInput)

        let effectiveMarkers: [ChapterMarker] = markers.isEmpty
            ? [ChapterMarker(chapterID: "ch_001", title: metadata.title, startFrame: 0, endFrameExclusive: Int64(samples.count), sampleRate: sampleRate)]
            : markers

        let textFormat = try makeTX3GFormatDescription()
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapterInput.expectsMediaDataInRealTime = false
        chapterInput.marksOutputTrackAsEnabled = false
        chapterInput.languageCode = "zho"
        chapterInput.extendedLanguageTag = metadata.languageTag
        guard writer.canAdd(chapterInput) else {
            throw AudioRenderError.m4bEncodingFailed("Cannot add tx3g chapter track to AVAssetWriter")
        }
        writer.add(chapterInput)

        guard audioInput.canAddTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue) else {
            throw AudioRenderError.m4bEncodingFailed("Cannot associate tx3g track as chapterList")
        }
        audioInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)

        guard writer.startWriting() else {
            throw AudioRenderError.m4bEncodingFailed("startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // Use Apple's canonical pull-based requestMediaDataWhenReady(on:) for both tracks on one serial queue.
        // Sparse tx3g chapter tracks (with multi-minute gaps between chapter starts) must pull independently
        // from continuous audio; otherwise AVAssetWriter's interleaver stalls once audio gets ~2s ahead of the
        // last appended chapter PTS.
        let sortedMarkers = effectiveMarkers.sorted { $0.startFrame < $1.startFrame }
        let chunkFrames = 8_192

        final class WriterPumpState: @unchecked Sendable {
            let writer: AVAssetWriter
            let audioInput: AVAssetWriterInput
            let chapterInput: AVAssetWriterInput
            let samples: [Float]
            let sampleRate: Int
            let pcmSourceFormat: CMAudioFormatDescription
            let textFormat: CMFormatDescription
            let sortedMarkers: [ChapterMarker]
            let chunkFrames: Int

            var audioOffset = 0
            var markerIndex = 0
            var audioDone = false
            var chaptersDone = false
            var capturedError: Error?
            var resumed = false
            var continuation: CheckedContinuation<Void, Error>?

            init(
                writer: AVAssetWriter,
                audioInput: AVAssetWriterInput,
                chapterInput: AVAssetWriterInput,
                samples: [Float],
                sampleRate: Int,
                pcmSourceFormat: CMAudioFormatDescription,
                textFormat: CMFormatDescription,
                sortedMarkers: [ChapterMarker],
                chunkFrames: Int
            ) {
                self.writer = writer
                self.audioInput = audioInput
                self.chapterInput = chapterInput
                self.samples = samples
                self.sampleRate = sampleRate
                self.pcmSourceFormat = pcmSourceFormat
                self.textFormat = textFormat
                self.sortedMarkers = sortedMarkers
                self.chunkFrames = chunkFrames
            }

            func fail(_ error: Error) {
                if capturedError == nil {
                    capturedError = error
                }
                if !audioDone {
                    audioDone = true
                    audioInput.markAsFinished()
                }
                if !chaptersDone {
                    chaptersDone = true
                    chapterInput.markAsFinished()
                }
                finishIfComplete()
            }

            func finishIfComplete() {
                guard !resumed, audioDone, chaptersDone else { return }
                resumed = true
                let cont = continuation
                continuation = nil
                if let err = capturedError {
                    cont?.resume(throwing: err)
                } else {
                    cont?.resume(returning: ())
                }
            }
        }

        let pump = WriterPumpState(
            writer: writer,
            audioInput: audioInput,
            chapterInput: chapterInput,
            samples: samples,
            sampleRate: sampleRate,
            pcmSourceFormat: pcmSourceFormat,
            textFormat: textFormat,
            sortedMarkers: sortedMarkers,
            chunkFrames: chunkFrames
        )
        let writerQueue = DispatchQueue(label: "com.sonook.m4b.writer")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pump.continuation = cont

            chapterInput.requestMediaDataWhenReady(on: writerQueue) {
                while !pump.chaptersDone && pump.chapterInput.isReadyForMoreMediaData {
                    if pump.writer.status == .failed || pump.writer.status == .cancelled {
                        pump.fail(AudioRenderError.m4bEncodingFailed("chapter writer failed: \(pump.writer.error?.localizedDescription ?? "unknown")"))
                        return
                    }
                    guard pump.markerIndex < pump.sortedMarkers.count else {
                        pump.chaptersDone = true
                        pump.chapterInput.markAsFinished()
                        pump.finishIfComplete()
                        return
                    }
                    let marker = pump.sortedMarkers[pump.markerIndex]
                    do {
                        let sampleBuffer = try makeChapterSampleBuffer(
                            marker: marker,
                            formatDescription: pump.textFormat,
                            timescale: CMTimeScale(pump.sampleRate)
                        )
                        guard pump.chapterInput.append(sampleBuffer) else {
                            pump.fail(AudioRenderError.m4bEncodingFailed("Failed appending chapter '\(marker.title)': \(pump.writer.error?.localizedDescription ?? "unknown")"))
                            return
                        }
                        pump.markerIndex += 1
                    } catch {
                        pump.fail(error)
                        return
                    }
                }
            }

            audioInput.requestMediaDataWhenReady(on: writerQueue) {
                while !pump.audioDone && pump.audioInput.isReadyForMoreMediaData {
                    if pump.writer.status == .failed || pump.writer.status == .cancelled {
                        pump.fail(AudioRenderError.m4bEncodingFailed("audio writer failed: \(pump.writer.error?.localizedDescription ?? "unknown")"))
                        return
                    }
                    guard pump.audioOffset < pump.samples.count else {
                        pump.audioDone = true
                        pump.audioInput.markAsFinished()
                        pump.finishIfComplete()
                        return
                    }
                    let count = min(pump.chunkFrames, pump.samples.count - pump.audioOffset)
                    do {
                        let sampleBuffer = try makePCMSampleBuffer(
                            samples: pump.samples,
                            offset: pump.audioOffset,
                            count: count,
                            formatDescription: pump.pcmSourceFormat,
                            sampleRate: pump.sampleRate
                        )
                        guard pump.audioInput.append(sampleBuffer) else {
                            pump.fail(AudioRenderError.m4bEncodingFailed("Failed appending PCM chunk at frame \(pump.audioOffset): \(pump.writer.error?.localizedDescription ?? "unknown")"))
                            return
                        }
                        pump.audioOffset += count
                    } catch {
                        pump.fail(error)
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioRenderError.m4bEncodingFailed("finishWriting status=\(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")")
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destinationURL)
    }

    private static func buildTopLevelMetadata(_ metadata: BookExportMetadata) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func makeItem(key: AVMetadataKey, value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as (NSCopying & NSObjectProtocol)
            item.value = value as (NSCopying & NSObjectProtocol)
            item.extendedLanguageTag = metadata.languageTag
            return item
        }

        items.append(makeItem(key: .commonKeyTitle, value: metadata.title))
        if let author = metadata.author, !author.isEmpty {
            items.append(makeItem(key: .commonKeyAuthor, value: author))
            items.append(makeItem(key: .commonKeyArtist, value: author))
        } else if let narrator = metadata.narrator, !narrator.isEmpty {
            items.append(makeItem(key: .commonKeyArtist, value: narrator))
        }
        items.append(makeItem(key: .commonKeyCreator, value: "Sonook"))
        return items
    }

    private static func makePCMFormatDescription(sampleRate: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw AudioRenderError.m4bEncodingFailed("CMAudioFormatDescriptionCreate failed: \(status)")
        }
        return desc
    }

    private static func makePCMSampleBuffer(
        samples: [Float],
        offset: Int,
        count: Int,
        formatDescription: CMAudioFormatDescription,
        sampleRate: Int
    ) throws -> CMSampleBuffer {
        let byteLength = count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw AudioRenderError.m4bEncodingFailed("CMBlockBufferCreate failed: \(createStatus)")
        }

        let copyStatus: OSStatus = samples.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            let ptr = base.advanced(by: offset * MemoryLayout<Float>.size)
            return CMBlockBufferReplaceDataBytes(
                with: ptr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw AudioRenderError.m4bEncodingFailed("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(offset), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw AudioRenderError.m4bEncodingFailed("CMSampleBufferCreate (PCM) failed: \(sbStatus)")
        }
        return sb
    }

    /// Creates a standard 3GPP Timed Text (`tx3g`) format description matching QuickTime/Apple Books M4B chapters.
    private static func makeTX3GFormatDescription() throws -> CMTextFormatDescription {
        // Full ISO BMFF / 3GPP TS 26.245 tx3g SampleEntry box:
        //   [size:4]['tx3g':4][reserved:6][dataRefIndex:2] (16 bytes)
        // + [displayFlags:4][hJust:1][vJust:1][bgRGBA:4][defaultTextBox:8][style:12] (30 bytes)
        // + [ftab box: 4+4+2+2+1+9 = 22 bytes] = 68 bytes total.
        let fontName = Array("Helvetica".utf8)
        let ftabSize = UInt32(4 + 4 + 2 + 2 + 1 + fontName.count)
        let totalSize = UInt32(16 + 30) + ftabSize

        var payload = Data()
        payload.reserveCapacity(Int(totalSize))
        func appendBE32(_ v: UInt32) {
            var be = v.bigEndian
            payload.append(Data(bytes: &be, count: 4))
        }
        func appendBE16(_ v: UInt16) {
            var be = v.bigEndian
            payload.append(Data(bytes: &be, count: 2))
        }

        // SampleEntry header (16 bytes)
        appendBE32(totalSize)
        payload.append(contentsOf: Array("tx3g".utf8))
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0])
        appendBE16(1) // data_reference_index

        // tx3g fields (30 bytes)
        appendBE32(0) // displayFlags
        payload.append(contentsOf: [0x01, 0xFF]) // hJust = center, vJust = bottom
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0xFF]) // bgColor RGBA
        appendBE16(0); appendBE16(0); appendBE16(0); appendBE16(0) // defaultTextBox
        appendBE16(0); appendBE16(0) // style startChar, endChar
        appendBE16(1) // fontID = 1
        payload.append(contentsOf: [0x00, 0x12]) // faceStyleFlags, fontSize (18)
        payload.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // textColor RGBA

        // ftab box
        appendBE32(ftabSize)
        payload.append(contentsOf: Array("ftab".utf8))
        appendBE16(1) // entryCount
        appendBE16(1) // fontID = 1
        payload.append(UInt8(fontName.count))
        payload.append(contentsOf: fontName)

        var desc: CMTextFormatDescription?
        let status = payload.withUnsafeBytes { buf in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: buf.baseAddress!,
                size: payload.count,
                flavor: nil,
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &desc
            )
        }
        guard status == noErr, let formatDesc = desc else {
            throw AudioRenderError.m4bEncodingFailed("CMTextFormatDescriptionCreate failed: \(status)")
        }
        return formatDesc
    }

    private static func makeChapterSampleBuffer(
        marker: ChapterMarker,
        formatDescription: CMTextFormatDescription,
        timescale: CMTimeScale
    ) throws -> CMSampleBuffer {
        let titleUTF8 = Data(marker.title.utf8)
        guard titleUTF8.count <= Int(UInt16.max) else {
            throw AudioRenderError.chapterMarkerError("Chapter title exceeds 65535 UTF-8 bytes")
        }
        // 2-byte big-endian text length + UTF-8 title + 12-byte 'encd' modifier box specifying UTF-8 (0x00000100)
        var sampleData = Data()
        var lenBE = UInt16(titleUTF8.count).bigEndian
        sampleData.append(Data(bytes: &lenBE, count: 2))
        sampleData.append(titleUTF8)
        var encdSize = UInt32(12).bigEndian
        sampleData.append(Data(bytes: &encdSize, count: 4))
        sampleData.append(contentsOf: Array("encd".utf8))
        var utf8Code = UInt32(0x00000100).bigEndian
        sampleData.append(Data(bytes: &utf8Code, count: 4))

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw AudioRenderError.m4bEncodingFailed("CMBlockBufferCreate (tx3g) failed: \(createStatus)")
        }
        let copyStatus = sampleData.withUnsafeBytes { buf in
            CMBlockBufferReplaceDataBytes(with: buf.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sampleData.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw AudioRenderError.m4bEncodingFailed("CMBlockBufferReplaceDataBytes (tx3g) failed: \(copyStatus)")
        }

        let startTicks: Int64
        let durationTicks: Int64
        if marker.sampleRate == Int(timescale) {
            startTicks = marker.startFrame
            durationTicks = max(1, marker.endFrameExclusive - marker.startFrame)
        } else {
            startTicks = Int64((marker.startSeconds * Double(timescale)).rounded())
            durationTicks = max(1, Int64((marker.durationSeconds * Double(timescale)).rounded()))
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: durationTicks, timescale: timescale),
            presentationTimeStamp: CMTime(value: startTicks, timescale: timescale),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw AudioRenderError.m4bEncodingFailed("CMSampleBufferCreate (tx3g) failed: \(sbStatus)")
        }
        return sb
    }
}

extension BookExporter {
    @discardableResult
    public static func export(_ render: SoundscapeRender, format: ExportFormat, metadata: BookExportMetadata,
                              to destinationURL: URL) async throws -> M4BVerificationReport? {
        try await export(samples: render.samples, sampleRate: render.timeline.sampleRate, format: format,
                         markers: render.timeline.chapters, metadata: metadata, to: destinationURL)
        return format == .m4b ? try await M4BChapterReader.inspect(url: destinationURL) : nil
    }
}

/// Reads back embedded chapter markers from an `.m4b` file via `AVURLAsset` to verify Apple Books compatibility.
public enum M4BChapterReader: Sendable {
    public static func inspect(url: URL) async throws -> M4BVerificationReport {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["zh-Hans", "zh", "en"])
        var chapters: [VerifiedM4BChapter] = []
        for group in groups {
            var title = ""
            for item in group.items {
                if let str = try await item.load(.stringValue), !str.isEmpty {
                    title = str
                    break
                }
            }
            chapters.append(VerifiedM4BChapter(
                title: title,
                startSeconds: CMTimeGetSeconds(group.timeRange.start),
                durationSeconds: CMTimeGetSeconds(group.timeRange.duration)
            ))
        }
        return M4BVerificationReport(
            durationSeconds: CMTimeGetSeconds(duration),
            chapters: chapters
        )
    }
}
