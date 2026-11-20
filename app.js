// StockLab Online — room-first multiplayer interface and six-round digital game engine.
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
  welcome: byId("home"), multiplayer: byId("multiplayer"),
  enterForm: byId("enter-form"), usernameInput: byId("username-input"), enterButton: byId("enter-button"),
  guestEntry: byId("guest-entry"), workspace: byId("room-workspace"), locked: byId("workspace-locked"),
  notice: byId("app-notice"), connection: byId("connection-indicator"),
  playerPill: byId("player-pill"), playerAvatar: byId("player-avatar"), playerName: byId("player-name-label"),
  roomHub: byId("room-hub"), roomModeGrid: byId("room-mode-grid"),
  showCreatePanel: byId("show-create-panel"), showJoinPanel: byId("show-join-panel"),
  createPanel: byId("create-room-panel"), backFromCreate: byId("back-from-create"),
  joinPanel: byId("join-room-panel"), backFromJoin: byId("back-from-join"),
  createForm: byId("create-room-form"), createButton: byId("create-room-button"),
  maxPlayers: byId("max-players"), createPassword: byId("create-password"),
  createBiddingSeconds: byId("create-bidding-seconds"), createTurnSeconds: byId("create-turn-seconds"),
  createIdleMinutes: byId("create-idle-minutes"),
  joinForm: byId("join-room-form"), joinInput: byId("room-code-input"),
  joinPassword: byId("join-password"), joinButton: byId("join-room-button"),
  roomList: byId("room-list"), refreshRooms: byId("refresh-rooms"),
  lobby: byId("room-lobby"), lobbyTitle: byId("lobby-title"), lobbySubtitle: byId("lobby-subtitle"),
  lobbyCode: byId("lobby-code"), lobbyCount: byId("lobby-count"), roster: byId("player-roster"),
  lobbyHint: byId("lobby-hint"), copyCode: byId("copy-code-button"), readyButton: byId("ready-button"),
  startButton: byId("start-game-button"), leaveButton: byId("leave-room-button"),
  roomSettingsForm: byId("room-settings-form"), lobbyBiddingSeconds: byId("lobby-bidding-seconds"),
  lobbyTurnSeconds: byId("lobby-turn-seconds"), lobbyIdleMinutes: byId("lobby-idle-minutes"),
  saveRoomSettings: byId("save-room-settings"),
  gameTable: byId("game-table"), gameSubtitle: byId("game-subtitle"), gameRound: byId("game-round"),
  gamePhase: byId("game-phase"), gamePhaseDescription: byId("game-phase-description"),
  phaseTimer: byId("phase-timer"), leaveGameButton: byId("leave-game-button"),
  gamePlayerSeats: byId("game-player-seats"),
  marketGrid: byId("market-grid"), mutualFundPrice: byId("mutual-fund-price"),
  mutualFundBoard: byId("mutual-fund-board"),
  gamePlayers: byId("game-players"), gamePlayerCount: byId("game-player-count"),
  ownCoins: byId("own-coins"), ownShares: byId("own-shares"), ownDebt: byId("own-debt"),
  debtButton: byId("debt-button"), debtForm: byId("debt-form"),
  debtSector: byId("debt-sector"), debtSubmit: byId("debt-submit"),
  privatePeek: byId("private-peek"), economyEffectSummary: byId("economy-effect-summary"),
  phaseControls: byId("phase-controls"), actionMarketSection: byId("action-market-section"),
  actionMarket: byId("action-market"), actionMarketCount: byId("action-market-count"),
  economySection: byId("economy-section"), economyReveal: byId("economy-reveal"),
  finalSection: byId("final-section"), finalScores: byId("final-scores"), gameNote: byId("game-note")
};

const sessionState = {
  user: null, username: "", roomId: null, roomCode: "", roomMeta: null,
  members: [], gameView: null, channel: null, gameLoadSeq: 0,
  phaseTimerHandle: null, autoTimeoutPending: false
};

const SECTORS = [
  { id: "finance", name: "Keuangan" },
  { id: "consumer", name: "Konsumer" },
  { id: "agriculture", name: "Agrikultur" },
  { id: "mining", name: "Tambang" }
];
const SHARE_KEYS = [...SECTORS.map((sector) => sector.id), "mutual_fund"];

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
    if (!button.dataset.originalText) button.dataset.originalText = button.textContent;
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

function makeElement(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined && text !== null) el.textContent = String(text);
  return el;
}

function addOption(select, value, label) {
  const option = document.createElement("option");
  option.value = value;
  option.textContent = label;
  select.append(option);
}

function makeSelect(options, selected) {
  const select = document.createElement("select");
  select.className = "game-input";
  for (const option of options) addOption(select, option.value, option.label);
  if (selected !== undefined) select.value = String(selected);
  return select;
}

function makeField(labelText, control) {
  const wrapper = document.createElement("label");
  wrapper.className = "game-field";
  wrapper.append(makeElement("span", "", labelText), control);
  return wrapper;
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
  if (cleanName.length < 2 || cleanName.length > 24) throw new Error("Username harus terdiri dari 2 sampai 24 karakter.");
  const { error } = await db.from("profiles").upsert({
    id: sessionState.user.id, display_name: cleanName, updated_at: new Date().toISOString()
  }, { onConflict: "id" });
  if (error) throw error;
  sessionState.username = cleanName;
  localStorage.setItem("stocklab_guest_username", cleanName);
  ui.playerName.textContent = cleanName;
  ui.playerAvatar.textContent = cleanName.slice(0, 1).toUpperCase();
  ui.playerPill.hidden = false;
  return cleanName;
}

function showRoomHub() {
  ui.roomHub.hidden = false;
  ui.roomModeGrid.hidden = false;
  ui.createPanel.hidden = true;
  ui.joinPanel.hidden = true;
  ui.lobby.hidden = true;
  ui.gameTable.hidden = true;
}
function openCreatePanel() {
  ui.roomModeGrid.hidden = true;
  ui.createPanel.hidden = false;
  ui.joinPanel.hidden = true;
  ui.createPassword.value = "";
}
function openJoinPanel(code = "") {
  ui.roomModeGrid.hidden = true;
  ui.createPanel.hidden = true;
  ui.joinPanel.hidden = false;
  ui.joinInput.value = String(code || "").toUpperCase();
  ui.joinPassword.value = "";
  if (code) ui.joinPassword.focus();
}
function showWorkspace() {
  ui.welcome.hidden = true;
  ui.multiplayer.hidden = false;
  ui.guestEntry.hidden = true;
  ui.workspace.hidden = false;
  ui.locked.hidden = true;
  showRoomHub();
}

