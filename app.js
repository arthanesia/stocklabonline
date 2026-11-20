// StockLab Online — guest-first multiplayer lobby + asset catalog.
const SUPABASE_URL = "https://euzilxlmhuxftycgaqwh.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_YGViDDZQTaXVpUFJDeHDtA_jfZxWy9m";

const supabaseFactory = window.supabase && window.supabase.createClient;
const db = typeof supabaseFactory === "function"
  ? supabaseFactory(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    })
  : null;

const ui = {
  enterForm: document.querySelector("#enter-form"),
  usernameInput: document.querySelector("#username-input"),
  enterButton: document.querySelector("#enter-button"),
  guestEntry: document.querySelector("#guest-entry"),
  workspace: document.querySelector("#room-workspace"),
  locked: document.querySelector("#workspace-locked"),
  notice: document.querySelector("#app-notice"),
  connection: document.querySelector("#connection-indicator"),
  playerPill: document.querySelector("#player-pill"),
  playerName: document.querySelector("#player-name-label"),
  createForm: document.querySelector("#create-room-form"),
  createButton: document.querySelector("#create-room-button"),
  maxPlayers: document.querySelector("#max-players"),
  joinForm: document.querySelector("#join-room-form"),
  joinInput: document.querySelector("#room-code-input"),
  joinButton: document.querySelector("#join-room-button"),
  roomList: document.querySelector("#room-list"),
  refreshRooms: document.querySelector("#refresh-rooms"),
  lobby: document.querySelector("#room-lobby"),
  lobbyTitle: document.querySelector("#lobby-title"),
  lobbySubtitle: document.querySelector("#lobby-subtitle"),
  lobbyCode: document.querySelector("#lobby-code"),
  lobbyCount: document.querySelector("#lobby-count"),
  roster: document.querySelector("#player-roster"),
  lobbyHint: document.querySelector("#lobby-hint"),
  copyCode: document.querySelector("#copy-code-button"),
  readyButton: document.querySelector("#ready-button"),
  leaveButton: document.querySelector("#leave-room-button")
};

const gameSession = {
  user: null,
  username: "",
  roomId: null,
  roomCode: "",
  roomMeta: null,
  members: [],
  channel: null
};

function setConnection(label, online = false) {
  ui.connection.innerHTML = "";
  const dot = document.createElement("i");
  dot.textContent = "●";
  const text = document.createTextNode(" " + label);
  ui.connection.append(dot, text);
  ui.connection.classList.toggle("connected", online);
}

function showNotice(message, kind = "info", linkText = "", linkHref = "") {
  ui.notice.replaceChildren();
  ui.notice.className = "app-notice " + kind;
  ui.notice.append(document.createTextNode(message));
  if (linkText && linkHref) {
    const link = document.createElement("a");
    link.href = linkHref;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = linkText;
    ui.notice.append(document.createTextNode(" "), link);
  }
  ui.notice.hidden = !message;
}

function clearNotice() {
  showNotice("");
}

function errorMessage(error) {
  return error && (error.message || error.error_description || error.details)
    ? String(error.message || error.error_description || error.details)
    : "Terjadi kesalahan. Coba lagi.";
}

function setBusy(button, busy, busyText) {
  if (!button) return;
  if (busy) {
    button.dataset.originalText = button.textContent;
    button.disabled = true;
    button.textContent = busyText || "Memproses…";
  } else {
    button.disabled = false;
    if (button.dataset.originalText) {
      button.textContent = button.dataset.originalText;
      delete button.dataset.originalText;
    }
  }
}

async function ensureGuestSession() {
  if (!db) throw new Error("Library Supabase belum berhasil dimuat. Periksa koneksi lalu muat ulang halaman.");
  const { data: sessionData, error: sessionError } = await db.auth.getSession();
  if (sessionError) throw sessionError;
  if (sessionData.session && sessionData.session.user) return sessionData.session;

  const { data, error } = await db.auth.signInAnonymously();
  if (error) {
    if (error.code === "anonymous_provider_disabled" || /anonymous.*disabled/i.test(error.message || "")) {
      throw Object.assign(new Error("Mode pemain tamu belum diaktifkan pada project Supabase."), {
        needsAnonymousSetup: true
      });
    }
    throw error;
  }
  if (!data.session || !data.user) throw new Error("Supabase belum memberikan sesi pemain tamu.");
  return data.session;
}

