bash <(wget -qO- https://raw.githubusercontent.com/Vevivo/ar-io-gateway-installer/main/install-gateway.sh)


cd /opt/ar-io-gateway

gateway-check	En Önemlisi! Node'unuzun sağlığını kontrol eder ve test linkini verir.

gateway-update	Node yazılımını son sürüme günceller (Verilerinizi silmez, güvenlidir).

gateway-restart	Tüm servisleri kapatıp temiz bir şekilde yeniden başlatır.

gateway-logs	Core ve Observer loglarını canlı izlemenizi sağlar.

gateway-status	Docker konteynerlerinin CPU ve RAM kullanımını gösterir.

gateway-renew-cert	90 günde bir süresi dolan SSL sertifikasını yeniler.