function showGuestSetupError() {
  showNotice(
    "Pemain tamu memerlukan Anonymous Sign-Ins yang aktif. Pastikan pengaturan itu sudah disimpan di Supabase.",
    "warning", "Buka pengaturan Auth",
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
    const { data: profile, error: profileError } = await db.from("profiles")
      .select("display_name").eq("id", session.user.id).maybeSingle();
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
  ui.roomList.replaceChildren(makeElement("div", "empty-state", "Mencari meja…"));
  const { data, error } = await db.rpc("list_open_rooms");
  if (error) {
    ui.roomList.replaceChildren(makeElement("div", "empty-state", errorMessage(error)));
    return;
  }
  const rooms = Array.isArray(data) ? data : [];
  ui.roomList.replaceChildren();
  if (!rooms.length) {
    ui.roomList.append(makeElement("div", "empty-state", "Belum ada meja terbuka. Buat meja baru atau masukkan kode undangan."));
    return;
  }
  for (const room of rooms) {
    const item = makeElement("article", "room-item");
    const details = makeElement("div", "room-item-details");
    details.append(makeElement("strong", "", "Meja " + room.host_name));
    details.append(makeElement("span", "", room.member_count + " / " + room.max_players + " pemain"));
    const code = makeElement("code", "", room.invite_code);
    const join = makeElement("button", "small-join", Number(room.member_count) >= Number(room.max_players) ? "Penuh" : "Gabung");
    join.type = "button";
    join.disabled = Number(room.member_count) >= Number(room.max_players);
    join.addEventListener("click", () => openJoinPanel(room.invite_code));
    item.append(details, code, join);
    ui.roomList.append(item);
  }
}

async function createRoom(event) {
  event.preventDefault();
  if (!sessionState.user) return;
  const password = String(ui.createPassword.value || "");
  if (password.length < 6 || password.length > 32) {
    showNotice("Password room harus 6–32 karakter.", "warning");
    return;
  }
  setBusy(ui.createButton, true, "Membuat room…");
  clearNotice();
  try {
    await savePlayerProfile(sessionState.username);
    const { data, error } = await db.rpc("create_room", {
      p_display_name: sessionState.username,
      p_max_players: Number(ui.maxPlayers.value),
      p_password: password,
      p_bidding_seconds: Number(ui.createBiddingSeconds.value),
      p_turn_seconds: Number(ui.createTurnSeconds.value),
      p_idle_timeout_minutes: Number(ui.createIdleMinutes.value)
    });
    if (error) throw error;
    ui.createPassword.value = "";
    await openRoom(data.room_id, data.invite_code);
    await refreshOpenRooms();
    showNotice("Room siap. Bagikan kode dan password kepada teman satu meja.", "success");
  } catch (error) {
    console.error("Create room failed:", error);
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.createButton, false);
  }
}

