// StockLab Online — guest access, room lobby and initial game table.
const SUPABASE_URL = "https://euzilxlmhuxftycgaqwh.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_YGViDDZQTaXVpUFJDeHDtA_jfZxWy9m";

const supabaseFactory = window.supabase && window.supabase.createClient;
const db = typeof supabaseFactory === "function"
  ? supabaseFactory(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    })
  : null;

const byId = (id) => document.getElementById(id);
const ui = {
  enterForm: byId("enter-form"),
  usernameInput: byId("username-input"),
  enterButton: byId("enter-button"),
  guestEntry: byId("guest-entry"),
  workspace: byId("room-workspace"),
  locked: byId("workspace-locked"),
  notice: byId("app-notice"),
  connection: byId("connection-indicator"),
  playerPill: byId("player-pill"),
  playerAvatar: byId("player-avatar"),
  playerName: byId("player-name-label"),
  createForm: byId("create-room-form"),
  createButton: byId("create-room-button"),
  maxPlayers: byId("max-players"),
  joinForm: byId("join-room-form"),
  joinInput: byId("room-code-input"),
  joinButton: byId("join-room-button"),
  roomList: byId("room-list"),
  refreshRooms: byId("refresh-rooms"),
  lobby: byId("room-lobby"),
  lobbyTitle: byId("lobby-title"),
  lobbySubtitle: byId("lobby-subtitle"),
  lobbyCode: byId("lobby-code"),
  lobbyCount: byId("lobby-count"),
  roster: byId("player-roster"),
  lobbyHint: byId("lobby-hint"),
  copyCode: byId("copy-code-button"),
  readyButton: byId("ready-button"),
  startButton: byId("start-game-button"),
  leaveButton: byId("leave-room-button"),
  gameTable: byId("game-table"),
  gameSubtitle: byId("game-subtitle"),
  gameRound: byId("game-round"),
  gamePhase: byId("game-phase"),
  gamePhaseDescription: byId("game-phase-description"),
  marketGrid: byId("market-grid"),
  gamePlayers: byId("game-players"),
  gamePlayerCount: byId("game-player-count"),
  ownCoins: byId("own-coins"),
  ownShares: byId("own-shares"),
  gameNote: byId("game-note")
};

const sessionState = {
  user: null,
  username: "",
  roomId: null,
  roomCode: "",
  roomMeta: null,
  members: [],
  game: null,
  channel: null
};

const SECTORS = [
  { id: "finance", name: "Keuangan" },
  { id: "consumer", name: "Konsumer" },
  { id: "agriculture", name: "Agrikultur" },
  { id: "mining", name: "Tambang" }
];

