const gallery = document.querySelector("#gallery");
const search = document.querySelector("#search");
const filter = document.querySelector("#filter");
const notice = document.querySelector("#asset-notice");

let assets = [];
let imageUrls = new Map();
let archiveStatus = "loading";
let archiveError = "";
let failedImages = 0;

async function initializeCatalog() {
  try {
    const response = await fetch("assets/manifest.json");
    if (!response.ok) throw new Error("Manifest katalog tidak dapat dimuat.");
    const manifest = await response.json();
    assets = Array.isArray(manifest.assets) ? manifest.assets : [];
    document.querySelector("#total-assets").textContent = String(assets.length);

    updateNotice();
    await loadOriginalAssetArchive();
    render();
  } catch (error) {
    archiveStatus = "failed";
    archiveError = error instanceof Error ? error.message : "Terjadi kesalahan saat memuat katalog.";
    render();
    updateNotice();
    console.error(error);
  }
}

async function loadOriginalAssetArchive() {
  if (!window.JSZip) {
    throw new Error("Library pembaca arsip tidak tersedia. Periksa koneksi internet lalu muat ulang halaman.");
  }

  const response = await fetch("stocklab-assets-upload.zip", { cache: "force-cache" });
  if (!response.ok) {
    throw new Error("Arsip foto kartu belum tersedia di hosting (HTTP " + response.status + ").");
  }

  const archive = await window.JSZip.loadAsync(await response.arrayBuffer());
  const files = await Promise.all(assets.map(async (asset) => {
    const entry = archive.file(asset.path);
    if (!entry) return null;
    const blob = await entry.async("blob");
    return [asset.path, URL.createObjectURL(blob)];
  }));

  imageUrls = new Map(files.filter(Boolean));
  const missing = assets.filter((asset) => !imageUrls.has(asset.path));
  if (missing.length) {
    throw new Error("Arsip berhasil dibaca, tetapi " + missing.length + " gambar tidak ditemukan.");
  }

  archiveStatus = "ready";
  archiveError = "";
}

function render() {
  const query = search.value.trim().toLowerCase();
  const category = filter.value;
  const list = assets.filter((asset) => {
    const matchesCategory = category === "all" || asset.category === category;
    const searchable = [asset.title, asset.group, asset.category, asset.path]
      .filter(Boolean).join(" ").toLowerCase();
    return matchesCategory && searchable.includes(query);
  });

  failedImages = 0;
  gallery.replaceChildren();

  if (!list.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "Tidak ada aset yang cocok dengan pencarian.";
    gallery.append(empty);
    updateNotice();
    return;
  }

  for (const asset of list) {
    const card = document.createElement("article");
    card.className = "asset-card";

    const art = document.createElement("div");
    art.className = "asset-art";

    const img = document.createElement("img");
    img.src = imageUrls.get(asset.path) || asset.path;
    img.alt = asset.title || "Aset StockLab";
    img.loading = "lazy";
    img.addEventListener("error", () => showImageFallback(art, asset, img), { once: true });
    art.append(img);

    const meta = document.createElement("div");
    meta.className = "asset-meta";

    const kind = document.createElement("span");
    kind.className = "asset-kind";
    kind.textContent = (asset.category || "Aset") + " · " + (asset.group || "Komponen");

    const title = document.createElement("h3");
    title.textContent = asset.title || "Aset StockLab";

    const page = document.createElement("p");
    page.textContent = "Halaman sumber " + (Number(asset.page) || "-");

    const source = document.createElement("div");
    source.className = "asset-page";
    source.textContent = "SOURCE PDF · PAGE " + String(asset.page || "-").padStart(2, "0");

    meta.append(kind, title, page, source);
    card.append(art, meta);
    gallery.append(card);
  }

  updateNotice();
}

function showImageFallback(container, asset, img) {
  if (img.parentElement !== container) return;
  img.remove();
  container.classList.add("missing");

  const fallback = document.createElement("div");
  fallback.className = "asset-placeholder";

  const initial = document.createElement("b");
  initial.textContent = (asset.title || "S").slice(0, 1).toUpperCase();

  const title = document.createElement("span");
  title.textContent = asset.title || "Aset StockLab";

  fallback.append(initial, title);
  container.append(fallback);
  failedImages += 1;
  updateNotice();
}

function updateNotice() {
  if (archiveStatus === "loading") {
    notice.hidden = false;
    notice.textContent = "Memuat arsip foto asli StockLab. Pada kunjungan pertama, browser perlu mengunduh arsip sekitar 24,6 MB.";
    return;
  }
  if (archiveStatus === "failed") {
    notice.hidden = false;
    notice.textContent = archiveError || "Foto asli belum dapat dimuat. Metadata katalog tetap tersedia.";
    return;
  }
  if (failedImages > 0) {
    notice.hidden = false;
    notice.textContent = failedImages + " gambar tidak berhasil ditampilkan. Muat ulang halaman atau periksa koneksi.";
    return;
  }
  notice.hidden = true;
}

search.addEventListener("input", render);
filter.addEventListener("change", render);
initializeCatalog();