async function joinRoom(code, password, button = ui.joinButton) {
  if (!sessionState.user) return;
  const normalizedCode = String(code || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(normalizedCode)) {
    showNotice("Kode room harus terdiri dari 6 huruf atau angka.", "warning");
    return;
  }
  if (!password || String(password).length < 6 || String(password).length > 32) {
    showNotice("Masukkan password room (6–32 karakter).", "warning");
    return;
  }
  setBusy(button, true, "Masuk room…");
  clearNotice();
  try {
    await savePlayerProfile(sessionState.username);
    const { data, error } = await db.rpc("join_room_by_code", {
      p_code: normalizedCode,
      p_password: String(password)
    });
    if (error) throw error;
    ui.joinPassword.value = "";
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
  const { data: room, error } = await db.from("rooms")
    .select("id,invite_code,host_id,max_players,status,bidding_seconds,turn_seconds,idle_timeout_minutes,last_activity_at")
    .eq("id", roomId).maybeSingle();
  if (error) throw error;
  if (!room) throw new Error("Room tidak ditemukan atau akses sudah berakhir.");
  sessionState.roomMeta = room;
  sessionState.roomCode = room.invite_code;
  ui.roomHub.hidden = true;
  ui.lobby.hidden = room.status === "in_progress";
  ui.gameTable.hidden = room.status === "waiting";
  ui.lobbyCode.textContent = room.invite_code;
  ui.lobbyTitle.textContent = "Room " + room.invite_code;
  ui.lobbySubtitle.textContent = room.status === "waiting"
    ? "Bagikan kode dan password room kepada teman."
    : room.status === "finished" ? "Permainan selesai." : "Permainan sedang berlangsung.";
  if (room.status === "waiting" || room.status === "finished") await refreshLobby();
  if (room.status === "in_progress" || room.status === "finished") await loadActiveGame();
  subscribeToRoom();
}

async function restoreRoom() {
  if (!sessionState.user) return;
  const { data: membership, error } = await db.from("room_members")
    .select("room_id,joined_at").eq("user_id", sessionState.user.id)
    .order("joined_at", { ascending: false }).limit(1).maybeSingle();
  if (error || !membership) return;
  const { data: room, error: roomError } = await db.from("rooms")
    .select("id,invite_code,status").eq("id", membership.room_id).maybeSingle();
  if (roomError || !room || !["waiting", "in_progress", "finished"].includes(room.status)) return;
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
  const isFinished = sessionState.roomMeta.status === "finished";
  ui.leaveButton.hidden = !(isWaiting || isFinished);
  ui.leaveButton.textContent = isFinished ? "Kembali ke lobi" : "Keluar";
  ui.roomSettingsForm.hidden = !isHost || !isWaiting;
  ui.lobbyBiddingSeconds.value = String(sessionState.roomMeta.bidding_seconds || 90);
  ui.lobbyTurnSeconds.value = String(sessionState.roomMeta.turn_seconds || 45);
  ui.lobbyIdleMinutes.value = String(sessionState.roomMeta.idle_timeout_minutes || 30);

  for (let seat = 1; seat <= capacity; seat += 1) {
    const member = sessionState.members.find((entry) => Number(entry.seat_no) === seat);
    const row = makeElement("div", member ? "roster-player" : "roster-player vacant");
    const seatNo = makeElement("span", "seat-number", String(seat).padStart(2, "0"));
    const name = makeElement("strong", "", member ? member.display_name : "Kursi kosong");
    const status = makeElement("span");
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

  if (!isWaiting) ui.lobbyHint.textContent = "Permainan sudah dimulai.";
  else if (sessionState.members.length < 2) ui.lobbyHint.textContent = "Butuh minimal dua pemain untuk memulai.";
  else if (!allReady) ui.lobbyHint.textContent = "Semua pemain yang bergabung harus menandai siap sebelum host memulai.";
  else ui.lobbyHint.textContent = isHost ? "Semua pemain siap. Host dapat memulai permainan." : "Semua pemain siap. Menunggu host memulai permainan.";
}

async function syncRoomState() {
  if (!sessionState.roomId) return;
  const { data: room, error } = await db.from("rooms")
    .select("id,invite_code,host_id,max_players,status,bidding_seconds,turn_seconds,idle_timeout_minutes,last_activity_at")
    .eq("id", sessionState.roomId).maybeSingle();
  if (error || !room) return;
  sessionState.roomMeta = room;
  ui.lobbySubtitle.textContent = room.status === "waiting"
    ? "Bagikan kode dan password room kepada teman."
    : room.status === "finished" ? "Permainan selesai." : "Permainan sedang berlangsung.";
  ui.roomHub.hidden = true;
  ui.lobby.hidden = room.status === "in_progress";
  ui.gameTable.hidden = room.status === "waiting";
  if (room.status === "waiting" || room.status === "finished") await refreshLobby();
  if (room.status === "in_progress" || room.status === "finished") await loadActiveGame();
  await refreshOpenRooms();
}

async function startGame() {
  if (!sessionState.roomId || !sessionState.user) return;
  setBusy(ui.startButton, true, "Memulai…");
  clearNotice();
  try {
    const { error } = await db.rpc("start_game", { p_room_id: sessionState.roomId });
    if (error) throw error;
    await syncRoomState();
  } catch (error) {
    console.error("Start game failed:", error);
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.startButton, false);
  }
}

async function loadActiveGame() {
  if (!sessionState.roomId || !sessionState.user) return;
  const loadId = ++sessionState.gameLoadSeq;
  const { data, error } = await db.rpc("get_game_view", { p_room_id: sessionState.roomId });
  if (loadId !== sessionState.gameLoadSeq) return;
  if (error) {
    showNotice(errorMessage(error), "error");
    return;
  }
  if (!data) return;
  sessionState.gameView = data;
  renderGame(data);
}

function renderMarket(market, state) {
  ui.marketGrid.replaceChildren();
  const remaining = economyCardsRemaining(state);
  for (const sector of SECTORS) {
    const cell = makeElement("article", "market-cell market-board-card");
    const heading = makeElement("div", "market-card-heading");
    heading.append(makeElement("strong", "", sector.name));
    heading.append(makeElement("span", "deck-count", remaining > 0 ? "×" + remaining + " kartu" : "Tumpukan habis"));
    const artWrap = makeElement("div", "market-board-art");
    appendCardImage(
      artWrap,
      sectorBoardAsset(sector.id),
      "Papan sektor " + sector.name + " dengan tumpukan kartu ekonomi",
      "market-board-image"
    );
    const price = makeElement("div", "market-price-chip");
    price.append(makeElement("span", "", "HARGA SAHAM"));
    price.append(makeElement("strong", "", String(Number(market[sector.id] || 5))));
    cell.append(heading, artWrap, price);
    ui.marketGrid.append(cell);
  }

  const pair = Array.isArray(state && state.mutual_fund_pair) && state.mutual_fund_pair.length === 2
    ? state.mutual_fund_pair : ["consumer", "agriculture"];
  const leftSector = SECTORS.find((item) => item.id === pair[0]) || SECTORS[0];
  const rightSector = SECTORS.find((item) => item.id === pair[1]) || SECTORS[1];
  const price = Math.floor((Number(market[leftSector.id] || 0) + Number(market[rightSector.id] || 0)) / 2);
  if (ui.mutualFundPrice) ui.mutualFundPrice.textContent = String(price);
  if (ui.mutualFundBoard) {
    ui.mutualFundBoard.replaceChildren();
    const linkedStock = (sector, side) => {
      const panel = makeElement("article", "mf-linked-stock " + side);
      appendCardImage(panel, sectorBoardAsset(sector.id), "Kartu saham " + sector.name + " penentu Reksa Dana", "mf-linked-stock-image");
      panel.append(makeElement("strong", "", sector.name));
      panel.append(makeElement("span", "", "Harga " + Number(market[sector.id] || 0)));
      return panel;
    };
    ui.mutualFundBoard.append(linkedStock(leftSector, "left"));
    const center = makeElement("div", "mutual-fund-center");
    const artwork = makeElement("div", "mutual-fund-center-art");
    appendCardImage(artwork, "./assets/cards/boards/papan-reksa-dana.webp", "Papan Reksa Dana StockLab vertikal", "mutual-fund-center-image");
    center.append(artwork, makeElement("span", "mutual-fund-center-label", "HARGA UNIT"), makeElement("strong", "mutual-fund-center-price", String(price)));
    ui.mutualFundBoard.append(center, linkedStock(rightSector, "right"));
  }
}

function renderGameSeats(players, view, privateState) {
  ui.gamePlayerSeats.replaceChildren();
  const byOrder = [...players].sort((a, b) => Number(a.order_no) - Number(b.order_no));
  const ownIndex = Math.max(0, byOrder.findIndex((player) => player.user_id === sessionState.user.id));
  const rotated = byOrder.slice(ownIndex).concat(byOrder.slice(0, ownIndex));
  const positions = {
    2: ["bottom", "top"],
    3: ["bottom", "top-left", "top-right"],
    4: ["bottom", "left", "top", "right"],
    5: ["bottom", "left", "top-left", "top-right", "right"]
  }[rotated.length] || ["bottom", "left", "top", "right", "top-left"];
  for (let index = 0; index < rotated.length; index += 1) {
    const player = rotated[index];
    const isOwn = player.user_id === sessionState.user.id;
    const isTurn = player.user_id === view.active_user_id;
    const seat = makeElement("article", "game-player-seat seat-" + positions[index] +
      (isOwn ? " is-you" : "") + (isTurn ? " is-active-turn" : ""));
    const avatar = makeElement("span", "seat-avatar", String(player.display_name || "P").slice(0, 1).toUpperCase());
    const identity = makeElement("div", "seat-identity");
    identity.append(makeElement("strong", "", player.display_name || "Pemain"));
    const tags = [];
    if (player.is_host || player.user_id === sessionState.roomMeta?.host_id) tags.push("HOST");
    if (isOwn) tags.push("KAMU");
    if (isTurn) tags.push("GILIRAN");
    if (tags.length) identity.append(makeElement("small", "seat-tags", tags.join(" · ")));
    const shares = player.shares || {};
    const stockCount = SECTORS.reduce((sum, sector) => sum + Number(shares[sector.id] || 0), 0);
    const assets = makeElement("div", "seat-assets");
    assets.append(makeElement("span", "", stockCount + " saham"));
    assets.append(makeElement("span", "", Number(shares.mutual_fund || 0) + " RD"));
    if (isOwn) assets.append(makeElement("span", "seat-own-coins", Number(privateState.coins || 0) + " koin"));
    seat.append(avatar, identity, assets);
    ui.gamePlayerSeats.append(seat);
  }
}

function renderPortfolio(players) {
  ui.gamePlayers.replaceChildren();
  const labels = {
    finance: "Keuangan", consumer: "Konsumer", agriculture: "Agrikultur",
    mining: "Tambang", mutual_fund: "Reksa Dana"
  };
  for (const player of players) {
    const isTurn = player.user_id === (sessionState.gameView && sessionState.gameView.active_user_id);
    const row = makeElement("tr", isTurn ? "portfolio-active-player" : "");
    const name = makeElement("td", "", player.display_name + (player.user_id === sessionState.user.id ? " (kamu)" : ""));
    const order = " · Urutan " + player.order_no;
    name.textContent += order;
    row.append(name);
    for (const key of SHARE_KEYS) row.append(makeElement("td", "", Number(player.shares && player.shares[key] || 0)));
    ui.gamePlayers.append(row);
  }
}

function renderEconomyLast(state) {
  ui.economyReveal.replaceChildren();
  const items = Array.isArray(state.last_economy) ? state.last_economy : [];
  if (!items.length) {
    ui.economyReveal.append(makeElement("p", "muted-text", "Belum ada kartu ekonomi yang dibuka."));
    return;
  }
  for (const item of items) {
    const card = makeElement("article", "economy-card is-revealed");
    const economy = item.card || {};
    appendCardImage(card, economyCardAsset(economy), economy.name || "Kartu ekonomi StockLab", "economy-card-image");
    const title = makeElement("strong", "", economy.name || "Kartu ekonomi");
    const subtitle = makeElement("span", "", "Tumpukan " + sectorName(item.stack_sector));
    const body = makeElement("p", "", economy.body || "");
    card.append(title, subtitle, body);
    const effects = Array.isArray(item.effects) ? item.effects : [];
    for (const effect of effects) {
      const parts = [];
      const hasPriceChange = Number.isFinite(Number(effect.old_price)) &&
        Number.isFinite(Number(effect.new_price));
      if (hasPriceChange) {
        parts.push(sectorName(effect.sector) + ": " + effect.old_price + " → " + effect.new_price);
      } else if (effect.sector) {
        parts.push(sectorName(effect.sector));
      }
      if (effect.outcome && effect.outcome !== "normal") {
        parts.push(String(effect.outcome).replaceAll("_", " "));
      }
      if (effect.message) parts.push(effect.message);
      if (parts.length) card.append(makeElement("small", "economy-effect", parts.join(" · ")));
    }
    ui.economyReveal.append(card);
  }
}

function sectorName(id) {
  if (id === "mutual_fund") return "Reksa Dana";
  const item = SECTORS.find((sector) => sector.id === id);
  return item ? item.name : String(id || "—");
}

const CARD_ASSET_ROOT = "./assets/cards";
const SECTOR_ASSET_SLUGS = {
  finance: "keuangan",
  consumer: "consumer",
  agriculture: "agrikultur",
  mining: "tambang",
  mutual_fund: "reksa-dana"
};
const ACTION_ASSET_SLUGS = {
  "info-bursa": "info-bursa",
  rumor: "rumor",
  quickbuy: "quickbuy",
  "trading-fee": "trading-fee",
  acquisition: "akuisisi"
};
const ECONOMY_ASSET_SLUGS = {
  issue: "penerbitan-saham-baru",
  tax_amnesty: "tax-amnesty",
  buyback: "buyback",
  extra_fee: "extra-fee",
  merger: "merger",
  recession: "resesi",
  restructure: "restrukturisasi-ekonomi",
  stimulus: "stimulus-ekonomi",
  road_tax: "pajak-jalan",
  world_oil: "world-oil-regulation",
  dividend: "dividen",
  sideways: "sideways"
};
const MOVEMENT_ASSETS = { 1: "naik", 2: "melaju", 3: "boom", "-1": "anjlok", "-2": "terjun", "-3": "crash" };
const ECONOMY_BOARD_ASSETS = {
  finance: "back-ekonomi-keuangan",
  consumer: "back-ekonomi-consumer",
  agriculture: "back-ekonomi-agrikultur",
  mining: "back-ekonomi-tambang"
};

function sectorBoardAsset(sectorId) {
  const slug = ECONOMY_BOARD_ASSETS[sectorId];
  return slug ? CARD_ASSET_ROOT + "/boards/" + slug + ".webp" : CARD_ASSET_ROOT + "/components/stocklab-back-dark.webp";
}

function actionCardAsset(card) {
  const sector = SECTOR_ASSET_SLUGS[card && card.sector];
  const action = ACTION_ASSET_SLUGS[card && card.action];
  return sector && action ? CARD_ASSET_ROOT + "/action/" + sector + "-" + action + ".webp" : CARD_ASSET_ROOT + "/components/stocklab-back-dark.webp";
}

function economyCardAsset(card) {
  if (!card) return CARD_ASSET_ROOT + "/components/stocklab-back-dark.webp";
  const slug = card.effect === "movement"
    ? MOVEMENT_ASSETS[String(Number(card.delta))]
    : ECONOMY_ASSET_SLUGS[card.effect];
  return slug ? CARD_ASSET_ROOT + "/economy/" + slug + ".webp" : CARD_ASSET_ROOT + "/components/stocklab-back-dark.webp";
}

function appendCardImage(parent, src, alt, className) {
  const image = makeElement("img", className || "stocklab-card-image");
  image.src = src;
  image.alt = alt || "Kartu StockLab";
  image.loading = "lazy";
  image.decoding = "async";
  image.addEventListener("error", () => {
    image.replaceWith(makeElement("div", "card-image-fallback", alt || "Visual kartu belum tersedia"));
  }, { once: true });
  parent.append(image);
  return image;
}

function economyCardsRemaining(state) {
  if (!state || state.phase === "finished") return 0;
  return Math.max(0, 7 - Number(state.round || 1));
}

function currentPlayer(view) {
  const players = view.state && Array.isArray(view.state.players) ? view.state.players : [];
  return players.find((player) => player.user_id === sessionState.user.id) || null;
}

function renderGame(view) {
  const state = view.state || {};
  const market = state.market || {};
  const players = Array.isArray(state.players) ? state.players : [];
  const own = currentPlayer(view);
  const privateState = view.my_private_state || {};
  const coins = Number(privateState.coins || 0);
  const shares = own && own.shares ? own.shares : {};
  const totalShares = SHARE_KEYS.reduce((sum, key) => sum + Number(shares[key] || 0), 0);
  const debt = Number(privateState.debt || 0);

  ui.gameTable.hidden = false;
  ui.gameRound.textContent = String(view.current_round || 1).padStart(2, "0");
  ui.gamePhase.textContent = phaseName(view.phase);
  renderPhaseTimer(view);
  renderGameSeats(players, view, privateState);
  ui.gameSubtitle.textContent = "Meja " + sessionState.roomCode + " · " + players.length + " pemain";
  ui.gamePhaseDescription.textContent = phaseDescription(view, state);
  ui.ownCoins.textContent = String(coins);
  ui.ownShares.textContent = String(totalShares);
  ui.ownDebt.textContent = debt > 0 ? debt + " kartu utang · penalti akhir " + (debt * 13) : "Tanpa utang";
  ui.gamePlayerCount.textContent = players.length + " pemain";
  renderMarket(market, { ...state, phase: view.phase, round: view.current_round });
  renderPortfolio(players);
  renderEconomyLast(state);

  const canFlipShare = SECTORS.some((sector) => Number(shares[sector.id] || 0) > 0);
  const debtAvailable = view.phase !== "finished" && debt < 1 && canFlipShare;
  ui.debtButton.hidden = !debtAvailable;
  ui.debtButton.disabled = !debtAvailable;
  if (!debtAvailable) ui.debtForm.hidden = true;
  if (ui.economyEffectSummary) {
    const messages = Array.isArray(state.last_economy_effects) ? state.last_economy_effects : [];
    ui.economyEffectSummary.replaceChildren();
    for (const effect of messages) {
      if (effect.message) ui.economyEffectSummary.append(makeElement("p", "muted-text", effect.message));
    }
    ui.economyEffectSummary.hidden = messages.length === 0;
  }
  ui.actionMarketSection.hidden = view.phase !== "action";
  ui.economySection.hidden = !(Array.isArray(state.last_economy) && state.last_economy.length);
  ui.finalSection.hidden = view.phase !== "finished";
  ui.actionMarketCount.textContent = Array.isArray(state.action_market) ? state.action_market.length + " kartu tersisa" : "";

  ui.privatePeek.replaceChildren();
  const peek = Array.isArray(privateState.peek) ? privateState.peek : [];
  if (peek.length) {
    ui.privatePeek.hidden = false;
    ui.privatePeek.append(makeElement("strong", "", "Intip kartu ekonomi (hanya kamu)"));
    for (const item of peek) {
      const card = item.card || {};
      ui.privatePeek.append(makeElement("p", "", sectorName(item.sector) + " · " + (card.name || "Kartu") + ": " + (card.body || "")));
    }
  } else {
    ui.privatePeek.hidden = true;
  }

  if (view.phase === "finished") {
    renderFinalScores(state);
  } else {
    ui.finalSection.hidden = true;
  }
  renderPhaseControls(view, own, coins);
  if (view.phase === "action") renderActionMarket(view, own);
  else ui.actionMarket.replaceChildren();

  ui.gameNote.textContent = "Saldo pribadi hanya terlihat oleh pemiliknya. Deck kartu ekonomi dan aksi di versi ini merupakan adaptasi digital komunitas, bukan komposisi resmi yang telah diverifikasi.";
}

function phaseName(phase) {
  return ({ bidding: "Bidding", action: "Aksi", sell: "Jual", economy: "Ekonomi", finished: "Selesai" })[phase] || phase;
}

function renderPhaseTimer(view) {
  if (sessionState.phaseTimerHandle) {
    window.clearInterval(sessionState.phaseTimerHandle);
    sessionState.phaseTimerHandle = null;
  }
  sessionState.autoTimeoutPending = false;
  const deadline = view.phase_deadline ? new Date(view.phase_deadline).getTime() : 0;
  if (!deadline || view.phase === "finished") {
    ui.phaseTimer.textContent = "—";
    return;
  }
  const tick = async () => {
    const remainingMs = Math.max(0, deadline - Date.now());
    const totalSeconds = Math.ceil(remainingMs / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    ui.phaseTimer.textContent = minutes + ":" + String(seconds).padStart(2, "0");
    ui.phaseTimer.classList.toggle("is-expired", remainingMs <= 0);
    if (remainingMs <= 0 && !sessionState.autoTimeoutPending && sessionState.roomId) {
      sessionState.autoTimeoutPending = true;
      try {
        const { error } = await db.rpc("advance_expired_turn", { p_room_id: sessionState.roomId });
        if (error) throw error;
        await loadActiveGame();
      } catch (error) {
        const message = errorMessage(error);
        if (!/deadline|expired|not a room member/i.test(message)) {
          console.warn("Auto phase advance:", error);
        }
        sessionState.autoTimeoutPending = false;
      }
    }
  };
  tick();
  sessionState.phaseTimerHandle = window.setInterval(tick, 1000);
}

function phaseDescription(view, state) {
  if (view.phase === "bidding") return "Ajukan penawaran koin secara tertutup untuk menentukan urutan pemain.";
  if (view.phase === "action") return state.phase_status === "drafting" ? "Ambil satu kartu secara bergiliran: simpan sebagai saham atau aktifkan efeknya." : "Fase aksi.";
  if (view.phase === "sell") return "Setiap pemain mendapat satu kesempatan untuk menjual satu jenis saham atau melewati fase jual.";
  if (view.phase === "economy") return "Host membuka satu kartu dari setiap tumpukan ekonomi.";
  return "Permainan telah selesai. Periksa skor akhir dan pemenang.";
}

function renderPhaseControls(view, own, coins) {
  ui.phaseControls.replaceChildren();
  const state = view.state || {};
  const isActive = view.active_user_id === sessionState.user.id;

  if (view.phase === "bidding") {
    const panel = makeElement("div", "phase-panel");
    panel.append(makeElement("h4", "", "Penawaran tertutup"));
    panel.append(makeElement("p", "muted-text", "Masukkan jumlah koin (minimal 1). Penawaran pemain lain tidak akan terlihat sebelum semua pemain mengirim penawaran."));
    const status = view.bidding || {};
    panel.append(makeElement("p", "turn-status", status.submitted
      ? "Penawaranmu sudah terkirim. Menunggu pemain lain (" + status.submitted_count + "/" + status.player_count + ")."
      : "Penawaran diterima: " + status.submitted_count + "/" + status.player_count + "."));
    if (!status.submitted) {
      const form = makeElement("form", "inline-game-form");
      const bidInput = document.createElement("input");
      bidInput.type = "number"; bidInput.min = "1"; bidInput.max = String(coins);
      bidInput.step = "1"; bidInput.value = String(Math.min(1,coins));
      bidInput.required = true; bidInput.className = "game-input"; bidInput.disabled = coins < 1;
      form.append(makeField("Tawaran (koin)", bidInput));
      const submit = makeElement("button", "button primary", "Kirim penawaran");
      submit.type = "submit"; submit.disabled = coins < 1;
      form.append(submit);
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const amount = Number(bidInput.value);
        if (!Number.isInteger(amount) || amount < 1 || amount > coins) {
          showNotice("Penawaran harus bilangan bulat dari 1 sampai saldo koinmu.", "warning");
          return;
        }
        setBusy(submit,true,"Mengirim…");
        await runGameAction(() => db.rpc("submit_bid", {
          p_room_id:sessionState.roomId,p_bid_amount:amount
        }), "Penawaran terkirim.");
        setBusy(submit,false);
      });
      panel.append(form);
    } else {
      panel.append(makeElement("p", "muted-text", "Penawaranmu: " + status.my_bid + " koin."));
    }
    ui.phaseControls.append(panel);
    return;
  }

  if (view.phase === "action") {
    const panel = makeElement("div", "phase-panel");
    panel.append(makeElement("h4", "", isActive ? "Giliranmu memilih kartu" : "Menunggu pemain"));
    panel.append(makeElement("p", "muted-text", isActive
      ? "Pilih satu kartu di area kartu aksi. Kamu bisa menyimpannya sebagai saham atau mengaktifkan efeknya."
      : "Sedang menunggu " + displayNameFor(state.players,view.active_user_id) + " memilih kartu."));
    ui.phaseControls.append(panel);
    return;
  }

  if (view.phase === "sell") {
    const panel = makeElement("div", "phase-panel");
    panel.append(makeElement("h4", "", isActive ? "Giliran jual saham" : "Menunggu pemain menjual"));
    panel.append(makeElement("p", "muted-text", isActive
      ? "Jual satu jenis saham atau Reksa Dana dalam jumlah yang kamu tentukan, atau lewati giliran."
      : "Sedang menunggu " + displayNameFor(state.players,view.active_user_id) + "."));
    if (isActive) {
      const form = makeElement("form", "inline-game-form");
      const owned = SHARE_KEYS.filter((key) => Number(own && own.shares && own.shares[key] || 0)>0);
      const sectorSelect = makeSelect(
        owned.map((key) => ({value:key,label:sectorName(key)})),
        owned.length ? owned[0] : ""
      );
      const quantitySelect = document.createElement("select");
      quantitySelect.className = "game-input";
      const updateQuantities = () => {
        quantitySelect.replaceChildren();
        const count = Number(own && own.shares && own.shares[sectorSelect.value] || 0);
        for (let i=1;i<=count;i++) addOption(quantitySelect,String(i),String(i)+" lembar");
      };
      if (owned.length) updateQuantities();
      sectorSelect.disabled = owned.length===0;
      quantitySelect.disabled = owned.length===0;
      sectorSelect.addEventListener("change",updateQuantities);
      form.append(makeField("Saham yang dijual",sectorSelect));
      form.append(makeField("Jumlah",quantitySelect));
      const sellButton = makeElement("button","button primary","Jual");
      sellButton.type = "submit"; sellButton.disabled = owned.length===0;
      form.append(sellButton);
      form.addEventListener("submit",async(event)=>{
        event.preventDefault();
        setBusy(sellButton,true,"Menjual…");
        await runGameAction(()=>db.rpc("complete_sell_turn",{
          p_room_id:sessionState.roomId,p_sector:sectorSelect.value,p_quantity:Number(quantitySelect.value)
        }),"Penjualan selesai.");
        setBusy(sellButton,false);
      });
      const passButton = makeElement("button","button secondary","Lewati jual");
      passButton.type="button";
      passButton.addEventListener("click",async()=>{
        setBusy(passButton,true,"Melewati…");
        await runGameAction(()=>db.rpc("complete_sell_turn",{
          p_room_id:sessionState.roomId,p_sector:null,p_quantity:0
        }),"Giliran jual dilewati.");
        setBusy(passButton,false);
      });
      panel.append(form,passButton);
    }
    ui.phaseControls.append(panel);
    return;
  }

  if (view.phase === "economy") {
    const panel = makeElement("div","phase-panel");
    const isHost = sessionState.roomMeta && sessionState.roomMeta.host_id===sessionState.user.id;
    panel.append(makeElement("h4","","Fase ekonomi"));
    panel.append(makeElement("p","muted-text",isHost
      ? "Buka satu kartu teratas dari masing-masing tumpukan sektor untuk menerapkan perubahan harga."
      : "Menunggu host membuka kartu ekonomi."));
    if (isHost) {
      const reveal = makeElement("button","button primary","Buka kartu ekonomi");
      reveal.type="button";
      reveal.addEventListener("click",async()=>{
        setBusy(reveal,true,"Membuka…");
        await runGameAction(()=>db.rpc("resolve_economy",{p_room_id:sessionState.roomId}),"Kartu ekonomi dibuka.");
        setBusy(reveal,false);
      });
      panel.append(reveal);
    }
    ui.phaseControls.append(panel);
    return;
  }

  if (view.phase === "finished") {
    ui.phaseControls.append(makeElement("div","phase-panel finished-message","Permainan selesai. Skor akhir dihitung dari uang, nilai saham, Reksa Dana, dan pengurangan utang."));
  }
}

