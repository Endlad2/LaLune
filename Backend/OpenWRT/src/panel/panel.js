// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"use strict";

const byId = (id) => document.getElementById(id);
const profileSelect = byId("profile-select");
const profileDialog = byId("profile-dialog");
const profileForm = byId("profile-form");
const profileFields = profileForm.elements;
const settingsForm = byId("settings-form");
const authMode = byId("auth-mode");
const tokenFile = byId("token-file");
const logs = byId("logs");
const logOutput = byId("log-output");
const logSource = byId("log-source");

let protocols = [];
let profiles = [];
let selectedId = null;
let editedId = null;
let settings = {};
let hasToken = false;
let vpnState = "unknown";
let ready = false;
let busy = false;
let monitoring = false;
let readingLogs = false;

const currentProfile = () => profiles.find((profile) => profile.id === selectedId);
const protocolAliases = { "CSQTT 2.5.1": "CSQTT", "CSQTTR 2.5.2": "CSQTTR" };
const usesToken = (mode) => mode === "autoApi" || mode === "autoVk";

function supportedId(protocol) {
  const normalized = protocol.trim().toUpperCase();
  const id = protocolAliases[normalized] ?? normalized;
  return protocols.find((candidate) => candidate.id === id)?.id;
}

async function request(path, method = "GET", payload) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), method === "GET" ? 8000 : 65000);
  try {
    const response = await fetch(path, {
      method,
      mode: "same-origin",
      cache: "no-store",
      redirect: "error",
      signal: controller.signal,
      headers: payload === undefined ? undefined : { "Content-Type": "application/json" },
      body: payload === undefined ? undefined : JSON.stringify(payload),
    });
    const text = await response.text();
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    }
    if (!response.ok) {
      const detail = data && typeof data === "object"
        ? (data.error ?? data.message ?? data.detail)
        : data;
      throw new Error(detail ? String(detail) : `HTTP ${response.status}`);
    }
    return data ?? {};
  } catch (error) {
    if (error?.name === "AbortError") {
      throw new Error(`Таймаут запроса ${method} ${path}`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function message(id, text = "", error = false) {
  const element = byId(id);
  element.textContent = text;
  element.toggleAttribute("data-error", error);
}

function refreshControls() {
  const active = vpnState === "connected" || vpnState === "connecting";
  const profile = currentProfile();
  const idle = ready && !busy;
  const editable = idle && !active;
  const canUseAuth = !usesToken(settings.authMode) || hasToken;
  profileSelect.disabled = !editable;
  byId("connect").disabled = !editable || vpnState !== "disconnected"
    || !profile || !supportedId(profile.protocol) || !canUseAuth;
  byId("disconnect").disabled = !idle || !active;
  byId("add-profile").disabled = !editable || protocols.length === 0;
  byId("edit-profile").disabled = !editable || !profile;
  byId("profile-fields").disabled = busy;
  byId("settings-fields").disabled = !idle;
  tokenFile.disabled = !idle;
  byId("auth-token-note").hidden = hasToken || !(usesToken(authMode.value) || usesToken(settings.authMode));
}

function showStatus(state, uptime = 0, socksPort) {
  const labels = {
    connecting: "Подключаемся…",
    connected: "Подключено",
    disconnected: "Отключено",
    unavailable: "Нет связи с роутером",
  };
  vpnState = state;
  byId("connection").dataset.state = state;
  const status = byId("vpn-state");
  if (status.textContent !== labels[state]) status.textContent = labels[state];
  const seconds = Math.max(0, Math.floor(Number(uptime) || 0));
  const duration = [
    Math.floor(seconds / 3600),
    Math.floor((seconds % 3600) / 60),
    seconds % 60,
  ].map((part) => String(part).padStart(2, "0")).join(":");
  const detail = socksPort ? `${duration} · SOCKS5 ${socksPort}` : duration;
  byId("vpn-uptime").textContent = state === "connected" ? detail : "";
  refreshControls();
}

async function refreshStatus() {
  try {
    const status = await request("/vpn/status");
    const state = status.connected ? "connected" : status.state;
    const known = ["connecting", "connected", "disconnected"].includes(state);
    showStatus(known ? state : "unavailable", status.uptimeSec, status.socks5Port);
  } catch {
    showStatus("unavailable");
  }
}

function showProfiles() {
  profileSelect.replaceChildren(new Option("Выберите профиль", ""));
  for (const profile of profiles) {
    const name = profile.name || profile.peer;
    const note = supportedId(profile.protocol) ? "" : " · недоступен";
    profileSelect.add(new Option(`${name} · ${profile.protocol}${note}`, profile.id));
  }
  profileSelect.value = currentProfile() ? String(selectedId) : "";
  refreshControls();
}

function updateAuthFields() {
  byId("manual-settings").hidden = authMode.value !== "manual";
  byId("auto-api-settings").hidden = authMode.value !== "autoApi";
  settingsForm.elements.autoApiWorkers.disabled = authMode.value !== "autoApi";
  refreshControls();
}

const settingsControls = [...settingsForm.querySelectorAll("[name]")];

function settingValue(control) {
  if (control.type === "checkbox") return control.checked;
  if (["workers", "autoApiWorkers"].includes(control.name)) return control.valueAsNumber;
  return control.value.trim();
}

function showSettings(values) {
  for (const control of settingsControls) {
    const value = values[control.name];
    if (value !== undefined) {
      if (control.type === "checkbox") {
        control.checked = value;
      } else {
        if (control.tagName === "SELECT" && ![...control.options].some((option) => option.value === value)) {
          control.add(new Option(value, value));
        }
        control.value = value;
      }
    }
    settings[control.name] = settingValue(control);
  }
  updateAuthFields();
}

async function refreshToken() {
  const tokenState = await request("/vk/token/state");
  hasToken = tokenState.hasToken === true;
  message("token-state", hasToken ? "Токен загружен" : "Токен не загружен");
  refreshControls();
}

async function refreshLogs() {
  if (!logs.open || readingLogs) return;
  const source = logSource.value;
  readingLogs = true;
  try {
    const lines = await request(`/logs/tail?source=${source}&lines=100`);
    if (source !== logSource.value) return;
    const text = lines.join("\n") || "Журнал пока пуст.";
    if (text !== logOutput.textContent) {
      const nearEnd = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight < 24;
      logOutput.textContent = text;
      if (nearEnd) logOutput.scrollTop = logOutput.scrollHeight;
    }
  } catch {
    if (source === logSource.value) logOutput.textContent = "Не удалось загрузить журнал.";
  } finally {
    readingLogs = false;
    if (source !== logSource.value) refreshLogs();
  }
}

async function run(messageId, failure, action) {
  if (busy || !ready) return;
  busy = true;
  message(messageId);
  refreshControls();
  try {
    await action();
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error ?? "");
    message(messageId, detail ? `${failure} Причина: ${detail}` : failure, true);
  } finally {
    busy = false;
    refreshControls();
  }
}

async function selectProfile(id) {
  try {
    await request("/configs/selected", "PUT", { id });
    selectedId = id;
  } finally {
    showProfiles();
  }
}

function openProfile(profile) {
  editedId = profile?.id ?? null;
  profileForm.reset();
  profileFields.protocol.replaceChildren(...protocols.map(({ id, displayName }) => new Option(displayName || id, id)));
  if (profile) {
    const protocol = supportedId(profile.protocol);
    if (!protocol) {
      profileFields.protocol.prepend(new Option("Выберите поддерживаемый протокол", ""));
    }
    profileFields.protocol.value = protocol ?? "";
    for (const key of ["name", "peer", "password", "hashes"]) {
      profileFields[key].value = profile[key] ?? "";
    }
  }
  byId("profile-title").textContent = profile ? "Изменить профиль" : "Добавить профиль";
  byId("delete-profile").hidden = !profile;
  message("profile-message");
  profileDialog.showModal();
}

profileSelect.addEventListener("change", () => {
  const id = Number(profileSelect.value) || null;
  run("vpn-message", "Не удалось выбрать профиль.", () => selectProfile(id));
});
byId("add-profile").addEventListener("click", () => openProfile());
byId("edit-profile").addEventListener("click", () => openProfile(currentProfile()));
byId("close-profile").addEventListener("click", () => profileDialog.close());
profileDialog.addEventListener("cancel", (event) => {
  if (busy) event.preventDefault();
});
profileDialog.addEventListener("close", () => profileForm.reset());

profileForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const protocol = profileFields.protocol.value;
  const name = profileFields.name.value.trim();
  const link = profileFields.link.value.trim();
  const peer = profileFields.peer.value.trim();
  const password = profileFields.password.value;
  const hashes = profileFields.hashes.value.trim();
  if (!link && (!peer || !password)) {
    message("profile-message", "Введите ссылку либо адрес сервера и пароль.", true);
    return;
  }
  const payload = link ? { protocol, name, link } : { protocol, name, peer, password, hashes };
  run("profile-message", "Не удалось сохранить профиль. Проверьте введённые данные.", async () => {
    const editing = editedId !== null;
    const result = await request(editing ? `/configs/${editedId}` : "/configs", editing ? "PUT" : "POST", payload);
    profileDialog.close();
    try {
      profiles = await request("/configs");
      if (editing) showProfiles();
      else await selectProfile(result.id);
      message("vpn-message", "Профиль сохранён");
    } catch {
      message("vpn-message", "Профиль сохранён. Обновите страницу, чтобы проверить выбор.", true);
    }
  });
});

