import { apiOriginPattern, normalizeApiBaseUrl } from '../shared/config.js';

const form = document.querySelector('#settings-form');
const statusEl = document.querySelector('#status');

const fields = {
  apiBaseUrl: document.querySelector('#api-base-url'),
  authToken: document.querySelector('#auth-token'),
  kindleEnabled: document.querySelector('#kindle-enabled'),
  webtoonEnabled: document.querySelector('#webtoon-enabled'),
  mangaPipeline: document.querySelector('#manga-pipeline'),
  targetLanguage: document.querySelector('#target-language'),
  webtoonPrefetch: document.querySelector('#webtoon-prefetch'),
};

loadSettings();

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  await saveSettings();
});

document.querySelector('#health-check').addEventListener('click', async () => {
  setStatus('Checking server…');
  const response = await sendMessage({ type: 'CHECK_HEALTH' });
  if (!response.ok) {
    setStatus(response.error || 'Health check failed.', 'error');
    return;
  }
  const health = response.health || {};
  setStatus(`Server OK. Redis: ${health.redis || 'unknown'}, workers: ${health.active_workers ?? 0}.`, 'ok');
});

async function loadSettings() {
  const response = await sendMessage({ type: 'GET_SETTINGS' });
  if (!response.ok) {
    setStatus(response.error || 'Could not load settings.', 'error');
    return;
  }
  applySettings(response.settings || {});
}

async function saveSettings() {
  setStatus('Saving…');
  const settings = readSettings();
  const permissionGranted = await requestApiPermission(settings.apiBaseUrl);
  if (!permissionGranted) return;
  const response = await sendMessage({ type: 'SAVE_SETTINGS', settings });
  if (!response.ok) {
    setStatus(response.error || 'Could not save settings.', 'error');
    return;
  }
  applySettings(response.settings || {});
  setStatus('Saved.', 'ok');
}

function applySettings(settings) {
  fields.apiBaseUrl.value = settings.apiBaseUrl || '';
  fields.authToken.value = settings.authToken || '';
  fields.kindleEnabled.checked = settings.kindleEnabled !== false;
  fields.webtoonEnabled.checked = settings.webtoonEnabled !== false;
  fields.mangaPipeline.value = settings.mangaPipeline || 'manga_translate';
  fields.targetLanguage.value = settings.targetLanguage || 'en';
  fields.webtoonPrefetch.value = settings.webtoonPrefetch || 'nearby';
}

function readSettings() {
  return {
    apiBaseUrl: fields.apiBaseUrl.value,
    authToken: fields.authToken.value,
    kindleEnabled: fields.kindleEnabled.checked,
    webtoonEnabled: fields.webtoonEnabled.checked,
    mangaPipeline: fields.mangaPipeline.value,
    targetLanguage: fields.targetLanguage.value,
    webtoonPrefetch: fields.webtoonPrefetch.value,
  };
}

async function requestApiPermission(apiBaseUrl) {
  const normalized = normalizeApiBaseUrl(apiBaseUrl);
  if (!normalized) return true;
  const origin = apiOriginPattern(normalized);
  const alreadyGranted = await chrome.permissions.contains({ origins: [origin] });
  if (alreadyGranted) return true;
  const granted = await chrome.permissions.request({ origins: [origin] });
  if (!granted) {
    setStatus(`Permission denied for ${origin}.`, 'error');
    return false;
  }
  return true;
}

function setStatus(message, kind = '') {
  statusEl.textContent = message;
  if (kind) statusEl.dataset.kind = kind;
  else delete statusEl.dataset.kind;
}

function sendMessage(message) {
  return chrome.runtime.sendMessage(message).catch((error) => ({
    ok: false,
    error: error.message || String(error),
  }));
}