function tradingFeeForCard(card, own) {
  const shares = own && own.shares || {};
  if (card && card.sector === "mutual_fund") return Number(shares.mutual_fund || 0);
  return SECTORS.reduce((total, sector) => total + Number(shares[sector.id] || 0), 0);
}
function tradingFeeDescription(card) {
  return card && card.sector === "mutual_fund"
    ? "1 koin per unit Reksa Dana"
    : "1 koin per saham sektor yang kamu miliki";
}

function displayNameFor(players,userId) {
  const player = (players||[]).find((item)=>item.user_id===userId);
  return player ? player.display_name : "pemain lain";
}

function renderActionMarket(view, own) {
  const state = view.state || {};
  const cards = Array.isArray(state.action_market) ? state.action_market : [];
  const isActive = view.active_user_id === sessionState.user.id;
  ui.actionMarket.replaceChildren();
  ui.actionMarketCount.textContent = cards.length + " kartu tersisa";

  if (!cards.length) {
    ui.actionMarket.append(makeElement("div", "empty-state", "Pasar kartu aksi sedang kosong."));
    return;
  }

  for (const card of cards) {
    const panel = makeElement("article", "action-card" + (isActive ? " is-selectable" : " is-waiting"));
    const header = makeElement("div", "action-card-header");
    header.append(makeElement("span", "action-sector", sectorName(card.sector)));
    header.append(makeElement("strong", "action-title", card.title));
    panel.append(header);
    appendCardImage(panel, actionCardAsset(card), card.title + " — " + sectorName(card.sector), "action-card-image");

    if (card.action === "info-bursa") {
      panel.append(makeElement("small", "action-hint", "Efek: intip kartu ekonomi dan dapatkan 2 koin."));
    } else if (card.action === "quickbuy") {
      panel.append(makeElement("small", "action-hint", "Efek: ambil dua kartu lain."));
    } else if (card.action === "trading-fee") {
      const fee = tradingFeeForCard(card, own);
      panel.append(makeElement("small", "action-hint", "Biaya aktivasi: " + fee + " koin (" + tradingFeeDescription(card) + ")."));
    } else {
      panel.append(makeElement("small", "action-hint", "Pilih untuk menyimpan atau mengaktifkan."));
    }

    const actions = makeElement("div", "action-card-buttons");
    const keepLabel = card.sector === "mutual_fund" ? "Simpan" : "Simpan saham";
    const keepButton = makeElement("button", "button secondary", keepLabel);
    keepButton.type = "button";
    keepButton.disabled = !isActive;
    keepButton.addEventListener("click", async () => {
      setBusy(keepButton, true, "Menyimpan…");
      const keepAs = card.sector === "mutual_fund" ? "mutual_fund" : "stock";
      await runGameAction(() => db.rpc("perform_action_card", {
        p_room_id: sessionState.roomId,
        p_card_id: card.id,
        p_mode: "keep",
        p_choice: { keep_as: keepAs }
      }), card.sector === "mutual_fund"
        ? "Kartu disimpan sebagai Reksa Dana."
        : "Kartu disimpan sebagai saham " + sectorName(card.sector) + ".");
      setBusy(keepButton, false);
    });

    const activate = makeElement("button", "button primary", "Aktifkan");
    activate.type = "button";
    activate.disabled = !isActive;
    activate.addEventListener("click", () => openActivationForm(card, panel, own));
    actions.append(keepButton, activate);
    panel.append(actions);
    ui.actionMarket.append(panel);
  }
}

