const gallery = document.querySelector("#gallery");
const search = document.querySelector("#search");
const filter = document.querySelector("#filter");
const notice = document.querySelector("#asset-notice");
let assets = [];

fetch("assets/manifest.json")
  .then((response) => {
    if (!response.ok) throw new Error("Manifest belum tersedia.");
    return response.json();
  })
  .then((data) => {
    assets = Array.isArray(data.assets) ? data.assets : [];
    document.querySelector("#total-assets").textContent = assets.length || 0;
    render();
  })
  .catch((error) => {
    gallery.innerHTML = '<div class="empty">Katalog belum dapat dimuat. Pastikan assets/manifest.json sudah ada.</div>';
    notice.hidden = false;
    notice.textContent = error.message;
    console.error(error);
  });

function render() {
  const query = search.value.trim().toLowerCase();
  const category = filter.value;
  const list = assets.filter((asset) => {
    const matchesCategory = category === "all" || asset.category === category;
    const searchable = [asset.title, asset.group, asset.category, asset.path]
      .filter(Boolean).join(" ").toLowerCase();
    return matchesCategory && searchable.includes(query);
  });

  if (!list.length) {
    gallery.innerHTML = '<div class="empty">Tidak ada aset yang cocok dengan pencarian.</div>';
    checkMissingImages();
    return;
  }

  gallery.innerHTML = list.map((asset) => {
    const title = escapeHtml(asset.title || "Aset StockLab");
    const group = escapeHtml(asset.group || asset.category || "Komponen");
    const path = escapeHtml(asset.path || "");
    const initial = escapeHtml((asset.title || "S").slice(0, 1).toUpperCase());
    return `
      <article class="asset-card">
        <div class="asset-art">
          <img src="${path}" alt="${title}" loading="lazy"
            onerror="this.remove();this.parentElement.classList.add('missing');this.parentElement.insertAdjacentHTML('afterbegin','<div class=&quot;asset-placeholder&quot;><b>${initial}</b><span>${title}</span></div>');checkMissingImages()">
        </div>
        <div class="asset-meta">
          <span class="asset-kind">${escapeHtml(asset.category || "Aset")} · ${group}</span>
          <h3>${title}</h3>
          <p>Halaman sumber ${Number(asset.page) || "-"}</p>
          <div class="asset-page">SOURCE PDF · PAGE ${String(asset.page || "-").padStart(2, "0")}</div>
        </div>
      </article>`;
  }).join("");
  checkMissingImages();
}

function checkMissingImages() {
  const expected = assets.length;
  const hasFallback = gallery.querySelectorAll(".asset-art.missing").length;
  const placeholders = gallery.querySelectorAll(".asset-placeholder").length;
  if (expected && (hasFallback > 0 || placeholders > 0)) {
    notice.hidden = false;
    notice.textContent = "Metadata katalog sudah tersedia. Sebagian/seluruh foto kartu belum diunggah ke assets/cards/. Unggah paket stocklab-assets-upload.zip ke root repository agar gambar asli ikut diterbitkan.";
  } else {
    notice.hidden = true;
  }
}
function escapeHtml(value = "") {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character]);
}
search.addEventListener("input", render);
filter.addEventListener("change", render);