async function savePlayerProfile(username) {
  if (!gameSession.user) throw new Error("Sesi pemain belum tersedia.");
  const cleanName = username.trim().replace(/\s+/g, " ");
  if (cleanName.length < 2 || cleanName.length > 24) {
    throw new Error("Username harus terdiri dari 2 sampai 24 karakter.");
  }

  const { error } = await db.from("profiles").upsert({
    id: gameSession.user.id,
    display_name: cleanName,
    updated_at: new Date().toISOString()
  }, { onConflict: "id" });

  if (error) throw error;
  gameSession.username = cleanName;
  localStorage.setItem("stocklab_guest_username", cleanName);
  ui.playerName.textContent = cleanName;
  ui.playerPill.hidden = false;
  return cleanName;
}

function showWorkspace() {
  ui.guestEntry.hidden = true;
  ui.workspace.hidden = false;
  ui.locked.hidden = true;
  ui.playerPill.hidden = false;
  document.querySelector("#multiplayer").scrollIntoView({ behavior: "smooth", block: "start" });
}

function showGuestSetupError() {
  showNotice(
    "Fitur pemain tanpa email/password membutuhkan Anonymous Sign-Ins aktif. Buka Authentication → Sign In / Providers → Anonymous pada Supabase, lalu aktifkan Allow anonymous sign-ins.",
    "warning",
    "Buka pengaturan Auth",
    "https://supabase.com/dashboard/project/euzilxlmhuxftycgaqwh/auth/providers"
  );
}

async function enterAsGuest(event) {
  event.preventDefault();
  const username = ui.usernameInput.value;
  if (username.trim().length < 2 || username.trim().length > 24) {
    showNotice("Username harus terdiri dari 2 sampai 24 karakter.", "warning");
    return;
  }

  setBusy(ui.enterButton, true, "Menyiapkan pemain…");
  clearNotice();
  setConnection("CONNECTING");
  try {
    const session = await ensureGuestSession();
    gameSession.user = session.user;
    await savePlayerProfile(username);
    showWorkspace();
    setConnection("CONNECTED", true);
    await refreshOpenRooms();
    await restoreWaitingRoom();
  } catch (error) {
    console.error("Guest entry failed:", error);
    if (error.needsAnonymousSetup) {
      showGuestSetupError();
      setConnection("SETUP NEEDED");
    } else {
      showNotice(errorMessage(error), "error");
      setConnection("OFFLINE");
    }
  } finally {
    setBusy(ui.enterButton, false);
  }
}

async function restoreExistingGuest() {
  if (!db) {
    showNotice("Library Supabase belum berhasil dimuat. Muat ulang halaman.", "error");
    return;
  }
  try {
    const { data, error } = await db.auth.getSession();
    if (error) throw error;
    const session = data.session;
    if (!session || !session.user) return;

    gameSession.user = session.user;
    const { data: profile, error: profileError } = await db
      .from("profiles")
      .select("display_name")
      .eq("id", session.user.id)
      .maybeSingle();

    if (profileError) throw profileError;
    if (!profile || !profile.display_name) return;

    ui.usernameInput.value = profile.display_name;
    gameSession.username = profile.display_name;
    ui.playerName.textContent = profile.display_name;
    showWorkspace();
    setConnection("RECONNECTED", true);
    await refreshOpenRooms();
    await restoreWaitingRoom();
  } catch (error) {
    console.warn("Could not restore previous guest session:", error);
    setConnection("RECONNECT NEEDED");
  }
}