function openActivationForm(card, cardElement, own) {
  const old = cardElement.querySelector(".activation-form");
  if (old) old.remove();

  const state = sessionState.gameView && sessionState.gameView.state || {};
  const marketCards = Array.isArray(state.action_market) ? state.action_market : [];
  const players = viewPlayers();
  const formWrap = makeElement("div", "activation-form");
  formWrap.append(makeElement("strong", "", "Pilihan aktivasi"));
  const form = makeElement("form", "choice-form");
  let getChoice = () => ({});
  let isChoiceValid = true;

  if (card.action === "info-bursa") {
    const sectors = SECTORS.map((s) => ({ value: s.id, label: s.name }));
    const a = makeSelect(sectors, "finance");
    const b = makeSelect(sectors, "consumer");
    const c = makeSelect(sectors, "agriculture");
    form.append(
      makeField("Sektor pertama", a),
      makeField("Sektor kedua", b),
      makeField("Sektor ketiga", c)
    );
    getChoice = () => ({ sector_a: a.value, sector_b: b.value, sector_c: c.value });
  } else if (card.action === "rumor") {
    const mode = makeSelect([
      { value: "single", label: "Satu sektor ±2" },
      { value: "double", label: "Dua sektor ±1" }
    ]);
    const choices = makeElement("div", "choice-fields");
    const fill = () => {
      choices.replaceChildren();
      if (mode.value === "single") {
        const sector = makeSelect(SECTORS.map((s) => ({ value: s.id, label: s.name })));
        const delta = makeSelect([
          { value: "2", label: "Naik 2" },
          { value: "-2", label: "Turun 2" }
        ]);
        choices.append(makeField("Sektor", sector), makeField("Perubahan", delta));
        getChoice = () => ({ mode: "single", sector: sector.value, delta: Number(delta.value) });
      } else {
        const options = SECTORS.map((s) => ({ value: s.id, label: s.name }));
        const a = makeSelect(options, "finance");
        const b = makeSelect(options, "consumer");
        const da = makeSelect([{ value: "1", label: "Naik 1" }, { value: "-1", label: "Turun 1" }]);
        const dbb = makeSelect([{ value: "1", label: "Naik 1" }, { value: "-1", label: "Turun 1" }]);
        choices.append(
          makeField("Sektor pertama", a), makeField("Perubahan pertama", da),
          makeField("Sektor kedua", b), makeField("Perubahan kedua", dbb)
        );
        getChoice = () => ({
          mode: "double", sector_a: a.value, delta_a: Number(da.value),
          sector_b: b.value, delta_b: Number(dbb.value)
        });
      }
    };
    form.append(makeField("Pola Rumor", mode), choices);
    mode.addEventListener("change", fill);
    fill();
  } else if (card.action === "quickbuy") {
    const choices = marketCards.filter((item) => item.id !== card.id);
    if (choices.length < 2) {
      isChoiceValid = false;
      form.append(makeElement("p", "muted-text", "Quickbuy memerlukan dua kartu lain yang masih tersedia. Tidak ada cukup kartu untuk dipilih."));
    } else {
      const options = choices.map((item) => ({
        value: item.id,
        label: sectorName(item.sector) + " · " + item.title
      }));
      const first = makeSelect(options, options[0].value);
      const second = makeSelect(options, options[1].value);
      const updateSecond = () => {
        const selected = second.value;
        second.replaceChildren();
        for (const option of options.filter((item) => item.value !== first.value)) {
          addOption(second, option.value, option.label);
        }
        if (options.some((item) => item.value === selected && item.value !== first.value)) {
          second.value = selected;
        }
      };
      first.addEventListener("change", updateSecond);
      form.append(makeField("Kartu pertama", first), makeField("Kartu kedua", second));
      getChoice = () => ({ card_ids: [first.value, second.value] });
    }
    form.append(makeElement("p", "muted-text", "Pilih dua kartu lain. Keduanya disimpan sebagai saham sesuai sektor kartunya; kartu Quickbuy dibuang."));
  } else if (card.action === "trading-fee") {
    const sellable = SHARE_KEYS.filter((key) => Number(own && own.shares && own.shares[key] || 0) > 0);
    const sector = makeSelect(sellable.map((key) => ({ value: key, label: sectorName(key) })));
    const quantity = makeSelect([]);
    const fill = () => {
      quantity.replaceChildren();
      const count = Number(own && own.shares && own.shares[sector.value] || 0);
      for (let i = 1; i <= count; i += 1) addOption(quantity, String(i), i + " unit");
    };
    sector.disabled = sellable.length === 0;
    quantity.disabled = sellable.length === 0;
    fill();
    sector.addEventListener("change", fill);
    form.append(makeField("Jenis yang dijual", sector), makeField("Jumlah", quantity));
    if (!sellable.length) {
      isChoiceValid = false;
      formWrap.append(makeElement("p", "muted-text", "Kamu belum memiliki saham atau Reksa Dana untuk dijual."));
    }
    const fee = tradingFeeForCard(card, own);
    formWrap.append(makeElement("p", "muted-text", "Biaya aktivasi: " + fee + " koin (" + tradingFeeDescription(card) + "). Pastikan saldo mencukupi."));
    getChoice = () => ({ sell_sector: sector.value, quantity: Number(quantity.value) });
  } else if (card.action === "acquisition") {
    const stockOptions = SECTORS.map((s) => ({ value: s.id, label: s.name }));
    const sectorSelect = card.sector === "mutual_fund"
      ? makeSelect(stockOptions, "finance")
      : null;
    const targetSelect = makeSelect([]);
    const targetField = makeField("Pemain yang diakuisisi", targetSelect);
    const fillTargets = () => {
      const chosenSector = card.sector === "mutual_fund" ? sectorSelect.value : card.sector;
      const ownCount = Number(own && own.shares && own.shares[chosenSector] || 0);
      const eligible = players.filter((player) =>
        player.user_id !== sessionState.user.id &&
        Number(player.shares && player.shares[chosenSector] || 0) > 0 &&
        Number(player.shares && player.shares[chosenSector] || 0) <= ownCount
      );
      targetSelect.replaceChildren();
      for (const player of eligible) {
        addOption(targetSelect, player.user_id,
          player.display_name + " (" + player.shares[chosenSector] + " saham)");
      }
      targetSelect.disabled = eligible.length === 0;
      isChoiceValid = eligible.length > 0;
      if (!isChoiceValid) {
        targetSelect.append(makeElement("option", "", "Tidak ada target yang memenuhi syarat"));
      }
    };
    if (sectorSelect) {
      form.append(makeField("Sektor saham yang diambil", sectorSelect));
      sectorSelect.addEventListener("change", fillTargets);
    }
    form.append(targetField);
    fillTargets();
    getChoice = () => ({
      ...(sectorSelect ? { target_sector: sectorSelect.value } : {}),
      target_user_id: targetSelect.value
    });
    if (card.sector === "mutual_fund") {
      formWrap.append(makeElement("p", "muted-text", "Akuisisi tidak dapat mengambil unit Reksa Dana; pilih salah satu sektor saham."));
    }
  }

  const buttons = makeElement("div", "choice-buttons");
  const cancel = makeElement("button", "button text-button", "Batal");
  cancel.type = "button";
  cancel.addEventListener("click", () => formWrap.remove());
  const confirm = makeElement("button", "button primary", "Konfirmasi aktivasi");
  confirm.type = "submit";
  confirm.disabled = !isChoiceValid;
  if (card.action === "trading-fee") {
    const fee = tradingFeeForCard(card, own);
    const coins = Number(sessionState.gameView && sessionState.gameView.my_private_state &&
      sessionState.gameView.my_private_state.coins || 0);
    if (coins < fee) confirm.disabled = true;
  }
  if (card.action === "acquisition") {
    const sectorSelect = form.querySelector("select");
    if (sectorSelect && card.sector === "mutual_fund") {
      sectorSelect.addEventListener("change", () => {
        window.setTimeout(() => { confirm.disabled = !isChoiceValid; }, 0);
      });
    }
  }
  buttons.append(cancel, confirm);
  form.append(buttons);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const choice = getChoice();
    if (card.action === "info-bursa" &&
      new Set([choice.sector_a, choice.sector_b, choice.sector_c]).size !== 3) {
      showNotice("Pilih tiga sektor yang berbeda.", "warning");
      return;
    }
    if (card.action === "rumor" && choice.mode === "double" && choice.sector_a === choice.sector_b) {
      showNotice("Pilih dua sektor yang berbeda.", "warning");
      return;
    }
    if (card.action === "quickbuy" &&
      (!Array.isArray(choice.card_ids) || choice.card_ids.length !== 2 || choice.card_ids[0] === choice.card_ids[1])) {
      showNotice("Pilih dua kartu yang berbeda.", "warning");
      return;
    }
    setBusy(confirm, true, "Memproses…");
    await runGameAction(() => db.rpc("perform_action_card", {
      p_room_id: sessionState.roomId,
      p_card_id: card.id,
      p_mode: "activate",
      p_choice: choice
    }), card.action === "quickbuy" ? "Quickbuy mengambil dua kartu." : "Efek kartu dijalankan.");
    setBusy(confirm, false);
  });

  formWrap.append(form);
  cardElement.append(formWrap);
  formWrap.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function viewPlayers() {
  return sessionState.gameView && sessionState.gameView.state && Array.isArray(sessionState.gameView.state.players)
    ? sessionState.gameView.state.players : [];
}

