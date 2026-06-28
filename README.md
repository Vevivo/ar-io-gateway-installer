bash <(wget -qO- https://raw.githubusercontent.com/Vevivo/ar-io-gateway-installer/main/install-gateway.sh)


cd /opt/ar-io-node

gateway-check	En Önemlisi! Node'unuzun sağlığını kontrol eder ve test linkini verir.

gateway-update	Node yazılımını son sürüme günceller (Verilerinizi silmez, güvenlidir).

gateway-restart	Tüm servisleri kapatıp temiz bir şekilde yeniden başlatır.

gateway-logs	Core ve Observer loglarını canlı izlemenizi sağlar.

gateway-status	Docker konteynerlerinin CPU ve RAM kullanımını gösterir.

gateway-renew-cert	90 günde bir süresi dolan SSL sertifikasını yeniler.

Hızli Tani Akisi
Servisler ayakta mi?
docker compose ps
Gateway cevap veriyor mu?
curl -s https://<DOMAIN>/ar-io/info | jq .
Observer state var mi?
docker compose exec -T observer node -e 'const fs=require("fs"); const p="/app/data/observer/observation-state.json"; console.log(fs.existsSync(p) ? "state var" : "state yok")'
Pending dusuyor mu?
docker compose exec -T observer node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/app/data/observer/observation-state.json","utf8")); console.log("pending",s.pendingObservations?.length??0,"submitted",s.reportSubmitted)'
Rapor submit logu var mi?
docker compose logs observer --since 6h \
  | grep -Ei 'Report saved|save_observations|Report submitted|reportTxId|interactionTxIds' \
  | tail -80
Kritik hata var mi?
docker compose logs observer --since 2h \
  | grep -Ei 'error|failed|Invalid|not configured|Set exactly one' \
  | grep -Eiv 'finalize_gone|LeaveWindow|6079|0x17bf|Cleanup cycle' \
  | tail -120
Core saglikli mi?
docker compose logs core --since 20m \
  | grep -Ei 'Block imported|Peer classification complete|SQLITE_BUSY|database is locked|out of memory|healthcheck failed' \
  | tail -100
Kisa Yorum Rehberi
core healthy, observer healthy: servisler ayakta.
pending dusuyor: observer gatewayleri test ediyor.
pending=0, submitted=true: rapor gonderildi.
pending=0, submitted=false: submit/upload/sign tarafina bak.
Report saved using TurboReportSink: upload tamam.
save_observations submitted: Solana submit tamam veya denenmis.
Report submitted: hedef durum.
IP limit exceeded: public istekler sinirlaniyor, tek basina sorun degil.
Failed to fetch chunk: peer/content erisiminde gecici veya upstream sorun olabilir.
Set exactly one...: env'de key yontemi karisik, duzelt.
