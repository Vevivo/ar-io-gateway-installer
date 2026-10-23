# Vevivo AR.IO Gateway Kurucusu — R85

Kurulumu tek komutla başlatın; alan adı ve cüzdan bilgileri ekranda sorulur. Kurucu Docker, Nginx ve HTTPS ile resmi R85 sürümünü hazırlar; **observer etkin olarak kurulur**. Ağa kayıt ve stake işlemini sonrasında siz tamamlarsınız; kurulumun bitmesi ödül kazanıldığı anlamına gelmez.

## Başlamadan önce

- Yeni kurulum için bu işe ayrılmış **Ubuntu 22.04 veya 24.04** sunucu ve root erişimi hazırlayın. Kapasite seçimi için [resmi sistem gereksinimlerine](https://docs.ar.io/build/run-a-gateway/quick-start#system-requirements) bakın.
- Kök alan adınızı ve `*.alanadiniz.com` wildcard kaydını sunucunun IP adresine yönlendirin. DNS paneline erişiminiz açık olsun; sertifika alınırken TXT kaydı ekleyeceksiniz.
- Solana operatör ve observer cüzdanlarınızın açık adreslerini ve bunlarla eşleşen anahtar dosyalarını hazırlayın. Observer adresi başka bir gateway tarafından kullanılmamalıdır; operatörle aynı cüzdanı kullanmak desteklenir. [Resmi cüzdan açıklaması](https://docs.ar.io/build/run-a-gateway/join-the-network/)
- Solana mainnet RPC adresinizi hazır bulundurun. Üretimde istek sınırlarına takılmayan bir RPC sağlayıcısı kullanın. [Resmi RPC ayarları](https://docs.ar.io/build/run-a-gateway/manage/environment-variables)

**Özel anahtarı veya kurtarma kelimelerini sohbete, GitHub'a ya da destek mesajına göndermeyin.** Anahtar dosyalarını kendi yönettiğiniz sunucuya güvenli biçimde aktarın; kurucunun yerel anahtar adımını kullanın.

## Kurulum

Sunucuya **root** olarak bağlanın ve çalıştırın:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Vevivo/ar-io-gateway-installer/main/install-gateway.sh)
```

Yeni sunucuda alan adı, cüzdanlar ve RPC sorularını yanıtlayın. Certbot beklediğinde DNS panelinize ekranda verilen `_acme-challenge` TXT kayıtlarını ekleyin; kayıtlar yayımlandıktan sonra devam edin. Anahtar doğrulaması tamamlanmadan servisleri başlatmayın.

Bu kurucuyla daha önce kurulmuş bir gateway'de aynı komut mevcut `.env` dosyasını algılar ve **R85 yükseltme akışını** kullanır. Mevcut cüzdan ve ayarları korur; yeni kurulum sorularını tekrar sormaz. İşlem servisleri yeniden oluşturacağından kısa kesinti için uygun bir zaman seçin ve önceden yedek alın.

Kurulum veya yükseltme bitince:

```bash
gateway-check
```

HTTPS, örnek dosya ve servis sonuçlarını kontrol edin. Hata varsa aşağıdaki tanılama bölümünü açın.

## Ödül katılımını tamamlayın

1. **Cüzdanları hazırlayın.** Operatör cüzdanında kayıt için gerekli ARIO stake ve işlem ücreti için SOL; observer cüzdanında gözlem gönderimleri için SOL bulundurun. Güncel stake miktarını [resmi katılım rehberinden](https://docs.ar.io/build/run-a-gateway/join-the-network/) ve kayıt ekranından kontrol edin. [Observer'ın SOL ihtiyacı](https://docs.ar.io/build/run-a-gateway/manage/solana-migration/#fund-your-wallets-with-sol)
2. **Rapor yükleme bakiyesini hazırlayın.** Yeni kurulum Turbo kullanır; raporları observer cüzdanıyla yükler. Gerektiğinde [AR.IO Console üzerinden](https://console.ar.io/topup) bu cüzdanın **Solana adresine** Turbo Credits ekleyin. SOL işlem bakiyesi ile Turbo Credits farklıdır. Ücretsiz yükleme sınırlarına güvenerek sürekli işletim planlamayın. [Turbo ödeme rehberi](https://docs.ar.io/build/upload/turbo-credits)
3. **Ağa kaydolun.** [Gateway portalında](https://gateways.ar.io) kurulumdaki operatör cüzdanıyla bağlanın. Alan adınızı, HTTPS/443 bilgisini ve kurulumdaki observer adresini girin; stake ve diğer kayıt alanlarını kontrol edip işlemi onaylayın. Ardından portalda kaydın ve performans sonuçlarının oluştuğunu doğrulayın. [Resmi kayıt adımları](https://docs.ar.io/build/run-a-gateway/join-the-network/)

Gateway'i ve observer'ı çalışır, sertifikayı geçerli, bakiyeleri yeterli tutun. Ödüller ağ kurallarına ve hizmet performansına bağlıdır; bu kurucu gelir veya ödül garantisi vermez. [Gözlem ve ödül protokolü](https://docs.ar.io/learn/oip)

<details>
<summary>Bakım, R85 sürüm sabitlemesi ve sertifika yenileme</summary>

| Komut | Ne yapar? |
| --- | --- |
| `gateway-check` | Dış erişimi, örnek dosyayı ve servisleri kontrol eder. |
| `gateway-status` | Servis, kaynak ve disk durumunu gösterir. |
| `gateway-balance` | Observer'ın SOL bakiyesini gösterir. |
| `gateway-logs` | Core, observer ve Envoy günlüklerini izler. |
| `gateway-observer-check` | Observer ayarları ve rapor durumunu inceler. |
| `gateway-update` | Sabitlenmiş R85 sürümünü uygular ve servisleri yeniden oluşturur. |
| `gateway-restart` | Servisleri yeniden oluşturur; kısa kesinti olabilir. |
| `gateway-renew-cert` | Yeni DNS TXT doğrulamasıyla sertifikayı yeniler. |
| `gateway-help` | Yardımcı komutları listeler. |

Bu kurucu [resmi `r85` sürümüne](https://github.com/ar-io/ar-io-node/releases/tag/r85), `6c7006d530355c8f07240e28bebac5c9f6c71b7d` commit'ine sabitlenmiştir. `gateway-update` kendiliğinden daha yeni bir sürüme geçmez. Gelecekteki bir sürüme geçiş, sürüm notları incelendikten sonra bilinçli olarak yapılmalıdır.

Wildcard sertifika **manuel DNS doğrulaması** kullanır. Otomatik yenilendiğini varsaymayın: süresi dolmadan `gateway-renew-cert` çalıştırın ve yeni TXT kayıtlarını ekleyin. DNS paneline erişimi ve yenileme takibini koruyun.

</details>

<details>
<summary>Mevcut kurulumdan R85'e geçerken</summary>

Yeni kurulum Nginx başlık tamponlarını ayarlar, yükseltme ise mevcut Nginx dosyanızı korur; eksikse aşağıdaki satırları HTTPS `server` bloğuna ekleyip yapılandırmayı test ederek yeniden yükleyin:

```nginx
proxy_buffer_size 32k;
proxy_buffers 8 32k;
proxy_busy_buffers_size 64k;
```

```bash
nginx -t && systemctl reload nginx
```

Özel Arweave/Ethereum rapor yükleme ayarları korunur; otomatik yükseltme bu durumda servisleri başlatmadan durur ve ayarları elle doğrulamanızı ister.

Yerel Git değişikliği veya R85'ten daha yeni bir sürüm saptanırsa yükseltme durur; mevcut kodu sıfırlamaz.

R85'in yerleşik Index Sharing varsayılanları korunur; kurucu özel yayın veya abonelik ayarı eklemez, disk ve ağ kullanımı için [resmi Index Sharing açıklamasını](https://docs.ar.io/build/run-a-gateway/manage/index-sharing/) inceleyin.

</details>

<details>
<summary>Bir sorun varsa: kısa tanılama</summary>

Önce şu komutları çalıştırın:

```bash
gateway-check
gateway-status
gateway-observer-check
```

- DNS veya sertifika hatasında kök/wildcard kayıtlarını ve sertifika süresini kontrol edin.
- Observer raporu yoksa önce portal kaydını, observer adresini, SOL ve Turbo bakiyelerini inceleyin. Yeni kurulumda henüz rapor oluşmamış olması tek başına başarısızlık değildir.
- `TurboReportSink` yapılandırma hatasında rapor yükleme anahtarının observer ile eşleştiğini kontrol edin. Yeni kurulum bunu açıkça ayarlar; yükseltme mevcut rapor ödeme yöntemini ve cüzdan tercihlerini korur.
- Sağlıklı container sonucu, ağ kaydı veya ödül uygunluğu kanıtı değildir. Portal sonuçlarını da kontrol edin.

Ayrıntılı log için `gateway-logs` kullanın; çıkmak için `Ctrl+C`. Destek isterken `.env`, anahtar dosyası veya RPC erişim anahtarı paylaşmayın. [Resmi sorun giderme rehberi](https://docs.ar.io/build/run-a-gateway/manage/troubleshooting)

</details>
