# StockLab Online

Permainan StockLab multiplayer berbasis browser. Pemain masuk dengan username tamu, membuat meja, lalu bermain bersama 2–5 orang dalam enam ronde.

## Fitur yang sudah diimplementasikan

- Masuk tanpa email/password melalui Supabase Anonymous Auth.
- Membuat meja, bergabung dengan kode undangan, melihat daftar pemain, dan status siap secara realtime.
- Host memulai permainan setelah minimal dua pemain bergabung dan semua pemain yang ada menyatakan siap.
- Setelah pertandingan selesai, pemain dapat kembali ke lobi tanpa menghapus catatan hasil game.
- Enam ronde dengan fase bidding, aksi/draft, jual, dan ekonomi.
- Bidding tertutup: bid pemain lain tidak dibuka sebelum seluruh pemain mengirim; penawaran terkunci setelah dikirim.
- Urutan bermain ditentukan oleh bid tertinggi. Jika seri, urutan sebelumnya menjadi pemecah seri.
- Pasar empat sektor dimulai pada harga 5; setiap pemain memulai dengan 15 koin.
- Lima jenis kartu aksi: Info Bursa, Rumor, Quickbuy, Trading Fee, dan Akuisisi.
- Penyimpanan kartu sebagai saham atau Reksa Dana, sesuai varian yang didokumentasikan pada panduan kompetisi.
- Info Bursa memberi intipan privat dua kartu ekonomi, +2 koin, dan giliran jual paling akhir pada ronde tersebut.
- Fase jual: tiap pemain menjual satu jenis saham atau melewati giliran.
- Fase ekonomi: buka satu kartu dari tiap tumpukan sektor; ada perubahan harga, Stock Crash, dan Stock Split.
- Kartu utang memberi 10 koin ketika saldo nol dan mengurangi 13 poin saat penghitungan akhir.
- Perhitungan skor dan pemenang setelah kartu ekonomi ronde keenam.

## Cara bermain

1. Masuk menggunakan username.
2. Buat meja dan bagikan kode, atau gabung meja teman.
3. Semua pemain menekan **Saya siap**. Host memulai saat minimal dua pemain sudah ada.
4. Pada fase Bidding, setiap pemain mengirim bid tertutup (minimal 1 koin).
5. Setelah bid dibuka, pemain mengambil kartu aksi bergiliran. Pilih simpan sebagai saham/Reksa Dana atau aktifkan efek sesuai kartu.
6. Setiap pemain mendapat satu giliran untuk menjual satu jenis saham atau melewati fase jual.
7. Host membuka kartu ekonomi. Harga bergerak sesuai efek kartu; jika belum ronde terakhir, bidding ronde berikutnya dimulai.
8. Setelah ekonomi ronde keenam, sistem menghitung uang, nilai saham, Reksa Dana, dan penalti utang.

## Catatan akurasi aturan dan kartu

Fondasi fase dan efek aksi mengacu pada Petunjuk Teknis National StockLab Competition 2025 serta booklet StockLab lain yang memuat penyimpanan Reksa Dana dan mekanik tambahan. Namun, materi publik yang ditemukan tidak menyediakan daftar muka kartu resmi lengkap yang dapat diverifikasi.

Karena itu, versi online menggunakan **deck digital komunitas/adaptasi**:
- 60 kartu aksi disusun dari 4 sektor × 5 jenis aksi × 3 salinan. Jumlah/pembagian ini adalah asumsi implementasi, bukan daftar distribusi resmi yang sudah diverifikasi.
- 36 efek ekonomi merupakan teks/efek rancangan prototipe; game mengambil 6 kartu per sektor untuk enam ronde.
- Pasangan nilai Reksa Dana pada implementasi ini adalah Konsumer + Agrikultur, mengikuti dua sektor tengah dalam susunan papan empat sektor.
- Batas waktu 5 detik dan penalti turnamen yang dapat berlaku pada penyelenggaraan tertentu belum diterapkan.
- Cocok untuk uji coba permainan digital. Jangan menganggap susunan deck atau seluruh efeknya identik dengan set turnamen resmi.

## Database dan keamanan

- Supabase project `stocklab-online`, PostgreSQL 17.
- Tabel publik: `profiles`, `rooms`, `room_members`, `games`, `game_events`, `game_private_states`, dan `bidding_submissions`.
- State umum tersimpan di `games.state`; saldo, utang, dan intipan ekonomi disimpan terpisah per pemain di `game_private_states`.
- Penawaran bidding tersimpan di `bidding_submissions`, hanya terbaca pemiliknya melalui fungsi tampilan game.
- Deck dan tumpukan ekonomi tersembunyi dari klien di `private.game_engine_secrets`.
- Semua perubahan game dilakukan melalui RPC yang memvalidasi anggota, host, fase, giliran, dan saldo di database.
- Public RPC menggunakan `SECURITY INVOKER`; implementasi privat yang memerlukan transaksi database berjalan di schema `private`.
- RLS aktif pada semua tabel di schema `public`. Browser hanya memakai project URL dan publishable key; secret/service-role key tidak disimpan di frontend.

## Reproduksi database

Untuk membuat database baru:
1. Jalankan [supabase/schema.sql](supabase/schema.sql) pada SQL Editor.
2. Setelah itu jalankan [supabase/game-engine.sql](supabase/game-engine.sql).

Perubahan saat pengembangan diterapkan langsung lewat SQL; migration history Supabase belum direkonsiliasi. Snapshot `game-engine.sql` dibuat dari definisi fungsi database yang aktif pada 20 November 2026.

## Pengujian yang sudah dilakukan

- Simulasi transaksi dua pemain hingga enam ronde: bidding, action draft, jual, ekonomi, skor akhir.
- Pengujian aksi Info Bursa, Rumor, Quickbuy, Trading Fee, dan Akuisisi.
- Pengujian penyimpanan Reksa Dana, penguncian bid, prioritas jual Info Bursa, dan kartu utang.
- Pengujian Stock Crash dan Stock Split, termasuk reset harga ke 5 dan perubahan kepemilikan.
- Simulasi meja lima pemain: lima bid, sepuluh pick kartu aksi, lima giliran jual, ekonomi, dan transisi ke ronde kedua.
- Pengujian keluar dari room selesai: semua pemain dapat kembali ke lobi sementara catatan pertandingan tetap tersimpan.
- Pengujian dilakukan dalam transaksi yang di-rollback; tidak mengubah room pemain yang sedang dipakai.
- JavaScript lolos pemeriksaan sintaks dan semua referensi elemen HTML cocok. Uji browser nyata dua perangkat dan koneksi Realtime saat bermain masih perlu dilakukan.

Pengujian simulasi bukan jaminan bebas bug. Laporkan pesan error atau kirim screenshot dari sesi dua perangkat agar masalah integrasi/browser dapat ditelusuri.

## Akses

- Repository: https://github.com/arthanesia/stocklabonline
- Website: https://arthanesia.github.io/stocklabonline/

Sesi pemain tamu melekat pada browser/perangkat. Menghapus data browser atau berpindah perangkat berarti identitas tamu yang sama tidak dapat dipulihkan.
