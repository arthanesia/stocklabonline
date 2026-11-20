# StockLab Online

Web game digital multiplayer berbasis aturan resmi StockLab, dengan frontend statis dan Supabase sebagai backend.

## Status awal
- [x] Repository khusus StockLab Online.
- [x] Katalog metadata 56 aset dari PDF yang diunggah.
- [ ] Mengunggah seluruh gambar kartu asli ke folder `assets/cards/`.
- [ ] Membuat project Supabase dan menerapkan skema database.
- [ ] Mengimplementasikan game engine sesuai Guide Resmi StockLab.
- [ ] Menguji multiplayer dan menerbitkan website.

## Teknologi
- Frontend: HTML, CSS, JavaScript.
- Hosting: GitHub Pages melalui GitHub Actions.
- Backend: Supabase Auth, PostgreSQL, dan Realtime.
- Tidak menggunakan framework/build step pada fondasi awal.

## Menjalankan lokal
Buka `index.html` melalui local web server (contoh VS Code Live Server). Katalog mengambil metadata dari `assets/manifest.json`.

## Melengkapi aset gambar
Paket aset yang disiapkan dari PDF berisi folder `assets/cards/` dan file `assets/manifest.json`. Ekstrak paket starter, lalu unggah folder `assets/cards/` ke repository dengan struktur yang sama. Katalog saat ini menampilkan placeholder jika file foto belum tersedia.

## GitHub Pages
1. Buka Settings → Pages.
2. Pada Build and deployment, pilih **GitHub Actions**.
3. Workflow `.github/workflows/pages.yml` akan menerbitkan isi repository saat ada push ke branch `main`.

## Supabase
Skema awal akan ditinjau dan diterapkan setelah project Supabase dibuat. Gunakan hanya project URL dan publishable key pada frontend. Jangan pernah memasukkan secret/service-role key ke repository publik.

## Aturan permainan
Guide Resmi StockLab yang diunggah pemilik proyek menjadi sumber utama. Detail efek kartu, urutan resolusi, validasi giliran, perhitungan aset, dan kondisi akhir harus diuji terhadap guide sebelum multiplayer dinyatakan siap.
