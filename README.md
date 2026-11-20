# StockLab Online

Implementasi digital multiplayer StockLab berbasis browser, dengan Guide Resmi StockLab sebagai sumber aturan.

## Kondisi yang sudah diverifikasi

- Frontend statis: HTML, CSS, JavaScript.
- Katalog metadata 56 aset tersedia di `assets/manifest.json`; gambar dibaca dari `stocklab-assets-upload.zip`.
- Project Supabase `stocklab-online` aktif (Postgres 17, region Singapore).
- Mode masuk yang dirancang adalah **username tamu**, tanpa formulir email/password.
- Guest identity memakai Supabase Anonymous Auth dan tersimpan sebagai sesi browser.
- Fondasi backend: `profiles`, `rooms`, `room_members`, `games`, `game_events`, `game_private_states`, dan `bidding_submissions`.
- RLS aktif pada seluruh 7 tabel di schema `public`; akses `anon` dicabut dan hak `authenticated` dibatasi sesuai kebutuhan.
- Realtime Postgres Changes hanya mencakup `rooms`, `room_members`, dan `games`; `game_events`, private state, dan sealed bids tidak dipublikasikan.
- Snapshot schema: [supabase/schema.sql](supabase/schema.sql).
- `schema.sql` memuat bootstrap dan hardening tahap 1; `draft-schema.sql` sudah deprecated.

## Guest access

Pemain memasukkan username, kemudian bisa:
- melihat daftar ruangan yang menunggu pemain;
- membuat room dengan kapasitas 2–5 pemain;
- bergabung menggunakan kode 6 karakter;
- melihat pemain di lobby dan menandai siap;
- keluar dari ruangan sebelum permainan dimulai.

Untuk mengaktifkan alur ini, **Allow anonymous sign-ins** harus diaktifkan di Supabase Dashboard: Authentication → Sign In / Providers → Anonymous. Ini bukan halaman login; Supabase membuat identitas tamu di belakang layar agar RLS dan room membership tetap bekerja.

Sesi tamu melekat pada browser/perangkat. Menghapus data browser atau berpindah perangkat membuat pemain tidak dapat memulihkan identitas tamu yang sama. Untuk penggunaan publik, aktifkan CAPTCHA/Turnstile dan pantau pembuatan akun tamu.

Konfigurasi Anonymous Sign-Ins belum dapat diverifikasi melalui konektor pada pemeriksaan ini. Aktifkan dan uji di Dashboard sebelum mengandalkan alur guest.

## Database

- `games.phase` dibatasi ke `bidding`, `action`, `sell`, `economy`, dan `finished`.
- `games.state` hanya untuk data publik; tangan pemain dan bidding rahasia dipisahkan ke `game_private_states` dan `bidding_submissions`.
- Private state dan bid hanya bisa dibaca pemiliknya; penulisan belum diberikan ke client dan perlu RPC game tervalidasi.
- `game_events` adalah log internal dan tidak lagi dapat dibaca client atau dikirim lewat Realtime.
- Perubahan database tahap ini diterapkan langsung melalui SQL; Supabase migration history masih kosong.

## Keamanan

- Browser hanya memakai project URL dan Supabase publishable key.
- Secret/service-role key tidak disimpan di repository.
- RLS aktif pada semua tabel publik; akses anonim tanpa sesi tidak diberi table grants.
- Data privat pemain dan sealed bids hanya bisa dibaca pemiliknya; tidak dipublikasikan melalui Realtime.
- Pembuatan/join/keluar room melalui RPC tervalidasi; client hanya boleh mengubah flag kesiapan miliknya sendiri.
- Client tidak dapat menulis `games`, private state, sealed bids, atau `game_events`; mutasi game harus melalui RPC server yang memvalidasi fase, giliran, dan aturan.

## Teknologi

- Frontend: HTML, CSS, JavaScript.
- Hosting target: GitHub Pages (status deployment perlu dicek di Actions/Pages).
- Backend: Supabase Auth, PostgreSQL, Realtime.

## Tahapan berikutnya

1. Uji username tamu dan lobby dengan dua atau lebih browser/perangkat.
2. Bangun transaksi awal permainan dan game engine yang memvalidasi Guide Resmi.
3. Implementasikan bidding tertutup, kartu aksi, fase jual, ekonomi, dan scoring.
4. Tambahkan pengujian end-to-end untuk concurrency, RLS, turn order, dan state sync.

**Status:** UI room/lobby dan fondasi database sudah disiapkan. Project belum memiliki akun Auth saat pemeriksaan; Anonymous Auth dan alur dua pemain belum diuji end-to-end. Game engine dan efek kartu belum diimplementasikan.
