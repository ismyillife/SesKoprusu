import ReplayKit

/// Sistem genelindeki yayını alır; yalnızca uygulama sesini (audioApp) iletir.
/// Görüntü kareleri yok sayılır.
class SampleHandler: RPBroadcastSampleHandler {
    private let streamer = AudioStreamer()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        streamer.start()
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        streamer.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        streamer.enqueue(sampleBuffer)
    }
}