function setConnection(label, online = false) {
  const text = ui.connection.querySelector("span");
  if (text) text.textContent = label;
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

function cleanPlayerName(value) {
  return String(value || "").trim().replace(/\s+/g, " ");
}

async function ensureGuestSession() {
  if (!db) throw new Error("Library Supabase belum berhasil dimuat. Muat ulang halaman.");
  const { data: sessionData, error: sessionError } = await db.auth.getSession();
  if (sessionError) throw sessionError;
  if (sessionData.session && sessionData.session.user) return sessionData.session;

  const { data, error } = await db.auth.signInAnonymously();
  if (error) {
    if (error.code === "anonymous_provider_disabled" || /anonymous.*disabled/i.test(error.message || "")) {
      throw Object.assign(new Error("Mode pemain tamu belum aktif di Supabase."), { needsAnonymousSetup: true });
    }
    throw error;
  }
  if (!data.session || !data.user) throw new Error("Supabase belum memberikan sesi pemain tamu.");
  return data.session;
}

async function savePlayerProfile(username) {
  const cleanName = cleanPlayerName(username);
  if (!sessionState.user) throw new Error("Sesi pemain belum tersedia.");
  if (cleanName.length < 2 || cleanName.length > 24) {
    throw new Error("Username harus terdiri dari 2 sampai 24 karakter.");
  }
  const { error } = await db.from("profiles").upsert({
    id: sessionState.user.id,
    display_name: cleanName,
    updated_at: new Date().toISOString()
  }, { onConflict: "id" });
  if (error) throw error;

  sessionState.username = cleanName;
  localStorage.setItem("stocklab_guest_username", cleanName);
  ui.playerName.textContent = cleanName;
  ui.playerAvatar.textContent = cleanName.slice(0, 1).toUpperCase();
  ui.playerPill.hidden = false;
  return cleanName;
}

function showWorkspace() {
  ui.guestEntry.hidden = true;
  ui.workspace.hidden = false;
  ui.locked.hidden = true;
}

function showGuestSetupError() {
  showNotice(
    "Pemain tamu memerlukan Anonymous Sign-Ins yang aktif. Pastikan pengaturan tersebut sudah disimpan di Supabase.",
    "warning",
    "Buka pengaturan Auth",
    "https://supabase.com/dashboard/project/euzilxlmhuxftycgaqwh/auth/providers"
  );
}

async function enterAsGuest(event) {
  event.preventDefault();
  const username = cleanPlayerName(ui.usernameInput.value);
  if (username.length < 2 || username.length > 24) {
    showNotice("Username harus terdiri dari 2 sampai 24 karakter.", "warning");
    return;
  }
  setBusy(ui.enterButton, true, "Masuk…");
  clearNotice();
  setConnection("Menghubungkan");
  try {
    const session = await ensureGuestSession();
    sessionState.user = session.user;
    await savePlayerProfile(username);
    showWorkspace();
    setConnection("Terhubung", true);
    await refreshOpenRooms();
    await restoreRoom();
  } catch (error) {
    console.error("Guest entry failed:", error);
    if (error.needsAnonymousSetup) {
      showGuestSetupError();
      setConnection("Perlu pengaturan");
    } else {
      showNotice(errorMessage(error), "error");
      setConnection("Terputus");
    }
  } finally {
    setBusy(ui.enterButton, false);
  }
}

async function restoreExistingGuest() {
  if (!db) {
    showNotice("Library Supabase gagal dimuat. Muat ulang halaman.", "error");
    return;
  }
  try {
    const { data, error } = await db.auth.getSession();
    if (error) throw error;
    const session = data.session;
    if (!session || !session.user) return;

    sessionState.user = session.user;
    const { data: profile, error: profileError } = await db
      .from("profiles")
      .select("display_name")
      .eq("id", session.user.id)
      .maybeSingle();
    if (profileError) throw profileError;
    if (!profile || !profile.display_name) return;

    ui.usernameInput.value = profile.display_name;
    sessionState.username = profile.display_name;
    ui.playerName.textContent = profile.display_name;
    ui.playerAvatar.textContent = profile.display_name.slice(0, 1).toUpperCase();
    ui.playerPill.hidden = false;
    showWorkspace();
    setConnection("Terhubung", true);
    await refreshOpenRooms();
    await restoreRoom();
  } catch (error) {
    console.warn("Could not restore previous guest session:", error);
    setConnection("Perlu masuk ulang");
  }
}

async function refreshOpenRooms() {
  if (!sessionState.user) return;
  ui.roomList.replaceChildren();
  const loading = document.createElement("div");
  loading.className = "empty-state";
  loading.textContent = "Mencari meja…";
  ui.roomList.append(loading);

  const { data, error } = await db.rpc("list_open_rooms");
  if (error) {
    ui.roomList.replaceChildren();
    const message = document.createElement("div");
    message.className = "empty-state";
    message.textContent = errorMessage(error);
    ui.roomList.append(message);
    return;
  }

  const rooms = Array.isArray(data) ? data : [];
  ui.roomList.replaceChildren();
  if (!rooms.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "Belum ada meja terbuka. Buat meja baru atau masukkan kode undangan.";
    ui.roomList.append(empty);
    return;
  }

  for (const room of rooms) {
    const item = document.createElement("article");
    item.className = "room-item";

    const details = document.createElement("div");
    details.className = "room-item-details";
    const name = document.createElement("strong");
    name.textContent = "Meja " + room.host_name;
    const count = document.createElement("span");
    count.textContent = room.member_count + " / " + room.max_players + " pemain";
    details.append(name, count);

    const code = document.createElement("code");
    code.textContent = room.invite_code;

    const join = document.createElement("button");
    join.className = "small-join";
    join.type = "button";
    join.textContent = Number(room.member_count) >= Number(room.max_players) ? "Penuh" : "Gabung";
    join.disabled = Number(room.member_count) >= Number(room.max_players);
    join.addEventListener("click", () => joinRoom(room.invite_code, join));

    item.append(details, code, join);
    ui.roomList.append(item);
  }
}

async function createRoom(event) {
  event.preventDefault();
  if (!sessionState.user) return;
  setBusy(ui.createButton, true, "Membuat…");
  clearNotice();
  try {
    await savePlayerProfile(sessionState.username);
    const { data, error } = await db.rpc("create_room", {
      p_display_name: sessionState.username,
      p_max_players: Number(ui.maxPlayers.value)
    });
    if (error) throw error;
    await openRoom(data.room_id, data.invite_code);
    await refreshOpenRooms();
    showNotice("Meja berhasil dibuat. Bagikan kode undangan kepada teman.", "success");
  } catch (error) {
    console.error("Create room failed:", error);
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.createButton, false);
  }
}

