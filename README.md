# StockLab Online

Permainan StockLab multiplayer berbasis browser. Pemain masuk dengan username tamu, membuat meja, lalu bermain bersama 3–5 orang.

## Yang tersedia

- Masuk sebagai pemain tamu tanpa formulir email/password.
- Buat room 3–5 pemain dengan password opsional; jika password dikosongkan, room langsung terbuka. Password yang diisi tidak dibatasi jumlah karakter.
- Join room dengan memasukkan kode dan password hanya jika room dikunci, atau memilih room yang sedang menunggu dari daftar.
- Lobby realtime dengan kode room, daftar pemain, status siap, dan kontrol mulai khusus host.
- Meja pertandingan dengan posisi pemain mengelilingi area papan; posisi disusun relatif ke pemain yang sedang melihat.
- Reksa Dana berada di tengah papan secara vertikal. Dua sektor pengaruh dipilih acak setiap game; harga unit adalah rata-rata harga dua sektor tersebut.
- Trading Fee dihitung dari jumlah unit pada sektor yang tercetak di kartu. Jika kartu Trading Fee disimpan, kartu itu ikut dihitung sebagai satu unit tambahan sebelum pajak dipotong dari saldo.
- Password room bersifat opsional. Password baru di-hash menggunakan SHA-256 di schema privat tanpa batas karakter; hash password lama bcrypt tetap didukung selama masa kompatibilitas.
- Host dapat mengatur waktu bidding, waktu tiap giliran, dan batas room tidak aktif sebelum memulai permainan.
- Bidding yang habis waktu menganggap pemain yang belum menawar memasukkan 0; giliran aksi otomatis menyimpan kartu teratas; giliran jual otomatis dilewati; fase ekonomi dibuka otomatis.
- Room yang tidak menerima aktivitas manusia akan dibubarkan. Batas tidak aktif dapat diatur host; pemeriksaan berjalan setiap menit.
- Jika host keluar dari lobby atau pertandingan, host berpindah ke pemain berikutnya. Jika pemain tersisa kurang dari dua saat pertandingan aktif, room dibubarkan.
- Enam ronde permainan: Bidding, Aksi/Draft, Jual, dan Ekonomi.
- Pada awal permainan, setiap pemain memilih satu kartu urutan tertutup. Nomor langsung terbuka untuk semua pemain dan menentukan tie-break saat nilai bidding sama. Setelah setiap pembukaan Ekonomi (kecuali ronde terakhir), pemain ditawari Kartu Utang secara opsional sebelum bidding berikutnya. Bidding tertutup: pemain hanya melihat status bid miliknya sampai seluruh pemain mengirim.
- Kartu aksi: Info Bursa, Rumor, Quickbuy, Trading Fee, dan Akuisisi.
- Kartu aksi dapat disimpan sebagai saham atau unit Reksa Dana sesuai keluarga kartu yang diambil.
- Fase jual biasa hanya menjual saham sektor; Reksa Dana hanya dapat dijual pada akhir permainan.
- Fase ekonomi membuka satu kartu dari setiap sektor, menjalankan perubahan harga serta efek khusus.
- Stock Crash, Stock Split, token split, kartu utang, nilai Reksa Dana, dan penghitungan skor akhir.
- Hasil pertandingan disimpan; pemain dapat kembali ke lobi setelah permainan selesai.

## Visual kartu dan meja permainan

Website memakai **56 gambar WebP yang diekstrak dari paket aset StockLab yang diunggah ke proyek**. Gambar tidak dibuat ulang: muka kartu aksi, kartu ekonomi, papan/tumpukan sektor, papan Reksa Dana, kartu utang, koin/token, dan sisi kartu diambil dari `stocklab-assets-upload.zip`.

