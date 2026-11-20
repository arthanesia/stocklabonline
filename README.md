# StockLab Online

Implementasi digital multiplayer StockLab berbasis browser, dengan Guide Resmi StockLab sebagai sumber aturan.

## Kondisi yang sudah diverifikasi

- Frontend statis tersedia: `index.html`, `style.css`, dan `app.js`.
- Katalog metadata berisi 56 entri di `assets/manifest.json`.
- Frontend memuat arsip `stocklab-assets-upload.zip` untuk membaca gambar kartu di browser.
- Project Supabase `stocklab-online` aktif (Postgres 17, region Singapore).
- Fondasi database telah diterapkan: `profiles`, `rooms`, `room_members`, `games`, dan `game_events`.
- RLS aktif pada seluruh tabel di schema `public`.
- Realtime Postgres Changes publication mencakup `rooms`, `room_members`, `games`, dan `game_events`.
- Snapshot skema aktif tersimpan di [supabase/schema.sql](supabase/schema.sql).

## Arsitektur

- Frontend: HTML, CSS, JavaScript.
- Hosting target: GitHub Pages (status deployment terkini belum diverifikasi dalam pekerjaan ini).
- Backend: Supabase Auth, PostgreSQL, dan Realtime.
- Browser hanya boleh menggunakan project URL dan publishable key. Jangan pernah memasukkan secret/service-role key ke frontend atau repository.

## Database

- Profil pemain terhubung ke `auth.users`.
- Room memiliki kode undangan 6 karakter dan kapasitas 2–5 pemain.
- `join_room_by_code` mengunci row room saat join agar pengecekan kapasitas dan alokasi kursi berjalan atomik.
- `get_room_lobby` hanya mengembalikan daftar pemain kepada anggota room tersebut.
- Client belum diberi hak tulis ke `games` atau `game_events`; aksi game harus melalui engine server yang memvalidasi giliran, fase, dan aturan.

## Tahapan berikutnya

1. Implementasikan onboarding dan autentikasi pemain.
2. Buat UI pembuatan room, join dengan kode, dan lobby/ready.
3. Bangun game engine server-side dan validasi setiap efek kartu terhadap guide serta aset asli.
4. Implementasikan sinkronisasi realtime privat dan uji minimal dua akun.
5. Tambahkan pengujian RLS, batas kapasitas, bidding rahasia, urutan giliran, fase, dan scoring.

**Status:** fondasi backend sudah dibuat, tetapi permainan multiplayer belum playable dan belum dinyatakan berhasil diuji end-to-end.