async function joinRoom(code, button = ui.joinButton) {
  if (!sessionState.user) return;
  const normalizedCode = String(code || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(normalizedCode)) {
    showNotice("Kode undangan harus terdiri dari 6 huruf atau angka.", "warning");
    return;
  }
  setBusy(button, true, "Menggabungkan…");
  clearNotice();
  try {
    await savePlayerProfile(sessionState.username);
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
  sessionState.roomId = roomId;
  sessionState.roomCode = inviteCode;
  ui.lobby.hidden = false;
  const { data: room, error } = await db
    .from("rooms")
    .select("id,invite_code,host_id,max_players,status")
    .eq("id", roomId)
    .maybeSingle();
  if (error) throw error;
  if (!room) throw new Error("Meja tidak ditemukan atau akses sudah berakhir.");

  sessionState.roomMeta = room;
  sessionState.roomCode = room.invite_code;
  ui.lobbyCode.textContent = room.invite_code;
  ui.lobbyTitle.textContent = "Meja " + room.invite_code;
  ui.lobbySubtitle.textContent = room.status === "in_progress"
    ? "Permainan sedang berlangsung."
    : "Bagikan kode ini agar teman bisa bergabung.";
  await refreshLobby();
  if (room.status === "in_progress") await loadActiveGame();
  else ui.gameTable.hidden = true;
  subscribeToRoom();
}

async function restoreRoom() {
  if (!sessionState.user) return;
  const { data: membership, error } = await db.from("room_members")
    .select("room_id,joined_at")
    .eq("user_id", sessionState.user.id)
    .order("joined_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error || !membership) return;

  const { data: room, error: roomError } = await db.from("rooms")
    .select("id,invite_code,status")
    .eq("id", membership.room_id)
    .maybeSingle();
  if (roomError || !room || !["waiting", "in_progress"].includes(room.status)) return;
  await openRoom(room.id, room.invite_code);
}

async function refreshLobby() {
  if (!sessionState.roomId || !sessionState.user || !sessionState.roomMeta) return;
  const { data, error } = await db.rpc("get_room_lobby", { p_room_id: sessionState.roomId });
  if (error) {
    showNotice(errorMessage(error), "error");
    return;
  }

  sessionState.members = Array.isArray(data) ? data : [];
  const capacity = Number(sessionState.roomMeta.max_players || 5);
  ui.lobbyCount.textContent = sessionState.members.length + " / " + capacity + " pemain";
  ui.roster.replaceChildren();

  const current = sessionState.members.find((member) => member.user_id === sessionState.user.id);
  const isHost = sessionState.roomMeta.host_id === sessionState.user.id;
  const isWaiting = sessionState.roomMeta.status === "waiting";
  const allReady = sessionState.members.length >= 2 && sessionState.members.every((member) => member.is_ready);

  ui.readyButton.hidden = !isWaiting;
  ui.readyButton.disabled = !current || !isWaiting;
  ui.readyButton.textContent = current && current.is_ready ? "Batalkan siap" : "Saya siap";
  ui.readyButton.classList.toggle("is-ready", Boolean(current && current.is_ready));

  ui.startButton.hidden = !isWaiting || !isHost;
  ui.startButton.disabled = !allReady;
  ui.leaveButton.hidden = !isWaiting;

  for (let seat = 1; seat <= capacity; seat += 1) {
    const member = sessionState.members.find((entry) => Number(entry.seat_no) === seat);
    const row = document.createElement("div");
    row.className = member ? "roster-player" : "roster-player vacant";

    const seatNo = document.createElement("span");
    seatNo.className = "seat-number";
    seatNo.textContent = String(seat).padStart(2, "0");

    const name = document.createElement("strong");
    name.textContent = member ? member.display_name : "Kursi kosong";

    const status = document.createElement("span");
    if (!member) {
      status.className = "roster-state vacant-label";
      status.textContent = "BELUM TERISI";
    } else {
      const tags = [];
      if (member.user_id === sessionState.roomMeta.host_id) tags.push("HOST");
      if (member.user_id === sessionState.user.id) tags.push("KAMU");
      tags.push(member.is_ready ? "SIAP" : "BELUM SIAP");
      status.className = "roster-state " + (member.is_ready ? "ready" : "pending");
      status.textContent = tags.join(" · ");
    }
    row.append(seatNo, name, status);
    ui.roster.append(row);
  }

  if (!isWaiting) {
    ui.lobbyHint.textContent = "Permainan sudah dimulai. Papan permainan ada di bawah.";
  } else if (sessionState.members.length < 2) {
    ui.lobbyHint.textContent = "Butuh minimal dua pemain untuk memulai.";
  } else if (!allReady) {
    ui.lobbyHint.textContent = "Semua pemain yang bergabung harus menandai siap sebelum host memulai.";
  } else {
    ui.lobbyHint.textContent = isHost
      ? "Semua pemain siap. Host dapat memulai permainan."
      : "Semua pemain siap. Menunggu host memulai permainan.";
  }
}

async function syncRoomState() {
  if (!sessionState.roomId) return;
  const { data: room, error } = await db.from("rooms")
    .select("id,invite_code,host_id,max_players,status")
    .eq("id", sessionState.roomId)
    .maybeSingle();
  if (error || !room) return;
  sessionState.roomMeta = room;
  ui.lobbySubtitle.textContent = room.status === "in_progress"
    ? "Permainan sedang berlangsung."
    : "Bagikan kode ini agar teman bisa bergabung.";
  await refreshLobby();
  if (room.status === "in_progress") await loadActiveGame();
  else ui.gameTable.hidden = true;
  await refreshOpenRooms();
}

async function startGame() {
  if (!sessionState.roomId || !sessionState.user) return;
  setBusy(ui.startButton, true, "Memulai…");
  clearNotice();
  try {
    const { data, error } = await db.rpc("start_game", { p_room_id: sessionState.roomId });
    if (error) throw error;
    await syncRoomState();
    showNotice("Permainan dimulai. Papan awal dan modal pemain sudah disiapkan.", "success");
  } catch (error) {
    console.error("Start game failed:", error);
    showNotice(errorMessage(error), "error");
    await syncRoomState();
  } finally {
    setBusy(ui.startButton, false);
  }
}

async function loadActiveGame() {
  if (!sessionState.roomId || !sessionState.user) return;
  const { data: game, error } = await db.from("games")
    .select("id,room_id,current_round,phase,active_user_id,state,version")
    .eq("room_id", sessionState.roomId)
    .maybeSingle();
  if (error) {
    showNotice(errorMessage(error), "error");
    return;
  }
  if (!game) return;

  sessionState.game = game;
  const { data: privateRow, error: privateError } = await db.from("game_private_states")
    .select("private_state")
    .eq("game_id", game.id)
    .eq("user_id", sessionState.user.id)
    .maybeSingle();
  if (privateError) console.warn("Could not load private player state:", privateError);

  renderGame(game, privateRow ? privateRow.private_state : null);
}

function renderGame(game, privateState) {
  const state = game.state || {};
  const market = state.market || {};
  const players = Array.isArray(state.players) ? state.players : [];
  const coins = Number(privateState && privateState.coins);
  const shares = privateState && privateState.shares ? privateState.shares : {};
  const totalShares = Object.values(shares).reduce((sum, value) => sum + Number(value || 0), 0);

  ui.gameTable.hidden = false;
  ui.gameRound.textContent = String(game.current_round || 1).padStart(2, "0");
  ui.gamePhase.textContent = phaseName(game.phase);
  ui.gamePhaseDescription.textContent = game.phase === "bidding"
    ? "Pemain menentukan urutan bermain melalui penawaran tertutup."
    : "Permainan sedang berlangsung.";
  ui.gameSubtitle.textContent = "Meja " + sessionState.roomCode + " · " + players.length + " pemain";
  ui.gamePlayerCount.textContent = players.length + " pemain";

  ui.marketGrid.replaceChildren();
  for (const sector of SECTORS) {
    const cell = document.createElement("div");
    cell.className = "market-cell";
    const label = document.createElement("span");
    label.textContent = sector.name;
    const value = document.createElement("strong");
    value.textContent = String(Number(market[sector.id] || 5));
    cell.append(label, value);
    ui.marketGrid.append(cell);
  }

  ui.gamePlayers.replaceChildren();
  for (const player of players) {
    const card = document.createElement("div");
    card.className = "game-player";
    const name = document.createElement("strong");
    name.textContent = player.display_name + (player.user_id === sessionState.user.id ? " (Kamu)" : "");
    const meta = document.createElement("span");
    meta.textContent = "Kursi " + player.seat_no;
    card.append(name, meta);
    ui.gamePlayers.append(card);
  }

  ui.ownCoins.textContent = Number.isFinite(coins) ? String(coins) : "—";
  ui.ownShares.textContent = String(totalShares);
  ui.gameNote.textContent = "Sesi dan papan awal sudah dibuat. Tahap berikutnya adalah mengaktifkan bidding tertutup, pengambilan kartu aksi, fase jual, dan fase ekonomi. Saldo pemain lain tidak ditampilkan.";
}

function phaseName(phase) {
  return ({ bidding: "Bidding", action: "Aksi", sell: "Jual", economy: "Ekonomi", finished: "Selesai" })[phase] || phase;
}

function subscribeToRoom() {
  if (!sessionState.roomId || !db) return;
  if (sessionState.channel) db.removeChannel(sessionState.channel);

  const roomId = sessionState.roomId;
  sessionState.channel = db
    .channel("stocklab-room-" + roomId)
    .on("postgres_changes", {
      event: "*", schema: "public", table: "room_members", filter: "room_id=eq." + roomId
    }, async () => {
      await syncRoomState();
    })
    .on("postgres_changes", {
      event: "UPDATE", schema: "public", table: "rooms", filter: "id=eq." + roomId
    }, async () => {
      await syncRoomState();
    })
    .on("postgres_changes", {
      event: "*", schema: "public", table: "games", filter: "room_id=eq." + roomId
    }, async () => {
      await loadActiveGame();
    })
    .subscribe((status) => {
      if (status === "SUBSCRIBED") setConnection("Terhubung", true);
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") setConnection("Menghubungkan ulang");
    });
}

async function toggleReady() {
  if (!sessionState.roomId || !sessionState.user || sessionState.roomMeta.status !== "waiting") return;
  const current = sessionState.members.find((member) => member.user_id === sessionState.user.id);
  if (!current) return;

  setBusy(ui.readyButton, true, "Menyimpan…");
  try {
    const { error } = await db.from("room_members")
      .update({ is_ready: !current.is_ready })
      .eq("room_id", sessionState.roomId)
      .eq("user_id", sessionState.user.id);
    if (error) throw error;
    await refreshLobby();
  } catch (error) {
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.readyButton, false);
  }
}

async function leaveRoom() {
  if (!sessionState.roomId) return;
  setBusy(ui.leaveButton, true, "Keluar…");
  try {
    const { error } = await db.rpc("leave_room", { p_room_id: sessionState.roomId });
    if (error) throw error;
    if (sessionState.channel) {
      await db.removeChannel(sessionState.channel);
      sessionState.channel = null;
    }
    sessionState.roomId = null;
    sessionState.roomCode = "";
    sessionState.roomMeta = null;
    sessionState.members = [];
    sessionState.game = null;
    ui.lobby.hidden = true;
    ui.gameTable.hidden = true;
    setConnection("Terhubung", true);
    await refreshOpenRooms();
  } catch (error) {
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.leaveButton, false);
  }
}

ui.enterForm.addEventListener("submit", enterAsGuest);
ui.createForm.addEventListener("submit", createRoom);
ui.joinForm.addEventListener("submit", (event) => {
  event.preventDefault();
  joinRoom(ui.joinInput.value);
});
ui.refreshRooms.addEventListener("click", refreshOpenRooms);
ui.readyButton.addEventListener("click", toggleReady);
ui.startButton.addEventListener("click", startGame);
ui.leaveButton.addEventListener("click", leaveRoom);
ui.copyCode.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(sessionState.roomCode);
    ui.copyCode.textContent = "Tersalin";
    window.setTimeout(() => { ui.copyCode.textContent = "Salin kode"; }, 1500);
  } catch (_) {
    showNotice("Salin kode secara manual: " + sessionState.roomCode, "info");
  }
});

const rememberedName = localStorage.getItem("stocklab_guest_username");
if (rememberedName) ui.usernameInput.value = rememberedName;
if (!db) {
  showNotice("Library Supabase gagal dimuat. Periksa koneksi lalu muat ulang halaman.", "error");
  setConnection("Gagal dimuat");
} else {
  restoreExistingGuest();
}
