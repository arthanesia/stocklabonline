# StockLab Online

Permainan StockLab multiplayer berbasis browser. Pemain masuk dengan username tamu, membuat meja, lalu bermain bersama 2–5 orang.

## Yang tersedia

- Masuk sebagai pemain tamu tanpa formulir email/password.
- Buat meja 2–5 pemain, bagikan kode undangan, atau gabung ke meja teman.
- Lobby realtime, daftar pemain, status siap, dan kontrol mulai khusus host.
- Enam ronde permainan: Bidding, Aksi/Draft, Jual, dan Ekonomi.
- Bidding tertutup: pemain hanya melihat status bid miliknya sampai seluruh pemain mengirim.
- Kartu aksi: Info Bursa, Rumor, Quickbuy, Trading Fee, dan Akuisisi.
- Kartu aksi dapat disimpan sebagai saham atau unit Reksa Dana sesuai keluarga kartu yang diambil.
- Fase jual mendukung saham sektor maupun Reksa Dana.
- Fase ekonomi membuka satu kartu dari setiap sektor, menjalankan perubahan harga serta efek khusus.
- Stock Crash, Stock Split, token split, kartu utang, nilai Reksa Dana, dan penghitungan skor akhir.
- Hasil pertandingan disimpan; pemain dapat kembali ke lobi setelah permainan selesai.

## Cara bermain

1. Masuk dengan username, lalu buat meja atau gabung memakai kode.
2. Semua pemain yang hadir menekan **Saya siap**. Host dapat memulai setelah sedikitnya dua pemain siap.
3. Setiap ronde dimulai dengan bidding tertutup. Masukkan tawaran minimal 1 koin dan tidak melebihi saldo. Bid yang sudah dikirim tidak dapat diubah.
4. Setelah semua bid masuk, biaya bid dibayar dan urutan pemain ditentukan dari bid tertinggi. Jika seri, urutan sebelumnya menjadi pemecah seri.
5. Pemain bergiliran memilih kartu dari pasar aksi. Pilih **Simpan** untuk menambah saham/Reksa Dana, atau **Aktifkan** untuk menjalankan efek kartu.
6. Setelah semua kartu aksi habis, tiap pemain mendapat satu giliran menjual satu jenis saham/Reksa Dana atau melewati giliran. Pemakai Info Bursa ditempatkan paling akhir di fase jual.
7. Host membuka satu kartu ekonomi dari masing-masing tumpukan sektor. Efek kartu diterapkan dan ronde berikutnya dimulai.
8. Setelah ekonomi ronde keenam, sistem menghitung koin, nilai saham, Reksa Dana, penalti utang, dan pemenang. Jika skor seri, urutan bermain yang lebih tinggi menjadi pemecah seri.

## Aksi dan mekanik khusus

- **Info Bursa:** pilih tiga sektor untuk mengintip kartu ekonomi teratasnya secara privat, lalu dapatkan 2 koin. Pemakainya menjual setelah pemain lain.
- **Rumor:** gerakkan satu sektor sebesar ±2 atau dua sektor masing-masing ±1 tanpa memicu Crash/Split.
- **Quickbuy:** pilih dua kartu aksi lain yang masih tersedia; kedua kartu tersebut disimpan sebagai kepemilikan sesuai keluarga sektornya.
- **Trading Fee:** bayar 1 koin per unit dari keluarga sektor kartu, lalu jual satu jenis saham/Reksa Dana pilihan.
- **Akuisisi:** ambil satu saham sektor dari pemain lain jika kepemilikanmu pada sektor yang sama minimal sebesar kepemilikan target. Kartu Akuisisi keluarga Reksa Dana tetap harus memilih sektor saham biasa; Reksa Dana tidak dapat diakuisisi.
- **Kartu utang:** sebelum permainan selesai, balik satu saham sektor biasa milikmu untuk menerima 10 koin. Setiap pemain hanya dapat memakai satu kartu utang; penalti akhir 13 poin.
- **Reksa Dana:** harga unit dihitung dari rata-rata dibulatkan ke bawah dua sektor yang dipasangkan pada konfigurasi pertandingan ini, yaitu Konsumer dan Agrikultur.