byId("delete-profile").addEventListener("click", () => {
  if (!window.confirm("Удалить этот профиль?")) return;
  run("profile-message", "Не удалось удалить профиль.", async () => {
    await request(`/configs/${editedId}`, "DELETE");
    profiles = profiles.filter((profile) => profile.id !== editedId);
    selectedId = null;
    showProfiles();
    profileDialog.close();
    message("vpn-message", "Профиль удалён");
  });
});

byId("connect").addEventListener("click", () => {
  run("vpn-message", "Не удалось подключиться. Проверьте профиль и журнал ядра.", async () => {
    showStatus("connecting");
    try {
      await request("/vpn/connect", "POST", { configId: selectedId });
    } finally {
      await Promise.all([refreshStatus(), refreshLogs()]);
    }
  });
});
byId("disconnect").addEventListener("click", () => {
  run("vpn-message", "Не удалось отключиться.", async () => {
    await request("/vpn/disconnect", "POST");
    await refreshStatus();
  });
});

authMode.addEventListener("change", updateAuthFields);
settingsForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const patch = {};
  for (const control of settingsControls) {
    const value = settingValue(control);
    if (!control.disabled && value !== settings[control.name]) patch[control.name] = value;
  }
  run("settings-message", "Не удалось сохранить настройки.", async () => {
    if (Object.keys(patch).length) {
      await request("/settings", "PATCH", patch);
      Object.assign(settings, patch);
    }
    message("settings-message", "Настройки сохранены");
  });
});