async function refreshOpenRooms() {
  if (!gameSession.user) return;
  ui.roomList.replaceChildren();
  const loading = document.createElement("div");
  loading.className = "loading";
  loading.textContent = "Mencari ruangan…";
  ui.roomList.append(loading);

  const { data, error } = await db.rpc("list_open_rooms");
  if (error) {
    ui.roomList.replaceChildren();
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = errorMessage(error);
    ui.roomList.append(empty);
    return;
  }

  const rooms = Array.isArray(data) ? data : [];
  ui.roomList.replaceChildren();
  if (!rooms.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    const title = document.createElement("strong");
    title.textContent = "Belum ada ruangan terbuka.";
    const help = document.createElement("span");
    help.textContent = "Buat meja baru atau bagikan kode ruanganmu ke teman.";
    empty.append(title, help);
    ui.roomList.append(empty);
    return;
  }

  rooms.forEach((room) => {
    const item = document.createElement("article");
    item.className = "room-item";

    const details = document.createElement("div");
    details.className = "room-item-details";
    const name = document.createElement("strong");
    name.textContent = "Meja " + room.host_name;
    const sub = document.createElement("span");
    sub.textContent = String(room.member_count) + " / " + String(room.max_players) + " pemain";
    details.append(name, sub);

    const code = document.createElement("code");
    code.textContent = room.invite_code;

    const join = document.createElement("button");
    join.type = "button";
    join.className = "small-join";
    const full = Number(room.member_count) >= Number(room.max_players);
    join.disabled = full;
    join.textContent = full ? "Penuh" : "Gabung";
    join.addEventListener("click", () => joinRoom(room.invite_code, join));

    item.append(details, code, join);
    ui.roomList.append(item);
  });
}

async function createRoom(event) {
  event.preventDefault();
  if (!gameSession.user) return;
  setBusy(ui.createButton, true, "Membuat meja…");
  clearNotice();
  try {
    await savePlayerProfile(gameSession.username);
    const maxPlayers = Number(ui.maxPlayers.value);
    const { data, error } = await db.rpc("create_room", {
      p_display_name: gameSession.username,
      p_max_players: maxPlayers
    });
    if (error) throw error;
    await openRoom(data.room_id, data.invite_code);
    await refreshOpenRooms();
    showNotice("Ruangan berhasil dibuat. Bagikan kode " + data.invite_code + " kepada teman.", "success");
  } catch (error) {
    console.error("Create room failed:", error);
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.createButton, false);
  }
}

async function joinRoom(code, button = ui.joinButton) {
  if (!gameSession.user) return;
  const normalizedCode = String(code || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(normalizedCode)) {
    showNotice("Kode ruangan harus terdiri dari 6 huruf atau angka.", "warning");
    return;
  }
  setBusy(button, true, "Menghubungkan…");
  clearNotice();
  try {
    await savePlayerProfile(gameSession.username);
    const { data, error } = await db.rpc("join_room_by_code", { p_code: normalizedCode });
    if (error) throw error;
    await openRoom(data.room_id, normalizedCode);
    await refreshOpenRooms();
  } catch (error) {
    console.error("Join room failed:", error);
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(button, false);
  }
}

async function openRoom(roomId, inviteCode) {
  gameSession.roomId = roomId;
  gameSession.roomCode = inviteCode;
  ui.lobby.hidden = false;
  ui.lobby.scrollIntoView({ behavior: "smooth", block: "nearest" });

  const { data: room, error } = await db
    .from("rooms")
    .select("id,invite_code,host_id,max_players,status")
    .eq("id", roomId)
    .maybeSingle();
  if (error) throw error;
  if (!room) throw new Error("Ruangan tidak ditemukan atau akses sudah berakhir.");

  gameSession.roomMeta = room;
  gameSession.roomCode = room.invite_code;
  ui.lobbyCode.textContent = room.invite_code;
  ui.lobbyTitle.textContent = "Meja " + room.invite_code;
  ui.lobbySubtitle.textContent = "Bagikan kode ini untuk mengundang pemain lain.";
  await refreshLobby();
  subscribeToRoom();
}

