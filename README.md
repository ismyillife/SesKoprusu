# Ses Köprüsü — iPhone sesini Android'den dinle

iPhone'da çalan sesi (YouTube, Spotify, oyunlar, tarayıcı…) Wi-Fi üzerinden Android
telefona gönderir; Android'e taktığınız kulaklıktan dinlersiniz.

```
iPhone                                   Android
┌─────────────────────────┐   Wi-Fi     ┌──────────────────────────┐
│ ReplayKit yayın uzantısı│  TCP 50505  │ AudioReceiverService     │
│  audioApp → PCM 16-bit  │ ──────────▶ │  AudioTrack → kulaklık   │
│  Bonjour ile alıcı bulur│             │  NSD ile kendini duyurur │
└─────────────────────────┘             └──────────────────────────┘
```

## Neden "yayın" (ekran kaydı) kullanılıyor?
iOS, bir uygulamanın diğer uygulamaların sesini yakalamasına izin vermez. Tek resmi yol
**ReplayKit Broadcast Upload Extension**'dır (Kontrol Merkezi'ndeki Ekran Kaydı'nın
altyapısı). Yayın sırasında üst köşede kırmızı gösterge görünür. Görüntü gönderilmez,
yalnızca ses gönderilir.

---

## 1) Android alıcı (Windows'ta derlenebilir)

1. [Android Studio](https://developer.android.com/studio) kurun.
2. **File → Open** → `SesKoprusu/android` klasörünü açın. Gradle senkronizasyonunu bekleyin.
3. Telefonda *Geliştirici seçenekleri → USB hata ayıklama*'yı açın, USB ile bağlayın, ▶ **Run**.
   (APK dosyası için: **Build → Build APK(s)**.)

## 2) iPhone gönderici (Mac + Xcode gerekir)

iOS uygulamaları yalnızca macOS'teki Xcode ile derlenip iPhone'a yüklenebilir.

```bash
brew install xcodegen
cd SesKoprusu/ios
# project.yml içindeki APP_BUNDLE_ID değerini kendinize özgü yapın (örn. com.adiniz.seskoprusu)
xcodegen
open SesKoprusu.xcodeproj
```

Xcode'da:
1. **SesKoprusu** ve **BroadcastExtension** hedeflerinin ikisinde de *Signing & Capabilities →
   Team* olarak Apple kimliğinizi seçin (ücretsiz Apple ID yeterli).
2. iPhone'u bağlayın, şema olarak **SesKoprusu**'yu seçip ▶ Run.
3. İlk seferde iPhone'da *Ayarlar → Genel → VPN ve Cihaz Yönetimi*'nden geliştiriciye güvenin.
4. Uygulama ilk açıldığında çıkan **Yerel Ağ** iznine *İzin Ver* deyin (zorunlu).

> Ücretsiz Apple ID ile yüklenen uygulama 7 gün sonra açılmaz olur; Xcode'dan tekrar Run
> etmeniz yeterli.

## Kullanım
1. İki telefonu aynı Wi-Fi'a bağlayın (ya da birini diğerinin hotspot'una).
2. Android'de **Ses Köprüsü → Başlat**. Kulaklığı Android'e takın.
3. iPhone'da **Ses Köprüsü**'nü açın, "Android alıcı" kutusunda telefonunuz görünmeli.
4. Kırmızı yayın düğmesine dokunun → **Ses Köprüsü** → **Yayını Başlat**.
5. iPhone'da istediğiniz uygulamayı açıp sesi çalın.

Durdurmak: iPhone'da üstteki kırmızı göstergeye dokunun ya da Android bildirimindeki **Durdur**.

## Sınırlamalar
- **Kopya korumalı (DRM) içerik** (Apple Music, Netflix, Disney+ vb.) iOS tarafından yayında
  sessize alınır. YouTube, Spotify, podcast'ler, tarayıcı ve oyunlar genelde çalışır.
- Telefon görüşmeleri ve bazı sistem sesleri yakalanmaz.
- Gecikme ≈ 0,2–0,5 sn. Video için dudak senkronu kayabilir; müzik/podcast için sorun yok.
  Android'deki **Gecikme tamponu** ile ayarlanabilir (takılma varsa 400 ms seçin).
- iPhone kendi hoparlöründen de çalmaya devam eder; sesini kısmanın yakalanan sese
  etkisi iOS sürümüne göre değişebilir, deneyin.

## Sorun giderme
- **iPhone alıcıyı bulamıyor:** Bazı modem/kurumsal ağlar mDNS'i engeller. Android'in
  hotspot'unu açıp iPhone'u ona bağlamayı deneyin. iPhone'da *Ayarlar → Gizlilik →
  Yerel Ağ → Ses Köprüsü* açık olmalı.
- **Elle IP girme:** Ücretli Apple geliştirici hesabınız varsa `project.yml`'deki
  `entitlements` bloklarının yorumunu kaldırıp `xcodegen`'i tekrar çalıştırın; uygulamada
  "Elle adres" alanı belirir (Android ekranında gösterilen IP'yi girin).
- **Ses kesik kesik:** Tamponu büyütün, telefonları modeme yaklaştırın, 5 GHz Wi-Fi tercih edin.

## Protokol (meraklısına)
Her paket: 16 baytlık big-endian başlık + PCM yük.

| Alan | Tip | Değer |
|---|---|---|
| magic | u32 | `SKP1` (0x534B5031) |
| sampleRate | u32 | örn. 44100 |
| channels | u16 | 1 veya 2 |
| bits | u16 | 16 |
| length | u32 | yük bayt sayısı |
| payload | — | 16-bit little-endian, interleaved PCM |