tokenFile.addEventListener("change", () => {
  const file = tokenFile.files[0];
  tokenFile.value = "";
  if (!file) return;
  run("token-message", "Не удалось сохранить токен на роутере.", async () => {
    let token;
    try {
      if (file.size > 65536) throw new Error();
      const data = JSON.parse(await file.text());
      token = data?.Token ?? data?.token;
      if (typeof token !== "string" || !token.trim()) throw new Error();
    } catch {
      message("token-message", "Выберите JSON-файл с полем Token или token.", true);
      return;
    }
    await request("/vk/token/submit", "POST", { token: token.trim() });
    await refreshToken();
    message("token-message", "Токен сохранён на роутере");
  });
});

logs.addEventListener("toggle", refreshLogs);
logSource.addEventListener("change", () => {
  byId("log-export").href = `/logs/export?source=${logSource.value}`;
  refreshLogs();
});
byId("log-clear").addEventListener("click", () => {
  if (!window.confirm("Очистить весь журнал роутера?")) return;
  run("log-message", "Не удалось очистить журнал.", async () => {
    await request("/logs", "DELETE");
    await refreshLogs();
    message("log-message", "Журнал очищен");
  });
});

async function monitor() {
  if (document.hidden || busy || monitoring) return;
  monitoring = true;
  try {
    await Promise.all([refreshStatus(), refreshLogs()]);
  } finally {
    monitoring = false;
  }
}

async function start() {
  try {
    const [available, saved, selected, values] = await Promise.all([
      request("/core/protocols"),
      request("/configs"),
      request("/configs/selected"),
      request("/settings"),
      refreshToken(),
      refreshStatus(),
    ]);
    protocols = available;
    profiles = saved;
    selectedId = selected.id ?? null;
    showSettings(values);
    ready = true;
    showProfiles();
    message("load-message");
    setInterval(monitor, 3000);
  } catch {
    message("load-message", "Не удалось загрузить панель. Проверьте связь с роутером и обновите страницу.", true);
  }
}

start();
