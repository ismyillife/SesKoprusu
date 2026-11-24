import Network
import ReplayKit
import SwiftUI

struct ContentView: View {
    @StateObject private var finder = ReceiverFinder()
    @State private var manualHost = Config.sharedDefaults?.string(forKey: Config.manualHostKey) ?? ""
    private let canUseManualHost = Config.sharedDefaults != nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ses Köprüsü").font(.largeTitle.bold())
                    Text("iPhone'da çalan sesi aynı ağdaki Android telefona gönderir; oradan kulaklıkla dinlersiniz.")
                        .foregroundColor(.secondary)
                }

                GroupBox(label: Label("Android alıcı", systemImage: "antenna.radiowaves.left.and.right")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if finder.receivers.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Aranıyor… Android'de uygulamayı açıp **Başlat**'a basın.")
                            }
                        } else {
                            ForEach(finder.receivers, id: \.self) { name in
                                Label(name, systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox(label: Label("Yayını başlat", systemImage: "record.circle")) {
                    HStack(spacing: 16) {
                        BroadcastPicker()
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                        Text("Düğmeye dokunun → **Ses Köprüsü**'nü seçin → **Yayını Başlat**. Durdurmak için üstteki kırmızı göstergeye dokunun.")
                            .font(.callout)
                    }
                    .padding(.top, 4)
                }

                if canUseManualHost {
                    GroupBox(label: Label("Elle adres (isteğe bağlı)", systemImage: "keyboard")) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("örn. 192.168.1.42", text: $manualHost)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: manualHost) { value in
                                    Config.sharedDefaults?.set(value, forKey: Config.manualHostKey)
                                }
                            Text("Boş bırakılırsa alıcı otomatik bulunur.")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox(label: Label("Bilmeniz gerekenler", systemImage: "info.circle")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• İki telefon aynı Wi-Fi'da ya da biri diğerinin hotspot'unda olmalı.")
                        Text("• Apple Music, Netflix gibi kopya korumalı uygulamaların sesi iOS tarafından sessize alınır.")
                        Text("• Telefon görüşmeleri yakalanamaz.")
                        Text("• Gecikme yaklaşık 0,2–0,5 sn; müzik ve podcast için uygundur.")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
            .padding()
        }
    }
}

/// Sistem yayın seçicisi; yalnızca bizim uzantımızı gösterir.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = Config.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Ağdaki Android alıcıları listeler. Ayrıca iOS "Yerel Ağ" iznini ilk açılışta
/// tetikler; yayın uzantısı bu izni ana uygulamadan devralır.
final class ReceiverFinder: ObservableObject {
    @Published var receivers: [String] = []
    private var browser: NWBrowser?

    init() { start() }

    private func start() {
        let browser = NWBrowser(for: .bonjour(type: Config.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }.sorted()
            self?.receivers = names
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