## Catatan akurasi komponen

Implementasi ini mengikuti alur dan mekanik yang tersedia pada panduan StockLab yang diunggah untuk proyek, tetapi susunan kartu digital bukan klaim reproduksi set fisik resmi.

- Deck aksi digital berjumlah 60 kartu: 40 kartu keluarga saham sektor dan 20 kartu keluarga Reksa Dana.
- Tumpukan ekonomi dibuat dari 24 kartu pergerakan sektor dan 6 kartu khusus yang dipilih dari kumpulan 12 efek khusus. Total 24 kartu dipakai per permainan (enam per sektor); enam kartu sisanya tidak dipakai pada permainan itu.
- Teks, jumlah salinan, distribusi, dan beberapa efek ekonomi adalah adaptasi digital untuk prototipe. Konfirmasi varian dengan set fisik/panitia apabila digunakan untuk kompetisi resmi.

## Database dan keamanan

- Supabase project `stocklab-online`, PostgreSQL 17.
- Tabel publik: `profiles`, `rooms`, `room_members`, `games`, `game_events`, `game_private_states`, dan `bidding_submissions`.
- State papan bersama disimpan di `games.state`; saldo, utang, dan intipan ekonomi disimpan per pemain di `game_private_states`.
- Bidding tersimpan di `bidding_submissions` dan tidak dibuka ke pemain lain sebelum seluruh bid masuk.
- Deck aksi dan tumpukan ekonomi disimpan di `private.game_engine_secrets`, tidak dapat dibaca klien browser.
- Mutasi permainan dijalankan melalui RPC yang memvalidasi keanggotaan, host, fase, giliran, saldo, dan pilihan kartu di database.
- Public RPC memakai `SECURITY INVOKER`; implementasi privat yang memerlukan transaksi berjalan melalui fungsi terbatas di schema `private`.
- RLS aktif pada seluruh tabel schema `public`. Browser hanya memakai URL project dan publishable key; secret/service-role key tidak ada di frontend.

## Instalasi database

Pada project Supabase baru, jalankan file berikut secara berurutan di SQL Editor:

1. [supabase/schema.sql](supabase/schema.sql)
2. [supabase/game-engine.sql](supabase/game-engine.sql)

File kedua membuat penyimpanan deck privat dan mengganti fungsi awal menjadi engine permainan lengkap. Pada project pengembangan saat ini, SQL diterapkan langsung; riwayat migration Supabase belum direkonsiliasi.

## Pengujian

Pengujian otomatis dilakukan pada transaksi database terisolasi dan room tes dihapus setelah hasil didapat.

- Simulasi dua pemain menyelesaikan enam ronde, dari bidding sampai skor akhir.
- Simulasi lima pemain menyelesaikan enam ronde, dengan 10 pilihan kartu aksi dan 5 giliran jual pada setiap ronde.
- Uji Info Bursa, intipan tiga sektor, +2 koin, dan urutan jual paling akhir.
- Uji Rumor, Quickbuy dua kartu, Trading Fee, Akuisisi, penyimpanan Reksa Dana, dan penjualan Reksa Dana.
- Uji kartu utang: satu saham dibalik, +10 koin, dan penalti akhir 13.
- Uji pengosongan intipan privat setelah kartu ekonomi dibuka.
- JavaScript lolos pemeriksaan sintaks dan semua referensi elemen HTML cocok.

Pengujian transaksi ini membuktikan alur backend dan simulasi permainan; bukan jaminan bebas bug. Uji langsung pada beberapa browser/perangkat serta koneksi Realtime selama pemain nyata masih diperlukan.

## Akses

- Repository: https://github.com/arthanesia/stocklabonline
- Website: https://arthanesia.github.io/stocklabonline/

Sesi tamu melekat pada browser/perangkat. Menghapus data browser atau berpindah perangkat berarti identitas tamu yang sama tidak dapat dipulihkan.