async function refreshLobby() {
  if (!gameSession.roomId || !gameSession.user) return;
  const { data, error } = await db.rpc("get_room_lobby", {
    p_room_id: gameSession.roomId
  });
  if (error) {
    showNotice(errorMessage(error), "error");
    return;
  }

  gameSession.members = Array.isArray(data) ? data : [];
  const capacity = gameSession.roomMeta ? gameSession.roomMeta.max_players : 5;
  ui.lobbyCount.textContent = gameSession.members.length + " / " + capacity + " pemain";
  ui.roster.replaceChildren();

  const current = gameSession.members.find((member) => member.user_id === gameSession.user.id);
  ui.readyButton.disabled = !current;
  ui.readyButton.textContent = current && current.is_ready ? "Batalkan kesiapan" : "Saya siap ✓";
  ui.readyButton.classList.toggle("is-ready", Boolean(current && current.is_ready));

  for (let seat = 1; seat <= Number(capacity); seat += 1) {
    const member = gameSession.members.find((entry) => Number(entry.seat_no) === seat);
    const row = document.createElement("div");
    row.className = member ? "roster-player" : "roster-player vacant";

    const seatLabel = document.createElement("span");
    seatLabel.className = "seat-number";
    seatLabel.textContent = String(seat).padStart(2, "0");

    const name = document.createElement("strong");
    name.textContent = member ? member.display_name : "Menunggu pemain";

    const meta = document.createElement("span");
    if (!member) {
      meta.className = "roster-state vacant-label";
      meta.textContent = "KURSI KOSONG";
    } else {
      const tags = [];
      if (gameSession.roomMeta && member.user_id === gameSession.roomMeta.host_id) tags.push("HOST");
      if (member.user_id === gameSession.user.id) tags.push("KAMU");
      meta.className = "roster-state " + (member.is_ready ? "ready" : "pending");
      meta.textContent = tags.concat(member.is_ready ? "SIAP" : "BELUM SIAP").join(" · ");
    }

    row.append(seatLabel, name, meta);
    ui.roster.append(row);
  }

  const allReady = gameSession.members.length >= 2 && gameSession.members.length === Number(capacity)
    ? gameSession.members.every((member) => member.is_ready)
    : false;
  if (gameSession.members.length >= 2 && gameSession.members.every((member) => member.is_ready)) {
    ui.lobbyHint.textContent = "Semua pemain yang hadir sudah siap. Menunggu fitur mulai permainan.";
  } else {
    ui.lobbyHint.textContent = "Bagikan kode undangan dan tandai kesiapan setelah semua pemain bergabung.";
  }
  if (allReady) ui.lobbyHint.textContent = "Semua kursi terisi dan pemain sudah siap. Game engine belum diaktifkan.";
}

function subscribeToRoom() {
  if (!gameSession.roomId || !db) return;
  if (gameSession.channel) db.removeChannel(gameSession.channel);

  const roomId = gameSession.roomId;
  gameSession.channel = db
    .channel("stocklab-room-" + roomId)
    .on("postgres_changes", {
      event: "*",
      schema: "public",
      table: "room_members",
      filter: "room_id=eq." + roomId
    }, async () => {
      await refreshLobby();
      await refreshOpenRooms();
    })
    .on("postgres_changes", {
      event: "UPDATE",
      schema: "public",
      table: "rooms",
      filter: "id=eq." + roomId
    }, async () => {
      await refreshLobby();
      await refreshOpenRooms();
    })
    .subscribe((status) => {
      if (status === "SUBSCRIBED") setConnection("ROOM LIVE", true);
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") setConnection("RECONNECTING");
    });
}

async function toggleReady() {
  if (!gameSession.roomId || !gameSession.user) return;
  const current = gameSession.members.find((member) => member.user_id === gameSession.user.id);
  if (!current) return;

  setBusy(ui.readyButton, true, "Menyimpan…");
  try {
    const { error } = await db.from("room_members")
      .update({ is_ready: !current.is_ready })
      .eq("room_id", gameSession.roomId)
      .eq("user_id", gameSession.user.id);
    if (error) throw error;
    await refreshLobby();
  } catch (error) {
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.readyButton, false);
  }
}