async function runGameAction(request, successMessage) {
  clearNotice();
  try {
    const { error } = await request();
    if (error) throw error;
    await loadActiveGame();
    if (successMessage) showNotice(successMessage,"success");
  } catch(error) {
    console.error("Game action failed:",error);
    showNotice(errorMessage(error),"error");
    await loadActiveGame();
  }
}

function renderFinalScores(state) {
  ui.finalScores.replaceChildren();
  const scores=Array.isArray(state.final_scores)?state.final_scores:[];
  const winner=state.winner_user_id;
  for(const score of [...scores].sort((a,b)=>Number(b.total_assets)-Number(a.total_assets) || Number(a.order_no)-Number(b.order_no))){
    const row=makeElement("article","score-card"+(score.user_id===winner?" winner":""));
    row.append(makeElement("strong","",score.display_name+(score.user_id===winner?" · PEMENANG":"")));
    row.append(makeElement("span","score-total",Number(score.total_assets).toLocaleString("id-ID")+" poin"));
    row.append(makeElement("small","","Uang "+score.coins+" · Saham "+score.stock_value+" · Reksa Dana "+score.mutual_fund_value+" · Utang -"+score.debt_penalty));
    ui.finalScores.append(row);
  }
}

function subscribeToRoom() {
  if (!sessionState.roomId || !db) return;
  if (sessionState.channel) db.removeChannel(sessionState.channel);
  const roomId=sessionState.roomId;
  sessionState.channel=db.channel("stocklab-room-"+roomId)
    .on("postgres_changes",{event:"*",schema:"public",table:"room_members",filter:"room_id=eq."+roomId},async()=>{await syncRoomState();})
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"rooms",filter:"id=eq."+roomId},async()=>{await syncRoomState();})
    .on("postgres_changes",{event:"DELETE",schema:"public",table:"rooms",filter:"id=eq."+roomId},async()=>{
      if (sessionState.channel) { await db.removeChannel(sessionState.channel); sessionState.channel=null; }
      if (sessionState.phaseTimerHandle) { window.clearInterval(sessionState.phaseTimerHandle); sessionState.phaseTimerHandle=null; }
      sessionState.roomId=null; sessionState.roomCode=""; sessionState.roomMeta=null;
      sessionState.members=[]; sessionState.gameView=null;
      ui.lobby.hidden=true; ui.gameTable.hidden=true;
      showRoomHub();
      showNotice("Room dibubarkan karena melewati batas waktu tidak aktif.","warning");
      await refreshOpenRooms();
    })
    .on("postgres_changes",{event:"*",schema:"public",table:"games",filter:"room_id=eq."+roomId},async()=>{await loadActiveGame();})
    .subscribe((status)=>{
      if(status==="SUBSCRIBED")setConnection("Terhubung",true);
      if(status==="CHANNEL_ERROR"||status==="TIMED_OUT")setConnection("Menghubungkan ulang");
    });
}

