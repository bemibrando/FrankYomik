import test from 'node:test';
import assert from 'node:assert/strict';

import {
  cacheKeyFor,
  formatBytes,
  normalizeApiImageUrl,
  safeText,
  sanitizeCapture,
  sanitizeMetadata,
  validateAllowedWebtoonImageUrl,
} from '../src/shared/policy.js';

test('normalizeApiImageUrl allows relative and same-origin result URLs', () => {
  assert.equal(
    normalizeApiImageUrl('https://frank.example.net/base', '/api/v1/jobs/abc/image'),
    'https://frank.example.net/api/v1/jobs/abc/image',
  );
  assert.equal(
    normalizeApiImageUrl({ apiBaseUrl: 'https://frank.example.net/base' }, 'https://frank.example.net/api/v1/cache/x'),
    'https://frank.example.net/api/v1/cache/x',
  );
});

test('normalizeApiImageUrl rejects cross-origin result URLs', () => {
  assert.throws(
    () => normalizeApiImageUrl('https://frank.example.net', 'https://evil.example.net/leak'),
    /cross-origin/,
  );
});

test('validateAllowedWebtoonImageUrl allows only exact HTTPS pstatic image hosts', () => {
  assert.equal(
    validateAllowedWebtoonImageUrl('https://image-comic.pstatic.net/webtoon/1/2.jpg').hostname,
    'image-comic.pstatic.net',
  );
  assert.throws(() => validateAllowedWebtoonImageUrl('http://image-comic.pstatic.net/x.jpg'), /https/);
  assert.throws(() => validateAllowedWebtoonImageUrl('https://evil.pstatic.net/x.jpg'), /not allowed/);
});

test('sanitizeMetadata clamps strings and normalizes source URL', () => {
  const meta = sanitizeMetadata({
    title: 'x'.repeat(200),
    chapter: '7',
    pageNumber: '9',
    sourceUrl: 'javascript:alert(1)',
  }, 'https://read.amazon.co.jp/books/B000000000');
  assert.equal(meta.title.length, 120);
  assert.equal(meta.chapter, '7');
  assert.equal(meta.page_number, '9');
  assert.equal(meta.source_url, '');
});

test('sanitizeCapture keeps safe fields and numeric rect values', () => {
  const capture = sanitizeCapture({
    imgSrc: 'blob:https://read.amazon.co.jp/123',
    groupId: 'spread-1',
    side: 'left',
    index: '3',
    pageMode: 'spread',
    rect: { x: '1', y: 2, width: '300', height: 400 },
  });
  assert.deepEqual(capture.rect, { x: 1, y: 2, width: 300, height: 400 });
  assert.equal(capture.side, 'left');
  assert.equal(capture.index, 3);
  assert.equal(capture.pageMode, 'spread');
});

test('cacheKeyFor includes API origin, pipeline, and source hash', () => {
  assert.equal(cacheKeyFor('https://frank.example.net/api', 'manga_translate', 'abc'), 'https://frank.example.net|manga_translate|abc');
});

test('safeText and formatBytes are deterministic', () => {
  assert.equal(safeText('  abcdef  ', 3), 'abc');
  assert.equal(formatBytes(1536), '2 KiB');
  assert.equal(formatBytes(2 * 1024 * 1024), '2.0 MiB');
});