- Kartu aksi tampil sebagai deretan kartu bergambar yang dapat digeser; pada giliran sendiri pemain memilih **Simpan** atau **Aktifkan**.
- Pasar saham ditampilkan dalam satu blok berisi lima kartu: dua sektor yang memengaruhi Reksa Dana berada tepat di kiri dan kanannya, sementara dua sektor lain berada di sisi luar.
- Kartu Reksa Dana berada di tengah secara vertikal; harga unit dan rumus rata-rata dua saham penentunya ditampilkan langsung pada kartu.
- Setiap kartu saham menampilkan harga dan indikator arah ▲ naik, ▼ turun, atau • belum berubah berdasarkan pergerakan terakhir.
- Aset saham dan Reksa Dana ditampilkan langsung di bawah nama masing-masing pemain pada kartu tempat duduk; gambar kartu menunjukkan jenis aset dan badge menunjukkan jumlah kepemilikan.
- Pasar kartu aksi memakai interaksi langsung: klik kartu untuk memilih Simpan atau Aktifkan, lalu pilih kartu/sektor/pemain target melalui kartu-kartu visual.
- Quickbuy mengambil dua kartu dengan klik; Info Bursa memilih tiga sektor dengan klik; Trading Fee dan Akuisisi memilih kartu aset/pemain secara visual.
- Rumor memilih sektor dan arah perubahan melalui kartu sektor. Harga dijaga pada rentang 1–9; perubahan yang melewati batas ditolak di UI dan divalidasi ulang di server.
- Fase jual memilih tumpukan kartu aset, jumlahnya, dan menampilkan hasil penjualan sebelum konfirmasi. Fase ekonomi dibuka lewat kartu pembuka bergambar.
- Aksi terbaru muncul sebagai kartu sorotan di meja dan tersimpan pada log aktivitas bersama, sehingga pemain lain melihat efek transaksi yang sama.
- Banner permainan menampilkan fase aktif, pemain yang sedang mendapat giliran, dan timer.
- Kartu ekonomi yang dibuka tampil menggunakan gambar muka kartu sesuai efeknya.
- Animasi kartu dibuat singkat dan dapat dinonaktifkan melalui pengaturan reduced-motion perangkat.

### Publikasi aset ke GitHub Pages

Repository menyimpan paket `stocklab-assets-upload.zip` di root. Workflow `.github/workflows/deploy-pages.yml` mengekstrak 56 gambar ke folder hasil build sebelum mengunggah artefak GitHub Pages.

Workflow GitHub Actions sudah berhasil membangun dan menerbitkan halaman dari artefak hasil ekstraksi. Pada build terverifikasi, 56 file WebP ikut masuk ke artefak `github-pages`; tidak perlu mengekstrak ZIP secara manual. Dokumentasi alur deploy: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

