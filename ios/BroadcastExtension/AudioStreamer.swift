import AudioToolbox
import CoreMedia
import Foundation
import Network

/// Android alıcıyı bulur (Bonjour ya da elle IP), TCP ile bağlanır ve ses paketlerini gönderir.
/// Ağ yavaşsa gecikme birikmesin diye paketleri atar.
final class AudioStreamer {
    private let queue = DispatchQueue(label: "seskoprusu.net")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var isReady = false
    private var running = false
    private var reconnectScheduled = false
    private var pendingBytes = 0
    /// ~370 ms (44,1 kHz stereo). Bundan fazlası birikirse yeni paketler atılır.
    private let maxPendingBytes = 64 * 1024

    func start() {
        queue.async {
            self.running = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.teardown()
        }
    }

    /// ReplayKit iş parçacığında çağrılır: dönüştürme hemen yapılır, gönderim ağ kuyruğunda.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let packet = AudioPacketizer.makePacket(from: sampleBuffer) else { return }
        queue.async { self.send(packet) }
    }

    // MARK: - Bağlantı

    private func connect() {
        guard running else { return }
        teardown()
        let manual = Config.sharedDefaults?
            .string(forKey: Config.manualHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !manual.isEmpty, let port = NWEndpoint.Port(rawValue: Config.port) {
            open(.hostPort(host: NWEndpoint.Host(manual), port: port))
        } else {
            browse()
        }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: Config.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            self.browser?.cancel()
            self.browser = nil
            self.open(first.endpoint)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.scheduleReconnect() }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func open(_ endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVoice

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.pendingBytes = 0
            case .failed, .waiting:
                self.scheduleReconnect()
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        teardown()
        guard running, !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + 1) {
            self.reconnectScheduled = false
            self.connect()
        }
    }

    private func teardown() {
        browser?.cancel()
        browser = nil
        let old = connection
        connection = nil
        isReady = false
        pendingBytes = 0
        old?.cancel()
    }

    // MARK: - Gönderim

    private func send(_ data: Data) {
        guard isReady, let conn = connection else { return }
        if pendingBytes > maxPendingBytes { return } // gecikme birikmesin: at
        pendingBytes += data.count
        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn, conn === self.connection else { return }
            self.pendingBytes -= data.count
            if error != nil { self.scheduleReconnect() }
        })
    }
}

/// CMSampleBuffer → [16 bayt başlık][16-bit LE interleaved PCM]
/// ReplayKit'in audioApp tamponları genellikle 44,1 kHz, big-endian Int16'dır;
/// burada biçim her pakette okunup dönüştürülür.
enum AudioPacketizer {
    static let magic: UInt32 = 0x534B_5031 // "SKP1"

    static func makePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let inChannels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        guard frames > 0, inChannels > 0, bits == 16 || bits == 32 else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let outChannels = min(inChannels, 2)
        let bytesPerSample = bits / 8

        // AudioBufferList boyutunu öğren, sonra doldur.
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, listSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPtr, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)

        // Her kanalın hangi tampon/adım/kaydırma ile okunacağı
        let stride = nonInterleaved ? 1 : inChannels
        var frameCount = frames
        for ch in 0..<outChannels {
            let index = nonInterleaved ? ch : 0
            guard index < buffers.count, buffers[index].mData != nil else { return nil }
            frameCount = min(frameCount, Int(buffers[index].mDataByteSize) / (bytesPerSample * stride))
        }
        guard frameCount > 0 else { return nil }

        var pcm = [Int16](repeating: 0, count: frameCount * outChannels)
        for ch in 0..<outChannels {
            let index = nonInterleaved ? ch : 0
            let offset = nonInterleaved ? 0 : ch
            let base = buffers[index].mData!

            switch (isFloat, bits) {
            case (false, 16):
                let p = base.assumingMemoryBound(to: Int16.self)
                for i in 0..<frameCount {
                    let v = p[i * stride + offset]
                    pcm[i * outChannels + ch] = isBigEndian ? Int16(bigEndian: v) : Int16(littleEndian: v)
                }
            case (true, 32):
                let p = base.assumingMemoryBound(to: UInt32.self)
                for i in 0..<frameCount {
                    let u = p[i * stride + offset]
                    let f = Float(bitPattern: isBigEndian ? UInt32(bigEndian: u) : UInt32(littleEndian: u))
                    pcm[i * outChannels + ch] = Int16(max(-1, min(1, f)) * 32767)
                }
            case (false, 32):
                let p = base.assumingMemoryBound(to: Int32.self)
                for i in 0..<frameCount {
                    let v = p[i * stride + offset]
                    let h = isBigEndian ? Int32(bigEndian: v) : Int32(littleEndian: v)
                    pcm[i * outChannels + ch] = Int16(truncatingIfNeeded: h >> 16)
                }
            default:
                return nil
            }
        }

        let payloadBytes = pcm.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 16 + payloadBytes)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        put(magic)
        put(UInt32(asbd.mSampleRate))
        put(UInt16(outChannels))
        put(UInt16(16))
        put(UInt32(payloadBytes))
        // iOS little-endian olduğu için Int16 dizisi doğrudan LE bayt olarak eklenir.
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