async function saveRoomSettings(event) {
  event.preventDefault();
  if (!sessionState.roomId || !sessionState.roomMeta ||
      sessionState.roomMeta.host_id !== sessionState.user.id) return;
  setBusy(ui.saveRoomSettings, true, "Menyimpan…");
  try {
    const { error } = await db.rpc("update_room_settings", {
      p_room_id: sessionState.roomId,
      p_bidding_seconds: Number(ui.lobbyBiddingSeconds.value),
      p_turn_seconds: Number(ui.lobbyTurnSeconds.value),
      p_idle_timeout_minutes: Number(ui.lobbyIdleMinutes.value)
    });
    if (error) throw error;
    const { data, error: roomError } = await db.from("rooms")
      .select("id,invite_code,host_id,max_players,status,bidding_seconds,turn_seconds,idle_timeout_minutes,last_activity_at")
      .eq("id", sessionState.roomId).maybeSingle();
    if (roomError) throw roomError;
    if (data) sessionState.roomMeta = data;
    await refreshLobby();
    showNotice("Pengaturan room berhasil disimpan.", "success");
  } catch (error) {
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(ui.saveRoomSettings, false);
  }
}

async function toggleReady() {
  if(!sessionState.roomId||!sessionState.user||!sessionState.roomMeta||sessionState.roomMeta.status!=="waiting")return;
  const current=sessionState.members.find(member=>member.user_id===sessionState.user.id);
  if(!current)return;
  setBusy(ui.readyButton,true,"Menyimpan…");
  try{
    const {error}=await db.from("room_members").update({is_ready:!current.is_ready})
      .eq("room_id",sessionState.roomId).eq("user_id",sessionState.user.id);
    if(error)throw error;
    await refreshLobby();
  }catch(error){showNotice(errorMessage(error),"error");}
  finally{setBusy(ui.readyButton,false);}
}

