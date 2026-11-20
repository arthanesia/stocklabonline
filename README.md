# StockLab Online

Implementasi digital multiplayer StockLab berbasis browser. Pemain masuk menggunakan username tamu, membuat meja, lalu mengundang teman melalui kode.

## Yang sudah tersedia

- Guest access melalui Supabase Anonymous Auth (tanpa form email/password).
- Buat meja dengan kapasitas 2–5 pemain.
- Bergabung dengan kode undangan 6 karakter.
- Lobby realtime dengan daftar pemain dan status siap.
- Host dapat memulai permainan setelah minimal dua pemain bergabung dan seluruh pemain di meja sudah siap.
- Saat permainan dimulai, backend membuat sesi ronde pertama pada fase Bidding, papan harga awal empat sektor (5), serta modal pribadi 15 koin untuk tiap pemain.
- Tampilan utama sudah difokuskan ke ruang permainan; katalog/inventaris aset tidak ditampilkan.

## Status game engine

Tombol mulai dan pembuatan sesi game sudah diimplementasikan. Papan awal dan modal privat pemain sudah dibuat, tetapi mekanik lanjutan belum selesai: bidding tertutup dan penentuan urutan, drafting kartu aksi, aktivasi/penyimpanan kartu, fase jual, efek ekonomi, dan scoring. Jangan gunakan untuk kompetisi resmi sebelum semua mekanik dan komposisi deck diverifikasi terhadap set fisik/rulebook yang dipakai.

## Database dan keamanan

- Project Supabase `stocklab-online` aktif, Postgres 17.
- Tabel inti: `profiles`, `rooms`, `room_members`, `games`, `game_events`, `game_private_states`, dan `bidding_submissions`.
- RLS aktif pada seluruh tabel di schema `public`.
- Saldo dan portofolio awal disimpan di `game_private_states`; klien hanya dapat membaca data privat milik pemain sendiri.
- Pembuatan, join, keluar, dan mulai game melalui RPC tervalidasi.
- Browser hanya memakai Supabase project URL dan publishable key. Secret/service-role key tidak disimpan di repository.
- Realtime digunakan untuk room, membership, dan shared game state. Private state dan sealed bids tidak dipublikasikan.
- Snapshot schema: [supabase/schema.sql](supabase/schema.sql). Perubahan database tahap ini diterapkan langsung via SQL; migration history perlu direkonsiliasi sebelum rilis produksi.

## Akses

- GitHub repository: https://github.com/arthanesia/stocklabonline
- GitHub Pages: https://arthanesia.github.io/stocklabonline/

Sesi pemain tamu melekat pada browser/perangkat. Membersihkan data browser atau berpindah perangkat berarti identitas tamu yang sama tidak dapat dipulihkan.