async function leaveRoom() {
  if (!gameSession.roomId) return;
  setBusy(ui.leaveButton, true, "Keluar…");
  try {
    const { error } = await db.rpc("leave_room", { p_room_id: gameSession.roomId });
    if (error) throw error;
    if (gameSession.channel) {
      await db.removeChannel(gameSession.channel);
      gameSession.channel = null;
    }
    gameSession.roomId = null;
    gameSession.roomCode = "";
    gameSession.roomMeta = null;
    gameSession.members = [];
    ui.lobby.hidden = true;
    setConnection("CONNECTED", true);
    await refreshOpenRooms();
  } catch (error) {
    showNotice(errorMessage(error), "warning");
  } finally {
    setBusy(ui.leaveButton, false);
  }
}

async function restoreWaitingRoom() {
  if (!gameSession.user) return;
  const { data, error } = await db.from("room_members")
    .select("room_id,joined_at")
    .eq("user_id", gameSession.user.id)
    .order("joined_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error || !data) return;

  const { data: room, error: roomError } = await db.from("rooms")
    .select("id,invite_code,host_id,max_players,status")
    .eq("id", data.room_id)
    .maybeSingle();

  if (roomError || !room || room.status !== "waiting") return;
  await openRoom(room.id, room.invite_code);
}

ui.enterForm.addEventListener("submit", enterAsGuest);
ui.createForm.addEventListener("submit", createRoom);
ui.joinForm.addEventListener("submit", (event) => {
  event.preventDefault();
  joinRoom(ui.joinInput.value);
});
ui.refreshRooms.addEventListener("click", refreshOpenRooms);
ui.readyButton.addEventListener("click", toggleReady);
ui.leaveButton.addEventListener("click", leaveRoom);
ui.copyCode.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(gameSession.roomCode);
    ui.copyCode.textContent = "Tersalin ✓";
    setTimeout(() => { ui.copyCode.textContent = "Salin kode"; }, 1600);
  } catch (_) {
    showNotice("Salin kode secara manual: " + gameSession.roomCode, "info");
  }
});

const rememberedName = localStorage.getItem("stocklab_guest_username");
if (rememberedName) ui.usernameInput.value = rememberedName;
if (!db) {
  showNotice("Supabase SDK gagal dimuat. Muat ulang halaman atau periksa koneksi.", "error");
  setConnection("SDK ERROR");
} else {
  restoreExistingGuest();
}

// Asset catalog
const gallery = document.querySelector("#gallery");
const search = document.querySelector("#search");
const filter = document.querySelector("#filter");
const assetNotice = document.querySelector("#asset-notice");

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

    updateAssetNotice();
    await loadOriginalAssetArchive();
    renderCatalog();
  } catch (error) {
    archiveStatus = "failed";
    archiveError = error instanceof Error ? error.message : "Terjadi kesalahan saat memuat katalog.";
    renderCatalog();
    updateAssetNotice();
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
  if (missing.length) throw new Error("Arsip berhasil dibaca, tetapi " + missing.length + " gambar tidak ditemukan.");

  archiveStatus = "ready";
  archiveError = "";
}

function renderCatalog() {
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
    updateAssetNotice();
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
  updateAssetNotice();
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
  updateAssetNotice();
}

function updateAssetNotice() {
  if (archiveStatus === "loading") {
    assetNotice.hidden = false;
    assetNotice.textContent = "Memuat arsip foto asli StockLab. Pada kunjungan pertama, browser perlu mengunduh arsip sekitar 24,6 MB.";
    return;
  }
  if (archiveStatus === "failed") {
    assetNotice.hidden = false;
    assetNotice.textContent = archiveError || "Foto asli belum dapat dimuat. Metadata katalog tetap tersedia.";
    return;
  }
  if (failedImages > 0) {
    assetNotice.hidden = false;
    assetNotice.textContent = failedImages + " gambar tidak berhasil ditampilkan. Muat ulang halaman atau periksa koneksi.";
    return;
  }
  assetNotice.hidden = true;
}

search.addEventListener("input", renderCatalog);
filter.addEventListener("change", renderCatalog);
initializeCatalog();