Panduan tata cara permainan yang dijadikan referensi: [Tutorial Bermain StockLab — KSPM FEB ULM](https://www.youtube.com/watch?v=0bd47voPuUs). UI mengikuti alur empat fase Bidding → Aksi → Jual → Ekonomi, dengan presentasi meja kartu digital.

## Cara bermain

1. Masuk dengan username. Pilih **Buat Room** atau **Join Room**.
2. Untuk membuat room, tentukan kapasitas dan isi password bila ingin mengunci room. Kosongkan kolom password untuk membuat room terbuka; tidak ada batas jumlah karakter password.
3. Untuk join, masukkan kode room atau pilih room pada daftar. Password hanya wajib untuk room yang dikunci.
4. Semua pemain yang hadir menekan **Saya siap**. Host dapat memulai setelah sedikitnya tiga pemain siap.
5. Setiap ronde dimulai dengan bidding tertutup. Masukkan tawaran minimal 1 koin dan tidak melebihi saldo. Bid yang sudah dikirim tidak dapat diubah.
6. Setelah semua bid masuk, biaya bid dibayar dan urutan pemain ditentukan dari bid tertinggi. Jika seri, urutan sebelumnya menjadi pemecah seri. Bila waktu bidding habis, pemain yang belum mengirim bid dianggap mengirim 0 koin.
7. Pemain bergiliran memilih kartu dari pasar aksi. Pilih **Simpan** untuk menambah saham/Reksa Dana, atau **Aktifkan** untuk menjalankan efek kartu. Setiap giliran memiliki timer; saat habis, kartu teratas otomatis disimpan.
8. Setelah semua kartu aksi habis, tiap pemain mendapat satu giliran menjual satu jenis saham/Reksa Dana atau melewati giliran. Jika timer habis, sistem otomatis melewati giliran jual tersebut. Pemakai Info Bursa ditempatkan paling akhir di fase jual.
9. Host membuka satu kartu ekonomi dari masing-masing tumpukan sektor. Efek kartu diterapkan. Untuk ronde yang masih berlanjut, setiap pemain yang belum memiliki utang mendapat penawaran Kartu Utang sebelum bidding berikutnya.
10. Penawaran utang dapat diterima (+10 koin, penalti akhir 13 koin) atau ditolak tanpa perubahan koin/aset. Jika pemain tidak menjawab sampai timer habis, penawaran dianggap ditolak. Tidak ada kewajiban membalik saham.
11. Setelah ekonomi ronde keenam, sistem menghitung koin, nilai saham, Reksa Dana, penalti utang, dan pemenang. Jika skor seri, urutan bermain yang lebih tinggi menjadi pemecah seri.

## Aksi dan mekanik khusus

- **Info Bursa:** pilih tiga sektor untuk mengintip kartu ekonomi teratasnya secara privat, lalu dapatkan 2 koin. Pemakainya menjual setelah pemain lain.
- **Rumor:** gerakkan satu sektor sebesar ±2 atau dua sektor masing-masing ±1 tanpa memicu Crash/Split.
- **Quickbuy:** pilih dua kartu aksi lain yang masih tersedia; kedua kartu tersebut disimpan sebagai kepemilikan sesuai keluarga sektornya.
- **Trading Fee:** bayar 1 koin per unit dari keluarga sektor kartu, lalu jual satu jenis saham/Reksa Dana pilihan.
- **Akuisisi:** ambil satu saham sektor dari pemain lain jika kepemilikanmu pada sektor yang sama minimal sebesar kepemilikan target. Kartu Akuisisi keluarga Reksa Dana tetap harus memilih sektor saham biasa; Reksa Dana tidak dapat diakuisisi.
- **Kartu utang:** setelah pembukaan ekonomi dan sebelum bidding ronde berikutnya, pemain ditawari pinjaman 10 koin. Terima untuk menambah 10 koin dan mencatat satu utang; tolak tanpa konsekuensi. Tidak perlu membalik saham. Setiap pemain maksimal satu kartu utang; 13 koin dikurangi dari total aset pada akhir permainan.
- **Reksa Dana:** harga unit dihitung dari rata-rata dibulatkan ke bawah dua sektor yang dipasangkan pada konfigurasi pertandingan ini, yaitu Konsumer dan Agrikultur.

## Catatan akurasi komponen

Implementasi ini mengikuti alur dan mekanik yang tersedia pada panduan StockLab yang diunggah untuk proyek, tetapi susunan kartu digital bukan klaim reproduksi set fisik resmi.

- Deck aksi digital berjumlah 60 kartu: 40 kartu keluarga saham sektor dan 20 kartu keluarga Reksa Dana.
- Tumpukan ekonomi dibuat dari 24 kartu pergerakan sektor dan 6 kartu khusus yang dipilih dari kumpulan 12 efek khusus. Total 24 kartu dipakai per permainan (enam per sektor); enam kartu sisanya tidak dipakai pada permainan itu.
- Teks, jumlah salinan, distribusi, dan beberapa efek ekonomi adalah adaptasi digital untuk prototipe. Konfirmasi varian dengan set fisik/panitia apabila digunakan untuk kompetisi resmi.

## Database dan keamanan

- Supabase project `stocklab-online`, PostgreSQL 17.
- Tabel `profiles` permanen sudah dihapus. Nama pemain disimpan lokal di browser, lalu disalin ke `room_members` hanya selama keanggotaan room aktif. State game, saldo privat, dan bid tetap berada di Supabase untuk sinkronisasi realtime dan validasi server.
- Tidak ada profil pemain permanen yang ditulis ke Supabase. State papan bersama disimpan di `games.state`; saldo, utang, dan intipan ekonomi disimpan per pemain di `game_private_states` selama pertandingan berlangsung.
- Bidding tersimpan di `bidding_submissions` dan tidak dibuka ke pemain lain sebelum seluruh bid masuk.
- Deck aksi dan tumpukan ekonomi disimpan di `private.game_engine_secrets`, tidak dapat dibaca klien browser.
- Mutasi permainan dijalankan melalui RPC yang memvalidasi keanggotaan, host, fase, giliran, saldo, dan pilihan kartu di database.
- Public RPC memakai `SECURITY INVOKER`; implementasi privat yang memerlukan transaksi berjalan melalui fungsi terbatas di schema `private`.
- RLS aktif pada seluruh tabel schema `public`. Browser hanya memakai URL project dan publishable key; secret/service-role key tidak ada di frontend.

## Instalasi database

Pada project Supabase baru, jalankan file berikut secara berurutan di SQL Editor:

1. [supabase/schema.sql](supabase/schema.sql)
2. [supabase/game-engine.sql](supabase/game-engine.sql)
3. [supabase/room-passwords.sql](supabase/room-passwords.sql)
4. [supabase/room-game-settings.sql](supabase/room-game-settings.sql)
5. [supabase/tabletop-activity-feed.sql](supabase/tabletop-activity-feed.sql)
6. [supabase/rumor-price-boundaries.sql](supabase/rumor-price-boundaries.sql)
7. [supabase/competition-order-draw-and-fees.sql](supabase/competition-order-draw-and-fees.sql)
8. [supabase/room-privacy-assets-debt-offer-phase.sql](supabase/room-privacy-assets-debt-offer-phase.sql)
9. [supabase/debt-offer-eligible-rank-fix.sql](supabase/debt-offer-eligible-rank-fix.sql)
10. [supabase/rpc-invoker-privileges.sql](supabase/rpc-invoker-privileges.sql)
11. [supabase/drop-legacy-player-profiles.sql](supabase/drop-legacy-player-profiles.sql)

File kedua membuat penyimpanan deck privat dan mengganti fungsi awal menjadi engine permainan lengkap. File ketiga menambahkan password room dan mengganti RPC buat/join room dengan verifikasi hash bcrypt. File keempat menambahkan papan Reksa Dana acak, biaya Trading Fee, pengaturan durasi, timeout otomatis, pembersihan room idle, dan aturan leave/host handover. File kelima menambahkan catatan aktivitas publik yang aman untuk anggota room, merinci transaksi kartu dan penjualan, serta mengirim event terbaru melalui RPC tampilan permainan. File keenam menolak gerakan Rumor yang melampaui batas harga saham 1–9. File ketujuh menambahkan pengambilan kartu urutan tertutup sebelum bidding, menyembunyikan nomor yang belum dibuka dari game view, menetapkan batas meja 3–5 pemain, memperbaiki Trading Fee dan aturan penjualan Reksa Dana, serta mengulang pengundian pasar aksi bila komposisinya melanggar aturan. File kedelapan memindahkan nama pemain ke keanggotaan room, mengosongkan profil permanen, membuat password opsional tanpa batas karakter, dan menambahkan fase penawaran utang setelah Ekonomi. File kesembilan memperbaiki alokasi stok kartu utang agar hanya menghitung pemain yang belum pernah menerima pinjaman. File kesepuluh memastikan wrapper RPC publik memakai hak invoker dan hanya dapat dijalankan role authenticated. File kesebelas menghapus tabel profil permanen yang sudah tidak digunakan. Pada project pengembangan saat ini, SQL diterapkan langsung; riwayat migration Supabase belum direkonsiliasi.

## Pengujian

Pengujian otomatis dilakukan pada transaksi database terisolasi dan room tes dihapus setelah hasil didapat.

- Simulasi dua pemain menyelesaikan enam ronde, dari bidding sampai skor akhir.
- Simulasi lima pemain menyelesaikan enam ronde, dengan 10 pilihan kartu aksi dan 5 giliran jual pada setiap ronde.
- Uji Info Bursa, intipan tiga sektor, +2 koin, dan urutan jual paling akhir.
- Uji Rumor, Quickbuy dua kartu, Trading Fee, Akuisisi, penyimpanan Reksa Dana, dan penjualan Reksa Dana.
- Uji kartu utang: satu saham dibalik, +10 koin, dan penalti akhir 13.
- Uji 12 jenis efek khusus ekonomi dalam enam reveal, termasuk Buyback, Extra Fee, Merger, Resesi, Stimulus, Pajak Jalan, World Oil Regulation, Dividen, dan Restrukturisasi.
- Uji Stock Crash dan Stock Split: reset harga ke 5, perubahan lembar saham, serta pengembalian/penggunaan token split.
- Uji pengosongan intipan privat setelah kartu ekonomi dibuka.
- JavaScript lolos pemeriksaan sintaks dan semua referensi elemen HTML cocok.

Pengujian transaksi ini membuktikan alur backend dan simulasi permainan; bukan jaminan bebas bug. Uji langsung pada beberapa browser/perangkat serta koneksi Realtime selama pemain nyata masih diperlukan.

## Akses

- Repository: https://github.com/arthanesia/stocklabonline
- Website: https://arthanesia.github.io/stocklabonline/

Sesi tamu melekat pada browser/perangkat. Menghapus data browser atau berpindah perangkat berarti identitas tamu yang sama tidak dapat dipulihkan.
