# StockLab Online

Web game digital multiplayer berbasis Guide Resmi StockLab. Frontend statis di GitHub Pages, backend di Supabase.

## Status proyek
- [x] Repository khusus `arthanesia/stocklabonline`.
- [x] Fondasi UI responsif dan katalog aset.
- [x] Manifest metadata 56 aset dari PDF.
- [x] Arsip 56 gambar WebP asli sudah diunggah ke repository.
- [x] GitHub Pages berhasil menerbitkan versi fondasi.
- [ ] Membuat project Supabase dan menerapkan skema database.
- [ ] Implementasi game engine lengkap.
- [ ] Pengujian multiplayer.

## Teknologi
- Frontend: HTML, CSS, JavaScript.
- Hosting: GitHub Pages (deploy dari branch `main`).
- Backend: Supabase Auth, PostgreSQL, Realtime.

## Menjalankan lokal
Buka melalui local web server, misalnya VS Code Live Server. Katalog membaca `assets/manifest.json` dan arsip foto `stocklab-assets-upload.zip`.

## Aset kartu
Arsip `stocklab-assets-upload.zip` berisi 56 gambar WebP dan manifest. Halaman katalog mengekstrak gambar di browser menggunakan JSZip; tidak membuat atau mengubah desain kartu. Pada kunjungan pertama browser mengunduh arsip sekitar 24,6 MB. JSZip dipanggil dari CDN jsDelivr.

## GitHub Pages
Repository telah menghasilkan deployment GitHub Pages yang sukses. Pages menggunakan publikasi sumber branch `main`; setiap commit akan memicu build dan deployment bawaan GitHub Pages. Alur khusus GitHub Actions tidak digunakan karena token integrasi saat ini tidak memiliki izin untuk mengaktifkan Pages melalui API.

## Supabase
Belum ada project Supabase yang dibuat. File `supabase/draft-schema.sql` adalah rancangan awal dan **belum diterapkan**. Sebelum dipakai, schema, RPC, hak akses, dan RLS harus ditinjau. Frontend hanya boleh memuat project URL dan publishable key; secret/service-role key tidak boleh masuk ke repository publik.

## Aturan
Guide Resmi StockLab yang diunggah pemilik proyek menjadi sumber utama. Seluruh timing efek kartu, validasi giliran, urutan resolusi, perhitungan aset, dan kondisi akhir harus diuji terhadap guide sebelum multiplayer dinyatakan siap.

## Catatan penggunaan aset
Pastikan izin penggunaan logo dan foto kartu telah sesuai sebelum membuka permainan ke publik.
