import {
  DEFAULT_SETTINGS,
  KINDLE_HOSTS,
  NAVER_WEBTOON_HOSTS,
  STORAGE_KEYS,
  VALID_MANGA_PIPELINES,
  VALID_TARGET_LANGUAGES,
  apiOriginPattern,
  normalizeSettings,
} from '../shared/config.js';

const POLL_ALARM_NAME = 'frankPollJobs';
const POLL_DELAY_MS = 3_000;
const JOB_TIMEOUT_MS = 5 * 60_000;
const MAX_CACHE_ENTRIES = 200;
const MAX_CAPTURE_DATA_URL_BYTES = 28 * 1024 * 1024;
const DB_NAME = 'frank-yomik-extension';
const DB_VERSION = 1;
const IMAGE_STORE = 'images';

let pollTimer = null;

chrome.runtime.onInstalled.addListener(() => {
  restrictStorageAccess();
  ensurePollingAlarm();
});

chrome.runtime.onStartup.addListener(() => {
  restrictStorageAccess();
  ensurePollingAlarm();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === POLL_ALARM_NAME) {
    pollActiveJobs().catch((error) => console.warn('[Frank] poll alarm failed:', error));
  }
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
      return { ok: true, settings: await getSettingsForSender(sender) };
    case 'SAVE_SETTINGS':
      return saveSettings(message.settings || {});
    case 'CHECK_HEALTH':
      return checkHealth();
    case 'SUBMIT_CAPTURE':
      return submitCapture(message, sender);
    case 'GET_ACTIVE_JOBS':
      return { ok: true, jobs: await loadActiveJobs() };
    default:
      throw new Error(`unknown message type: ${message.type}`);
  }
}

async function getSettings() {
  const stored = await chrome.storage.local.get(STORAGE_KEYS.settings);
  return normalizeSettings(stored[STORAGE_KEYS.settings] || DEFAULT_SETTINGS);
}

async function getSettingsForSender(sender) {
  const settings = await getSettings();
  if (!sender?.tab) return settings;
  return {
    apiBaseUrl: settings.apiBaseUrl,
    configured: Boolean(settings.apiBaseUrl && settings.authToken),
    kindleEnabled: settings.kindleEnabled,
    webtoonEnabled: settings.webtoonEnabled,
    mangaPipeline: settings.mangaPipeline,
    targetLanguage: settings.targetLanguage,
    webtoonPrefetch: settings.webtoonPrefetch,
  };
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
  const response = await fetchWithTimeout(`${settings.apiBaseUrl}/api/v1/health`, {
    method: 'GET',
    cache: 'no-store',
  }, 10_000);
  if (!response.ok) throw new Error(`health check failed: HTTP ${response.status}`);
  return { ok: true, health: await response.json() };
}

