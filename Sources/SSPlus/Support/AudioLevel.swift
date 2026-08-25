import Accelerate
import AVFoundation

/// Bir PCM ses tamponunun tepe ve RMS düzeyi (doğrusal 0…1).
struct AudioLevelReading {
    var peak: Float
    var rms: Float
    /// Ölçülen kare (frame) sayısı; birleştirirken ağırlık olarak kullanılır.
    var frames: Int

    static let silence = AudioLevelReading(peak: 0, rms: 0, frames: 0)

    var peakDB: Float { AudioLevel.decibels(peak) }
    var rmsDB: Float { AudioLevel.decibels(rms) }
}

/// `CMSampleBuffer` ses düzeyi ölçümü — kayıt göstergesi ve `--audio-probe` tanılaması için.
/// float32 ile int16/int32 PCM'i, aralıklı (interleaved) ya da düzlemsel yerleşimi destekler.
enum AudioLevel {
    /// dBFS; sessizlikte -120.
    static func decibels(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10(linear) : -120
    }

    /// Göstergedeki 0…1 ölçeği: −60 dBFS → 0, 0 dBFS → 1.
    static func meterValue(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (decibels(peak) + 60) / 60))
    }

    /// Tamponun biçimini okunur özetler (günlük ve tanılama için).
    static func formatSummary(of sampleBuffer: CMSampleBuffer) -> String {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return "biçim yok" }
        let flags = asbd.mFormatFlags
        let kind = (flags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int"
        let layout = (flags & kAudioFormatFlagIsNonInterleaved) != 0 ? "düzlemsel" : "aralıklı"
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) kanal, \(asbd.mBitsPerChannel) bit \(kind), \(layout), \(CMSampleBufferGetNumSamples(sampleBuffer)) örnek/tampon"
    }

    /// Tamponun tepe/RMS düzeyi; ses tamponu değilse ya da biçim desteklenmiyorsa nil.
    ///
    /// Önce AudioBufferList yolu denenir; bazı kaynaklarda (ör. ScreenCaptureKit
    /// mikrofon tamponları) bu yol başarısız olabildiğinden blok tamponu düz PCM
    /// olarak tarayan bir geri dönüş vardır (tarama kanal düzeninden bağımsızdır).
    static func measure(_ sampleBuffer: CMSampleBuffer) -> AudioLevelReading? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        if let reading = measureViaBufferList(sampleBuffer, asbd: asbd) { return reading }
        return measureViaBlockBuffer(sampleBuffer, asbd: asbd)
    }

    private static func measureViaBufferList(_ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> AudioLevelReading? {
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        return withExtendedLifetime(blockBuffer) {
            var peak: Float = 0
            var sumSquares: Double = 0
            var count = 0

            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                let raw = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
                guard scan(raw, asbd: asbd, peak: &peak, sumSquares: &sumSquares, count: &count) else { return nil }
            }

            guard count > 0 else { return AudioLevelReading.silence }
            return finish(asbd: asbd, peak: peak, sumSquares: sumSquares, count: count)
        }
    }

    /// Geri dönüş: blok tamponun tamamını ASBD'ye göre düz PCM olarak tarar.
    /// Aralıklı/düzlemsel ayrımı önemsizdir; tüm örneklerin büyüklüğü ölçülür.
    private static func measureViaBlockBuffer(_ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> AudioLevelReading? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < 16 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }

        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0
        let supported = bytes.withUnsafeBytes { raw in
            scan(raw, asbd: asbd, peak: &peak, sumSquares: &sumSquares, count: &count)
        }
        guard supported, count > 0 else { return supported ? AudioLevelReading.silence : nil }
        return finish(asbd: asbd, peak: peak, sumSquares: sumSquares, count: count)
    }

    /// Ham PCM baytlarını ASBD'ye göre tarar; desteklenmeyen biçimde false döner.
    /// Desteklenen: float32/float64, int16, int32, 24-bit int (3 baytlık paket ve
    /// 32-bit kap içinde), little/big endian. Kanal düzeni önemsizdir.
    private static func scan(
        _ raw: UnsafeRawBufferPointer,
        asbd: AudioStreamBasicDescription,
        peak: inout Float,
        sumSquares: inout Double,
        count: inout Int
    ) -> Bool {
        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let bigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = (flags & kAudioFormatFlagIsNonInterleaved) == 0
        // Örnek başına kap boyu: aralıklıysa çerçeve/kanal, düzlemselse çerçeve baytı.
        let bytesPerSample = Int(asbd.mBytesPerFrame) / (interleaved ? channels : 1)

        func add(_ v: Float) {
            let a = abs(v)
            peak = max(peak, a)
            sumSquares += Double(a * a)
            count += 1
        }

        if isFloat && bits == 32 {
            guard let base = raw.baseAddress else { return false }
            let n = raw.count / MemoryLayout<Float>.size
            let samples = base.assumingMemoryBound(to: Float.self)
            var maxMagnitude: Float = 0
            var rms: Float = 0
            vDSP_maxmgv(samples, 1, &maxMagnitude, vDSP_Length(n))
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
            peak = max(peak, maxMagnitude)
            sumSquares += Double(rms * rms) * Double(n)
            count += n
            return true
        }
        if isFloat && bits == 64 {
            let samples = raw.bindMemory(to: Double.self)
            for s in samples { add(Float(s)) }
            return true
        }
        if !isFloat && bits == 16 {
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples { add(Float(bigEndian ? Int16(bigEndian: s) : s) / 32768) }
            return true
        }
        if !isFloat && bits == 32 {
            let samples = raw.bindMemory(to: Int32.self)
            for s in samples { add(Float(Double(bigEndian ? Int32(bigEndian: s) : s) / 2_147_483_648)) }
            return true
        }
        if !isFloat && bits == 24 && bytesPerSample == 3 {
            // 3 baytlık paket 24-bit (ScreenCaptureKit mikrofonu böyle verir).
            let n = raw.count / 3
            for i in 0..<n {
                let b0 = Int32(raw[3 * i]), b1 = Int32(raw[3 * i + 1]), b2 = Int32(raw[3 * i + 2])
                var v = bigEndian ? (b0 << 16) | (b1 << 8) | b2 : (b2 << 16) | (b1 << 8) | b0
                if v & 0x0080_0000 != 0 { v -= 0x0100_0000 }
                add(Float(Double(v) / 8_388_608))
            }
            return true
        }
        if !isFloat && bits == 24 && bytesPerSample == 4 {
            // 32-bit kap içinde 24-bit örnek.
            let alignedHigh = (flags & kAudioFormatFlagIsAlignedHigh) != 0
            let samples = raw.bindMemory(to: Int32.self)
            for s in samples {
                let value = bigEndian ? Int32(bigEndian: s) : s
                let v = alignedHigh ? value >> 8 : (value << 8) >> 8
                add(Float(Double(v) / 8_388_608))
            }
            return true
        }
        return false
    }

    private static func finish(asbd: AudioStreamBasicDescription, peak: Float, sumSquares: Double, count: Int) -> AudioLevelReading? {
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let rms = Float(sqrt(sumSquares / Double(count)))
        if !peak.isFinite || !rms.isFinite { return nil }
        return AudioLevelReading(peak: min(1, peak), rms: min(1, rms), frames: count / channels)
    }
}
