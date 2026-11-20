# StockLab Online

Web game digital multiplayer berbasis Guide Resmi StockLab. Frontend statis di GitHub Pages, backend di Supabase.

## Status proyek
- [x] Repository khusus `arthanesia/stocklabonline`.
- [x] Fondasi UI responsif dan katalog aset.
- [x] Manifest metadata 56 aset dari PDF.
- [x] Workflow GitHub Pages.
- [ ] Mengunggah foto kartu asli.
- [ ] Membuat project dan skema Supabase.
- [ ] Implementasi game engine lengkap.
- [ ] Pengujian multiplayer.

## Teknologi
- Frontend: HTML, CSS, JavaScript.
- Hosting: GitHub Pages + GitHub Actions.
- Backend: Supabase Auth, PostgreSQL, Realtime.

## Menjalankan lokal
Buka melalui local web server, misalnya VS Code Live Server. Katalog membaca `assets/manifest.json`.

## Memasukkan gambar kartu
Unduh arsip `stocklab-assets-upload.zip` yang disediakan di percakapan proyek ini. Unggah file ZIP tersebut ke **root repository** (sejajar dengan `index.html`) melalui Add file → Upload files. Workflow Pages akan mengekstrak `assets/cards/` dan `assets/manifest.json` otomatis sebelum menerbitkan situs.

Jangan mengganti nama file/folder di dalam ZIP. Foto kartu adalah hasil ekstraksi dari aset yang disediakan pemilik proyek, bukan ilustrasi pengganti.

## Mengaktifkan GitHub Pages (perlu satu kali dari pemilik akun)
1. Buka Settings → Pages.
2. Pada Build and deployment, pilih **GitHub Actions** sebagai Source.
3. Setelah Pages diaktifkan, setiap push ke `main` akan menjalankan workflow `.github/workflows/pages.yml`.

## Supabase
Belum ada project Supabase yang dibuat. File `supabase/draft-schema.sql` adalah rancangan awal dan **belum diterapkan**. Sebelum dipakai, schema, RPC, hak akses, dan RLS harus ditinjau. Frontend hanya boleh memuat project URL dan publishable key; secret/service-role key tidak boleh masuk ke repository publik.

## Aturan
Guide Resmi StockLab yang diunggah pemilik proyek menjadi sumber utama. Seluruh timing efek kartu, validasi giliran, urutan resolusi, perhitungan aset, dan kondisi akhir harus diuji terhadap guide sebelum multiplayer dinyatakan siap.

## Catatan penggunaan aset
Pastikan izin penggunaan logo dan foto kartu telah sesuai sebelum membuka permainan ke publik.