async function submitCapture(message, sender) {
  const site = validateSender(sender);
  const settings = await getSettings();
  if (!settings.apiBaseUrl || !settings.authToken) {
    throw new Error('Extension is not configured. Set API URL and auth token first.');
  }
  if (site === 'kindle' && settings.kindleEnabled === false) throw new Error('Kindle support is disabled.');
  if (site === 'webtoon' && settings.webtoonEnabled === false) throw new Error('Webtoon support is disabled.');

  const pageId = safeText(message.pageId, 120) || `${site}-${Date.now()}`;
  const dataUrl = String(message.imageDataUrl || '');
  if (!dataUrl.startsWith('data:image/png;base64,') && !dataUrl.startsWith('data:image/jpeg;base64,')) {
    throw new Error('capture must be a PNG or JPEG data URL');
  }
  if (dataUrl.length > MAX_CAPTURE_DATA_URL_BYTES) throw new Error('capture is too large');

  const image = await dataUrlToBlobAndBytes(dataUrl);
  const sourceHash = await sha256Hex(image.bytes);
  const pipeline = pipelineForSite(site, settings, message.pipeline);
  const targetLanguage = VALID_TARGET_LANGUAGES.has(settings.targetLanguage) ? settings.targetLanguage : 'en';
  const cachePipeline = targetLanguage === 'en' ? pipeline : `${pipeline}_${targetLanguage}`;
  const cacheKey = cacheKeyFor(settings.apiBaseUrl, cachePipeline, sourceHash);
  const cachedDataUrl = await cacheGet(cacheKey);
  if (cachedDataUrl) {
    return {
      ok: true,
      status: 'completed',
      cached: true,
      pageId,
      site,
      sourceHash,
      pipeline,
      imageDataUrl: cachedDataUrl,
      capture: sanitizeCapture(message.capture),
    };
  }

  const metadata = sanitizeMetadata(message.metadata || {}, sender.url || sender.tab?.url || '');
  const priority = message.priority === 'low' ? 'low' : 'high';
  const response = await submitJob(settings, image.blob, {
    pipeline,
    priority,
    targetLanguage,
    metadata,
    force: false,
  });

  const jobId = String(response.job_id || '');
  if (!jobId) throw new Error('server response did not include job_id');

  if (response.cached === true) {
    const imageUrl = response.image_url || `/api/v1/jobs/${encodeURIComponent(jobId)}/image`;
    try {
      const translated = await downloadImageDataUrl(settings, imageUrl);
      await cachePut(cacheKey, translated, { sourceHash, pipeline: cachePipeline, targetLanguage });
      return {
        ok: true,
        status: 'completed',
        cached: true,
        pageId,
        site,
        jobId,
        sourceHash: response.source_hash || sourceHash,
        pipeline,
        imageUrl,
        imageDataUrl: translated,
        capture: sanitizeCapture(message.capture),
      };
    } catch (error) {
      console.warn('[Frank] cached image download failed; forcing reprocess:', error);
      const forced = await submitJob(settings, image.blob, {
        pipeline,
        priority,
        targetLanguage,
        metadata,
        force: true,
      });
      return queueJobRecord({
        response: forced,
        sender,
        pageId,
        site,
        sourceHash,
        pipeline,
        cachePipeline,
        cacheKey,
        capture: sanitizeCapture(message.capture),
      });
    }
  }

  return queueJobRecord({
    response,
    sender,
    pageId,
    site,
    sourceHash: response.source_hash || sourceHash,
    pipeline,
    cachePipeline,
    cacheKey,
    capture: sanitizeCapture(message.capture),
  });
}

async function queueJobRecord({ response, sender, pageId, site, sourceHash, pipeline, cachePipeline, cacheKey, capture }) {
  const jobId = String(response.job_id || '');
  if (!jobId) throw new Error('server response did not include job_id');

  const job = {
    jobId,
    pageId,
    site,
    tabId: sender.tab?.id,
    sourceHash,
    pipeline,
    cachePipeline,
    cacheKey,
    capture,
    submittedAt: Date.now(),
    lastPollAt: 0,
    status: response.status || 'queued',
  };
  const jobs = await loadActiveJobs();
  jobs[jobId] = job;
  await saveActiveJobs(jobs);
  schedulePollSoon();
  return { ok: true, status: 'queued', pageId, site, jobId, sourceHash, pipeline, capture };
}

function validateSender(sender) {
  const rawUrl = sender?.url || sender?.tab?.url || '';
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error('message sender has no valid URL');
  }
  if (url.protocol !== 'https:') throw new Error('unsupported sender scheme');
  const host = url.hostname.toLowerCase();
  if (KINDLE_HOSTS.has(host)) return 'kindle';
  if (NAVER_WEBTOON_HOSTS.has(host)) return 'webtoon';
  throw new Error(`unsupported sender host: ${host}`);
}

function pipelineForSite(site, settings, requestedPipeline) {
  if (site === 'webtoon') return 'webtoon';
  const preferred = requestedPipeline || settings.mangaPipeline;
  return VALID_MANGA_PIPELINES.has(preferred) ? preferred : 'manga_translate';
}

async function submitJob(settings, imageBlob, options) {
  const form = new FormData();
  form.set('pipeline', options.pipeline);
  form.set('priority', options.priority);
  form.set('target_lang', options.targetLanguage);
  form.set('image', imageBlob, 'page.png');
  if (options.force) form.set('force', 'true');
  for (const [key, value] of Object.entries(options.metadata || {})) {
    if (value) form.set(key, value);
  }

  return withRetry(async () => {
    const response = await fetchWithTimeout(`${settings.apiBaseUrl}/api/v1/jobs`, {
      method: 'POST',
      headers: authHeaders(settings),
      body: form,
    }, 30_000);
    const text = await response.text();
    if (response.status !== 201) {
      throw retryableError(`submit failed: HTTP ${response.status} ${text}`, response.status >= 500);
    }
    return JSON.parse(text);
  });
}

