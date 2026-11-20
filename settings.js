(() => {
  "use strict";
  const STORAGE_KEY = "stocklab_site_preferences";
  const NAME_KEY = "stocklab_guest_username";
  const defaults = { theme: "midnight", textSize: "normal", roomDensity: "comfortable", reduceMotion: false };
  const $ = (id) => document.getElementById(id);
  const form = $("profile-settings-form");
  const nameInput = $("profile-settings-name");
  const themeInput = $("setting-theme");
  const textSizeInput = $("setting-text-size");
  const densityInput = $("setting-room-density");
  const reduceMotionInput = $("setting-reduce-motion");
  const feedback = $("settings-feedback");

  function readPreferences() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
      return { ...defaults, ...saved };
    } catch (_) {
      return { ...defaults };
    }
  }
  function preferencesFromForm() {
    return {
      theme: themeInput.value === "forest" ? "forest" : "midnight",
      textSize: textSizeInput.value === "large" ? "large" : "normal",
      roomDensity: densityInput.value === "compact" ? "compact" : "comfortable",
      reduceMotion: Boolean(reduceMotionInput.checked)
    };
  }
  function applyPreferences(preferences) {
    document.body.dataset.interfaceTheme = preferences.theme;
    document.body.classList.toggle("ui-large-text", preferences.textSize === "large");
    document.body.classList.toggle("ui-compact-cards", preferences.roomDensity === "compact");
    document.body.classList.toggle("ui-reduced-motion", Boolean(preferences.reduceMotion));
  }
  function showFeedback(message, kind) {
    feedback.textContent = message;
    feedback.dataset.state = kind || "success";
  }

  const savedPreferences = readPreferences();
  themeInput.value = savedPreferences.theme;
  textSizeInput.value = savedPreferences.textSize;
  densityInput.value = savedPreferences.roomDensity;
  reduceMotionInput.checked = savedPreferences.reduceMotion;
  nameInput.value = localStorage.getItem(NAME_KEY) || "";
  applyPreferences(savedPreferences);

  [themeInput, textSizeInput, densityInput, reduceMotionInput].forEach((control) => {
    control.addEventListener("change", () => applyPreferences(preferencesFromForm()));
  });

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const name = String(nameInput.value || "").trim();
    if (name && (name.length < 2 || name.length > 24)) {
      showFeedback("Nama pemain harus terdiri dari 2 sampai 24 karakter.", "error");
      nameInput.focus();
      return;
    }
    const preferences = preferencesFromForm();
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(preferences));
      if (name) localStorage.setItem(NAME_KEY, name);
      applyPreferences(preferences);
      showFeedback("Pengaturan berhasil disimpan di browser ini.", "success");
    } catch (_) {
      showFeedback("Browser tidak mengizinkan penyimpanan lokal. Periksa pengaturan privasi browser.", "error");
    }
  });
})();