async function leaveRoom(button = ui.leaveButton) {
  if (!sessionState.roomId) return;
  setBusy(button, true, "Keluar…");
  try {
    const { error } = await db.rpc("leave_room", { p_room_id: sessionState.roomId });
    if (error) throw error;
    if (sessionState.channel) {
      await db.removeChannel(sessionState.channel);
      sessionState.channel = null;
    }
    if (sessionState.phaseTimerHandle) {
      window.clearInterval(sessionState.phaseTimerHandle);
      sessionState.phaseTimerHandle = null;
    }
    sessionState.autoTimeoutPending = false;
    sessionState.roomId = null;
    sessionState.roomCode = "";
    sessionState.roomMeta = null;
    sessionState.members = [];
    sessionState.gameView = null;
    ui.lobby.hidden = true;
    ui.gameTable.hidden = true;
    showRoomHub();
    setConnection("Terhubung", true);
    await refreshOpenRooms();
  } catch (error) {
    showNotice(errorMessage(error), "error");
  } finally {
    setBusy(button, false);
  }
}

ui.enterForm.addEventListener("submit",enterAsGuest);
ui.showCreatePanel.addEventListener("click",openCreatePanel);
ui.showJoinPanel.addEventListener("click",() => { openJoinPanel(); refreshOpenRooms(); });
ui.backFromCreate.addEventListener("click",showRoomHub);
ui.backFromJoin.addEventListener("click",showRoomHub);
ui.createForm.addEventListener("submit",createRoom);
ui.joinForm.addEventListener("submit",(event)=>{
  event.preventDefault();
  joinRoom(ui.joinInput.value,ui.joinPassword.value);
});
ui.refreshRooms.addEventListener("click",refreshOpenRooms);
ui.readyButton.addEventListener("click",toggleReady);
ui.startButton.addEventListener("click",startGame);
ui.leaveButton.addEventListener("click", () => leaveRoom(ui.leaveButton));
ui.leaveGameButton.addEventListener("click", () => leaveRoom(ui.leaveGameButton));
ui.roomSettingsForm.addEventListener("submit", saveRoomSettings);
ui.debtButton.addEventListener("click", () => {
  const own = currentPlayer(sessionState.gameView || {});
  const shares = own && own.shares || {};
  const available = SECTORS.filter((sector) => Number(shares[sector.id] || 0) > 0);
  ui.debtSector.replaceChildren();
  for (const sector of available) addOption(ui.debtSector, sector.id, sector.name);
  ui.debtForm.hidden = available.length === 0 || !ui.debtForm.hidden;
});
ui.debtForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!sessionState.roomId || !ui.debtSector.value) return;
  setBusy(ui.debtSubmit, true, "Memproses…");
  await runGameAction(() => db.rpc("take_debt", {
    p_room_id: sessionState.roomId,
    p_sector: ui.debtSector.value
  }), "Satu saham " + sectorName(ui.debtSector.value) + " dibalik menjadi utang: +10 koin, penalti akhir 13.");
  ui.debtForm.hidden = true;
  setBusy(ui.debtSubmit, false);
});
ui.copyCode.addEventListener("click",async()=>{
  try{
    await navigator.clipboard.writeText(sessionState.roomCode);
    ui.copyCode.textContent="Tersalin";
    window.setTimeout(()=>{ui.copyCode.textContent="Salin kode";},1500);
  }catch(_){showNotice("Salin kode secara manual: "+sessionState.roomCode,"info");}
});

const rememberedName=localStorage.getItem("stocklab_guest_username");
if(rememberedName)ui.usernameInput.value=rememberedName;
if(!db){
  showNotice("Library Supabase gagal dimuat. Periksa koneksi lalu muat ulang halaman.","error");
  setConnection("Gagal dimuat");
}else{
  restoreExistingGuest();
}