async function getJobStatus(settings, jobId) {
  return withRetry(async () => {
    const response = await fetchWithTimeout(`${settings.apiBaseUrl}/api/v1/jobs/${encodeURIComponent(jobId)}`, {
      method: 'GET',
      headers: authHeaders(settings),
      cache: 'no-store',
    }, 10_000);
    if (!response.ok) throw retryableError(`status failed: HTTP ${response.status}`, response.status >= 500);
    return response.json();
  });
}

async function downloadImageDataUrl(settings, imageUrl) {
  const url = imageUrl.startsWith('http') ? imageUrl : `${settings.apiBaseUrl}${imageUrl}`;
  return withRetry(async () => {
    const response = await fetchWithTimeout(url, {
      method: 'GET',
      headers: authHeaders(settings),
      cache: 'no-store',
    }, 45_000);
    if (!response.ok) throw retryableError(`image download failed: HTTP ${response.status}`, response.status >= 500);
    const blob = await response.blob();
    return blobToDataUrl(blob);
  });
}

async function pollActiveJobs() {
  const settings = await getSettings();
  if (!settings.apiBaseUrl || !settings.authToken) return;
  const jobs = await loadActiveJobs();
  const entries = Object.values(jobs);
  if (!entries.length) return;

  let changed = false;
  for (const job of entries) {
    if (Date.now() - job.submittedAt > JOB_TIMEOUT_MS) {
      delete jobs[job.jobId];
      changed = true;
      await notifyTab(job, { type: 'FRANK_JOB_FAILED', pageId: job.pageId, jobId: job.jobId, error: 'Job timed out' });
      continue;
    }

    try {
      job.lastPollAt = Date.now();
      const status = await getJobStatus(settings, job.jobId);
      if (status.status === 'completed') {
        const imageUrl = status.image_url || `/api/v1/jobs/${encodeURIComponent(job.jobId)}/image`;
        const imageDataUrl = await downloadImageDataUrl(settings, imageUrl);
        await cachePut(job.cacheKey, imageDataUrl, {
          sourceHash: status.source_hash || job.sourceHash,
          pipeline: job.cachePipeline,
          targetLanguage: settings.targetLanguage,
        });
        delete jobs[job.jobId];
        changed = true;
        await notifyTab(job, {
          type: 'FRANK_JOB_COMPLETE',
          pageId: job.pageId,
          site: job.site,
          jobId: job.jobId,
          sourceHash: status.source_hash || job.sourceHash,
          imageUrl,
          imageDataUrl,
          capture: job.capture,
        });
      } else if (status.status === 'failed') {
        delete jobs[job.jobId];
        changed = true;
        await notifyTab(job, {
          type: 'FRANK_JOB_FAILED',
          pageId: job.pageId,
          site: job.site,
          jobId: job.jobId,
          error: status.error || 'Job failed',
        });
      }
    } catch (error) {
      console.warn(`[Frank] poll failed for ${job.jobId}:`, error);
    }
  }

  if (changed) await saveActiveJobs(jobs);
  if (Object.keys(jobs).length) schedulePollSoon();
}

async function notifyTab(job, message) {
  if (typeof job.tabId !== 'number') return;
  try {
    await chrome.tabs.sendMessage(job.tabId, message);
  } catch (error) {
    console.warn('[Frank] could not notify tab:', error);
  }
}

function ensurePollingAlarm() {
  chrome.alarms.create(POLL_ALARM_NAME, { periodInMinutes: 0.5 });
}

function schedulePollSoon() {
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = setTimeout(() => {
    pollTimer = null;
    pollActiveJobs().catch((error) => console.warn('[Frank] scheduled poll failed:', error));
  }, POLL_DELAY_MS);
  ensurePollingAlarm();
}

async function loadActiveJobs() {
  const stored = await chrome.storage.local.get(STORAGE_KEYS.activeJobs);
  const jobs = stored[STORAGE_KEYS.activeJobs];
  return jobs && typeof jobs === 'object' ? jobs : {};
}

async function saveActiveJobs(jobs) {
  await chrome.storage.local.set({ [STORAGE_KEYS.activeJobs]: jobs });
}

function authHeaders(settings) {
  return { Authorization: `Bearer ${settings.authToken}` };
}

function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timer));
}

async function withRetry(action, maxAttempts = 3) {
  let lastError;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await action();
    } catch (error) {
      lastError = error;
      if (!error.retryable && error.name !== 'AbortError' && !(error instanceof TypeError)) break;
      if (attempt === maxAttempts) break;
      await sleep(Math.min(2 ** attempt, 4) * 1000);
    }
  }
  throw lastError;
}

