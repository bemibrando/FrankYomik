import test from 'node:test';
import assert from 'node:assert/strict';

import {
  apiOriginPattern,
  normalizeApiBaseUrl,
  normalizeSettings,
} from '../src/shared/config.js';

test('normalizeApiBaseUrl strips trailing slashes and URL noise', () => {
  assert.equal(normalizeApiBaseUrl(' https://frank.example.net/api///?x=1#token '), 'https://frank.example.net/api');
});

test('normalizeApiBaseUrl accepts LAN HTTP but rejects non-HTTP protocols', () => {
  assert.equal(normalizeApiBaseUrl('http://192.168.0.90:8080/'), 'http://192.168.0.90:8080');
  assert.equal(normalizeApiBaseUrl('file:///tmp/nope'), '');
});

test('apiOriginPattern grants only the configured origin', () => {
  assert.equal(apiOriginPattern('https://frank.example.net/api'), 'https://frank.example.net/*');
  assert.equal(apiOriginPattern('http://192.168.0.90:8080'), 'http://192.168.0.90:8080/*');
});

test('normalizeSettings clamps enum-like settings to supported values', () => {
  const settings = normalizeSettings({
    apiBaseUrl: 'https://frank.example.net/',
    mangaPipeline: 'bad',
    targetLanguage: 'es',
    webtoonPrefetch: 'too-much',
    kindleEnabled: false,
  });
  assert.equal(settings.apiBaseUrl, 'https://frank.example.net');
  assert.equal(settings.mangaPipeline, 'manga_translate');
  assert.equal(settings.targetLanguage, 'en');
  assert.equal(settings.webtoonPrefetch, 'nearby');
  assert.equal(settings.kindleEnabled, false);
  assert.equal(settings.webtoonEnabled, true);
});
