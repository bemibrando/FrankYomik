export const DEFAULT_SETTINGS = Object.freeze({
  apiBaseUrl: '',
  authToken: '',
  kindleEnabled: true,
  webtoonEnabled: true,
  mangaPipeline: 'manga_translate',
  targetLanguage: 'en',
  webtoonPrefetch: 'nearby',
});

export const STORAGE_KEYS = Object.freeze({
  settings: 'frankSettings',
});

export const KINDLE_HOSTS = new Set(['read.amazon.co.jp', 'read.kindle.co.jp']);
export const NAVER_WEBTOON_HOSTS = new Set(['comic.naver.com', 'm.comic.naver.com']);

export function normalizeSettings(raw = {}) {
  return {
    ...DEFAULT_SETTINGS,
    ...raw,
    apiBaseUrl: normalizeApiBaseUrl(raw.apiBaseUrl ?? DEFAULT_SETTINGS.apiBaseUrl),
    mangaPipeline: raw.mangaPipeline === 'manga_furigana' ? 'manga_furigana' : 'manga_translate',
    targetLanguage: raw.targetLanguage === 'pt-br' ? 'pt-br' : 'en',
    webtoonPrefetch: raw.webtoonPrefetch === 'off' || raw.webtoonPrefetch === 'episode'
      ? raw.webtoonPrefetch
      : 'nearby',
    kindleEnabled: raw.kindleEnabled !== false,
    webtoonEnabled: raw.webtoonEnabled !== false,
  };
}

export function normalizeApiBaseUrl(value) {
  const trimmed = String(value || '').trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  try {
    const url = new URL(trimmed);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
    url.pathname = url.pathname.replace(/\/+$/, '');
    url.search = '';
    url.hash = '';
    return url.toString().replace(/\/+$/, '');
  } catch {
    return '';
  }
}

export function apiOriginPattern(apiBaseUrl) {
  const url = new URL(apiBaseUrl);
  return `${url.protocol}//${url.host}/*`;
}
