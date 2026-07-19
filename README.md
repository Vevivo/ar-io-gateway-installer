bash <(wget -qO- https://raw.githubusercontent.com/Vevivo/ar-io-gateway-installer/main/install-gateway.sh)


cd /opt/ar-io-node

gateway-check	En Önemlisi! Node'unuzun sağlığını kontrol eder ve test linkini verir.

gateway-update	Node yazılımını son sürüme günceller (Verilerinizi silmez, güvenlidir).

gateway-restart	Tüm servisleri kapatıp temiz bir şekilde yeniden başlatır.

gateway-logs	Core ve Observer loglarını canlı izlemenizi sağlar.

gateway-status	Docker konteynerlerinin CPU ve RAM kullanımını gösterir.

gateway-renew-cert	90 günde bir süresi dolan SSL sertifikasını yeniler.

# ar.io Gateway Hizli Tani Akisi

Bu dosya, gateway durumunu hizli kontrol etmek icin kopyala-yapistir komutlari icerir.

Guvenlik notu:
- Bu komutlar API key, private key veya keypair icerigi yazdirmaz.
- `<DOMAIN>` yazan yeri kendi domaininizle degistirin. Ornek: `vevivo.art`
- Komutlari sunucuda `/opt/ar-io-node` dizininde calistirin.

## Baslangic

```bash
cd /opt/ar-io-node
```

## 1. Servisler Ayakta Mi?

```bash
docker compose ps
```

Beklenen:
- `core`, `observer`, `envoy`, `redis`, `autoheal` servisleri `Up` olmali.
- `core` ve `observer` icin `healthy` gormek iyi isarettir.

## 2. Gateway Cevap Veriyor Mu?

```bash
curl -s https://<DOMAIN>/ar-io/info | jq .
```

`jq` yoksa:

```bash
curl -s https://<DOMAIN>/ar-io/info
```

Beklenen:
- `release`
- `wallet`
- `programIds`
- varsa `rateLimiter` ve `x402`

## 3. Observer State Var Mi?

```bash
docker compose exec -T observer node -e 'const fs=require("fs"); const p="/app/data/observer/observation-state.json"; console.log(fs.existsSync(p) ? "state var" : "state yok")'
```

Beklenen:
- `state var`: Observer epoch state olusturmus.
- `state yok`: Observer henuz epoch state olusturmamis veya yeni baslamis olabilir.

## 4. Pending Dusuyor Mu?

```bash
docker compose exec -T observer node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/app/data/observer/observation-state.json","utf8")); console.log("pending",s.pendingObservations?.length??0,"submitted",s.reportSubmitted)'
```

Beklenen:
- `pending` zamanla dusuyorsa observer gatewayleri test ediyor.
- `submitted true` raporun gonderildigini gosterir.

## 5. Observer State Detayli Kontrol

```bash
docker compose exec -T observer node -e 'const fs=require("fs"); const p="/app/data/observer/observation-state.json"; if(fs.existsSync(p)===false){console.log("state yok"); process.exit(0)} const s=JSON.parse(fs.readFileSync(p,"utf8")); console.log(JSON.stringify({now:new Date().toISOString(),epoch:s.epochIndex,pending:s.pendingObservations?.length??0,observed:s.gatewayObservations?Object.keys(s.gatewayObservations).length:null,submitted:s.reportSubmitted,deadline:s.submissionDeadlineExceeded,windowEnd:s.windowEnd?new Date(s.windowEnd).toISOString():null,lastCycleTimestamp:s.lastCycleTimestamp},null,2));'
```

Bu komut sunlari gosterir:
- `epoch`: mevcut epoch
- `pending`: kalan observation sayisi
- `observed`: toplanan gateway gozlem sayisi
- `submitted`: rapor gonderildi mi
- `deadline`: submission deadline gecildi mi
- `windowEnd`: observer rapor penceresi bitis zamani

## 6. Rapor Submit Logu Var Mi?

```bash
docker compose logs observer --since 6h \
  | grep -Ei 'Report saved|save_observations|Report submitted|reportTxId|interactionTxIds' \
  | tail -80
```

Beklenen:
- `Report saved using TurboReportSink`
- `save_observations submitted`
- `Report submitted`
- `reportTxId` veya `interactionTxIds`

## 7. Kritik Observer Hatasi Var Mi?

```bash
docker compose logs observer --since 2h \
  | grep -Ei 'error|failed|Invalid|not configured|Set exactly one' \
  | grep -Eiv 'finalize_gone|LeaveWindow|6079|0x17bf|Cleanup cycle' \
  | tail -120
```

Bu komut, bilinen cleanup/cranker gurultusunu filtreleyip daha anlamli hatalari gosterir.

## 8. Core Saglikli Mi?

```bash
docker compose logs core --since 20m \
  | grep -Ei 'Block imported|Peer classification complete|SQLITE_BUSY|database is locked|out of memory|healthcheck failed' \
  | tail -100
```

Beklenen:
- `Block imported`
- `Peer classification complete`

Dikkat edilecekler:
- `SQLITE_BUSY`
- `database is locked`
- `out of memory`
- `healthcheck failed`

## 9. Rate Limit En Cok Hangi IP'den Geliyor?

```bash
docker compose logs core --since 2h \
  | grep 'IP limit exceeded' \
  | sed -n 's/.*clientIp":"\([^"]*\)".*/\1/p' \
  | sort | uniq -c | sort -nr | head -20
```

Bu komut, rate limit'e en cok takilan IP adreslerini listeler.

## 10. Observer Report Endpoint

```bash
curl -s https://<DOMAIN>/ar-io/observer/reports/current | jq .
```

`jq` yoksa:

```bash
curl -s https://<DOMAIN>/ar-io/observer/reports/current
```

Beklenen:
- Rapor hazir degilse `Report pending`
- Rapor hazirsa current report bilgisi

## 11. Canli Rapor Takip Komutu

```bash
docker compose logs observer -f --tail=200 \
  | grep -Ei 'Report saved|save_observations|Report submitted|reportTxId|interactionTxIds|submitted|confirmed|error|failed|not configured|Set exactly one' \
  | grep -Eiv 'finalize_gone|LeaveWindow|6079|0x17bf|Cleanup cycle'
```

Bu komut rapor upload, imza ve Solana submit surecini canli takip etmek icindir.

## 12. Pending Hiz Kontrolu

Bu komut 10 dakika bekler ve pending dusme hizini hesaplar.

```bash
A=$(docker compose exec -T observer node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/app/data/observer/observation-state.json","utf8")); console.log(s.pendingObservations?.length??0)')
echo "START pending=$A at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

sleep 600

B=$(docker compose exec -T observer node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/app/data/observer/observation-state.json","utf8")); console.log(s.pendingObservations?.length??0)')
LEFT=$(docker compose exec -T observer node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/app/data/observer/observation-state.json","utf8")); const p=s.pendingObservations?.length??0; const left=(s.windowEnd-Date.now())/60000; console.log((p/left).toFixed(2))')
SPEED=$(awk "BEGIN { printf \"%.2f\", ($A-$B)/10 }")

echo "END pending=$B at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "speed/min=$SPEED required/min=$LEFT"
```

Yorum:
- `speed/min` degeri `required/min` degerinden buyukse yetisme ihtimali iyi.
- `speed/min` degeri `required/min` degerinden kucukse observer pencere kapanmadan bitiremeyebilir.

## Kisa Yorum Rehberi

- `core healthy`, `observer healthy`: servisler ayakta.
- `pending dusuyor`: observer gatewayleri test ediyor.
- `pending=0, submitted=true`: rapor gonderildi.
- `pending=0, submitted=false`: submit, upload veya sign tarafina bak.
- `Report saved using TurboReportSink`: rapor upload tamam.
- `save_observations submitted`: Solana submit tamam veya denenmis.
- `Report submitted`: hedef durum.
- `IP limit exceeded`: public istekler rate limit'e takiliyor; tek basina kritik sorun degildir.
- `Failed to fetch chunk`: peer/content erisiminde gecici veya upstream kaynakli sorun olabilir.
- `Set exactly one...`: `.env` icinde ayni is icin iki farkli key yontemi verilmis; birini kaldir.
- `TurboReportSink not configured`: report upload sink/key ayari eksik veya container'a gecmemis olabilir.
- `AccountNotInitialized`: ilgili Solana observation account henuz hazir degil olabilir.
- `LeaveWindowNotExpired`, `6079`, `0x17bf`: genelde cleanup/cranker not-ready gurultusudur.


Kalan süre 

cd /opt/ar-io-node

while true; do
  docker compose exec -T observer node -e 'const fs=require("fs"); const p="/app/data/observer/observation-state.json"; if(!fs.existsSync(p)){console.log(new Date().toISOString(),"state yok"); process.exit(0)} const s=JSON.parse(fs.readFileSync(p,"utf8")); const pending=s.pendingObservations?.length??0; const observed=s.gatewayObservations?Object.keys(s.gatewayObservations).length:null; const left=s.windowEnd?(s.windowEnd-Date.now())/60000:null; const req=left&&left>0?pending/left:null; console.log(JSON.stringify({now:new Date().toISOString(),epoch:s.epochIndex,pending,observed,submitted:s.reportSubmitted,deadlineExceeded:s.submissionDeadlineExceeded,minutesLeft:left===null?null:Math.round(left),requiredPerMinute:req===null?null:+req.toFixed(2),windowEnd:s.windowEnd?new Date(s.windowEnd).toISOString():null},null,2));'
  echo
  echo "60 sn sonra yenilenecek. Cikmak icin CTRL+C"
  sleep 60
done
