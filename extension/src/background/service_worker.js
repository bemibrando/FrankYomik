import { DEFAULT_SETTINGS, STORAGE_KEYS, apiOriginPattern, normalizeSettings } from '../shared/config.js';

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.setAccessLevel?.({ accessLevel: 'TRUSTED_CONTEXTS' }).catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  chrome.storage.local.setAccessLevel?.({ accessLevel: 'TRUSTED_CONTEXTS' }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message, sender)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: error.message || String(error) }));
  return true;
});

async function handleMessage(message) {
  if (!message || typeof message !== 'object') {
    throw new Error('invalid message');
  }

  switch (message.type) {
    case 'GET_SETTINGS':
      return { ok: true, settings: await getSettingsForUi() };
    case 'SAVE_SETTINGS':
      return saveSettings(message.settings || {});
    case 'CHECK_HEALTH':
      return checkHealth();
    default:
      throw new Error(`unknown message type: ${message.type}`);
  }
}

async function getSettings() {
  const stored = await chrome.storage.local.get(STORAGE_KEYS.settings);
  return normalizeSettings(stored[STORAGE_KEYS.settings] || DEFAULT_SETTINGS);
}

async function getSettingsForUi() {
  return getSettings();
}

async function saveSettings(rawSettings) {
  const settings = normalizeSettings(rawSettings);
  if (settings.apiBaseUrl) {
    const origin = apiOriginPattern(settings.apiBaseUrl);
    const granted = await chrome.permissions.request({ origins: [origin] });
    if (!granted) {
      throw new Error(`API host permission denied for ${origin}`);
    }
  }
  await chrome.storage.local.set({ [STORAGE_KEYS.settings]: settings });
  return { ok: true, settings };
}

async function checkHealth() {
  const settings = await getSettings();
  if (!settings.apiBaseUrl) throw new Error('Set the API base URL first.');
  const response = await fetch(`${settings.apiBaseUrl}/api/v1/health`, {
    method: 'GET',
    cache: 'no-store',
  });
  if (!response.ok) throw new Error(`health check failed: HTTP ${response.status}`);
  return { ok: true, health: await response.json() };
}