function retryableError(message, retryable) {
  const error = new Error(message);
  error.retryable = retryable;
  return error;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function dataUrlToBlobAndBytes(dataUrl) {
  const response = await fetch(dataUrl);
  const blob = await response.blob();
  const bytes = await blob.arrayBuffer();
  return { blob, bytes };
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error('failed to read image blob'));
    reader.onload = () => resolve(String(reader.result));
    reader.readAsDataURL(blob);
  });
}

async function sha256Hex(arrayBuffer) {
  const digest = await crypto.subtle.digest('SHA-256', arrayBuffer);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function cacheKeyFor(apiBaseUrl, cachePipeline, sourceHash) {
  const origin = new URL(apiBaseUrl).origin;
  return `${origin}|${cachePipeline}|${sourceHash}`;
}

function sanitizeMetadata(metadata, fallbackUrl) {
  return {
    title: safeText(metadata.title, 120),
    chapter: safeText(metadata.chapter, 60),
    page_number: safeText(metadata.pageNumber || metadata.page_number, 60),
    source_url: safeUrl(metadata.sourceUrl || metadata.source_url || fallbackUrl),
  };
}

function sanitizeCapture(capture = {}) {
  if (!capture || typeof capture !== 'object') return {};
  const rect = capture.rect && typeof capture.rect === 'object' ? capture.rect : capture.readerRect;
  return {
    imgSrc: safeText(capture.imgSrc, 2048),
    originalSrc: safeText(capture.originalSrc, 2048),
    index: Number.isFinite(Number(capture.index)) ? Number(capture.index) : undefined,
    pageMode: capture.pageMode === 'spread' ? 'spread' : 'single',
    rect: rect ? {
      x: finiteNumber(rect.x ?? rect.left),
      y: finiteNumber(rect.y ?? rect.top),
      width: finiteNumber(rect.width),
      height: finiteNumber(rect.height),
    } : undefined,
  };
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function safeText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function safeUrl(value) {
  const text = safeText(value, 2048);
  if (!text) return '';
  try {
    const url = new URL(text);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
    return url.toString();
  } catch {
    return '';
  }
}

async function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onerror = () => reject(request.error);
    request.onsuccess = () => resolve(request.result);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(IMAGE_STORE)) {
        const store = db.createObjectStore(IMAGE_STORE, { keyPath: 'key' });
        store.createIndex('lastAccessed', 'lastAccessed');
      }
    };
  });
}

async function cacheGet(key) {
  const db = await openDb();
  try {
    const entry = await idbRequest(db.transaction(IMAGE_STORE, 'readonly').objectStore(IMAGE_STORE).get(key));
    if (!entry?.dataUrl) return null;
    entry.lastAccessed = Date.now();
    await cachePut(key, entry.dataUrl, entry.meta || {});
    return entry.dataUrl;
  } finally {
    db.close();
  }
}

async function cachePut(key, dataUrl, meta = {}) {
  const db = await openDb();
  try {
    const now = Date.now();
    const store = db.transaction(IMAGE_STORE, 'readwrite').objectStore(IMAGE_STORE);
    await idbRequest(store.put({ key, dataUrl, meta, bytes: dataUrl.length, createdAt: now, lastAccessed: now }));
  } finally {
    db.close();
  }
  await evictCacheIfNeeded();
}

async function evictCacheIfNeeded() {
  const db = await openDb();
  try {
    const transaction = db.transaction(IMAGE_STORE, 'readwrite');
    const store = transaction.objectStore(IMAGE_STORE);
    const entries = await idbRequest(store.getAll());
    if (entries.length <= MAX_CACHE_ENTRIES) return;
    entries.sort((a, b) => (a.lastAccessed || 0) - (b.lastAccessed || 0));
    const overflow = entries.slice(0, entries.length - MAX_CACHE_ENTRIES);
    await Promise.all(overflow.map((entry) => idbRequest(store.delete(entry.key))));
  } finally {
    db.close();
  }
}

function idbRequest(request) {
  return new Promise((resolve, reject) => {
    request.onerror = () => reject(request.error);
    request.onsuccess = () => resolve(request.result);
  });
}

function restrictStorageAccess() {
  try {
    const result = chrome.storage.local.setAccessLevel?.({ accessLevel: 'TRUSTED_CONTEXTS' });
    if (result && typeof result.catch === 'function') result.catch(() => {});
  } catch {
    // Older Chromium builds may not support setAccessLevel. The token still
    // stays out of content-script messages; this is defense-in-depth.
  }
}
