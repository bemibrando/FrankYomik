(function frankKindleModule() {
  'use strict';

  if (window.FrankKindle) return;

  const SPREAD_THRESHOLD = 1.3;
  const DETECT_INTERVAL_MS = 450;
  const MAX_CAPTURE_SIDE = 2200;

  let started = false;
  let settings = {};
  let sessionId = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
  let pageCounter = 0;
  let lastBlob = '';
  let lastRect = null;
  let lastEmitAt = 0;
  let userNavAt = Date.now();
  let navIntent = 'forward';
  let activeGroups = 0;
  let queuedDetection = null;
  let lastNoTargetReportAt = 0;
  const processedBlobs = new Set();
  const spreadGroups = new Map();

  window.FrankKindle = { start };

  function start(nextSettings) {
    if (started) return;
    started = true;
    settings = nextSettings || {};
    installListeners();
    window.setInterval(detectPageChange, DETECT_INTERVAL_MS);
    window.setTimeout(detectPageChange, 400);
    console.info('[Frank] Kindle strategy started');
    report('info', 'Kindle strategy started');
  }

  function installListeners() {
    document.addEventListener('click', (event) => {
      if (typeof event.clientX === 'number') {
        navIntent = event.clientX <= window.innerWidth / 2 ? 'forward' : 'backward';
      }
      userNavAt = Date.now();
      window.setTimeout(detectPageChange, 500);
    });
    for (const eventName of ['pointerdown', 'mousedown', 'touchstart']) {
      document.addEventListener(eventName, () => {
        userNavAt = Date.now();
        window.setTimeout(detectPageChange, 420);
      }, true);
    }
    document.addEventListener('wheel', () => { userNavAt = Date.now(); }, { passive: true });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowLeft') navIntent = 'forward';
      if (event.key === 'ArrowRight') navIntent = 'backward';
      userNavAt = Date.now();
    });
    document.addEventListener('keyup', () => {
      userNavAt = Date.now();
      window.setTimeout(detectPageChange, 500);
    });
    window.addEventListener('resize', () => {
      lastBlob = '';
      userNavAt = Date.now();
      window.setTimeout(detectPageChange, 1000);
    });
    chrome.runtime.onMessage.addListener((message) => {
      if (message?.type === 'FRANK_JOB_COMPLETE' && message.site === 'kindle') handleJobComplete(message);
      if (message?.type === 'FRANK_JOB_FAILED' && message.site === 'kindle') handleJobFailed(message);
    });
  }

  function detectPageChange() {
    if (!settings.configured || settings.kindleEnabled === false) return;
    if (loaderVisible()) return;
    const target = findVisibleBlob();
    if (!target) {
      reportNoTarget();
      return;
    }
    const blobSrc = target.src;
    if (!blobSrc || blobSrc === lastBlob || processedBlobs.has(blobSrc)) return;

    const rect = target.getBoundingClientRect();
    const now = Date.now();
    const userNavRecent = now - userNavAt < 4000;
    if (!userNavRecent && lastRect) {
      const dw = Math.abs(rect.width - lastRect.width) / Math.max(1, lastRect.width);
      const dh = Math.abs(rect.height - lastRect.height) / Math.max(1, lastRect.height);
      if (dw < 0.02 && dh < 0.02 && now - lastEmitAt < 600) return;
    }

    lastBlob = blobSrc;
    lastRect = { width: rect.width, height: rect.height };
    lastEmitAt = now;
    pageCounter += 1;

    const pageMode = rect.width > rect.height * SPREAD_THRESHOLD ? 'spread' : 'single';
    const pageId = `kindle-${sessionId}-${pageCounter}${pageMode === 'spread' ? '-spread' : ''}`;
    const detection = {
      pageId,
      index: pageCounter,
      pageMode,
      navIntent,
      imgSrc: blobSrc,
      naturalWidth: target.naturalWidth,
      naturalHeight: target.naturalHeight,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      devicePixelRatio: window.devicePixelRatio || 1,
      kindlePage: findKindlePage(),
    };
    report('info', `Detected Kindle ${pageMode} page ${pageCounter}`);
    scheduleSubmit(detection);
  }

  function scheduleSubmit(detection) {
    if (activeGroups > 0) {
      queuedDetection = detection;
      return;
    }
    activeGroups += 1;
    queuedDetection = null;
    submitDetection(detection).finally(() => {
      if (!spreadGroups.has(detection.pageId)) activeGroups = Math.max(0, activeGroups - 1);
      if (activeGroups === 0 && queuedDetection) {
        const next = queuedDetection;
        queuedDetection = null;
        window.setTimeout(() => scheduleSubmit(next), 250);
      }
    });
  }

  async function submitDetection(detection) {
    const target = findImageBySrc(detection.imgSrc) || findVisibleBlob();
    if (!target) return;
    processedBlobs.add(detection.imgSrc);

    try {
      if (detection.pageMode === 'spread') {
        await submitSpread(target, detection);
      } else {
        const imageDataUrl = captureImage(target, 'full');
        if (!imageDataUrl) throw new Error('Kindle capture failed');
        const response = await submitCapture({ ...detection, pageMode: 'single' }, imageDataUrl, detection.pageId);
        if (response.status === 'completed') await applyKindle(response);
      }
    } catch (error) {
      if (spreadGroups.has(detection.pageId)) spreadGroups.delete(detection.pageId);
      processedBlobs.delete(detection.imgSrc);
      console.warn('[Frank] Kindle submit failed:', error);
      report('error', `Kindle submit failed: ${error.message || error}`);
    }
  }

  async function submitSpread(target, detection) {
    const left = captureImage(target, 'left');
    const right = captureImage(target, 'right');
    if (!left || !right) throw new Error('Kindle spread capture failed');

    const group = {
      pageId: detection.pageId,
      detection,
      sides: {},
      pending: 2,
    };
    spreadGroups.set(detection.pageId, group);

    const leftId = `${detection.pageId}-left`;
    const rightId = `${detection.pageId}-right`;
    const leftResponse = await submitCapture({ ...detection, groupId: detection.pageId, side: 'left' }, left, leftId);
    const rightResponse = await submitCapture({ ...detection, groupId: detection.pageId, side: 'right' }, right, rightId);
    if (leftResponse.status === 'completed') await handleSpreadSide(leftResponse);
    if (rightResponse.status === 'completed') await handleSpreadSide(rightResponse);
  }

  async function submitCapture(capture, imageDataUrl, pageId) {
    const metadata = parseKindleMetadata(capture, pageId);
    const response = await chrome.runtime.sendMessage({
      type: 'SUBMIT_CAPTURE',
      site: 'kindle',
      pageId,
      pipeline: settings.mangaPipeline,
      priority: 'high',
      metadata,
      capture,
      imageDataUrl,
    });
    if (!response?.ok) throw new Error(response?.error || 'submit failed');
    report('info', `Kindle capture submitted: ${pageId} (${response.status || 'unknown'})`);
    return response;
  }

  async function handleJobComplete(message) {
    if (message.capture?.groupId) {
      await handleSpreadSide(message);
      return;
    }
    await applyKindle(message);
    finishGroup();
  }

  function handleJobFailed(message) {
    console.warn('[Frank] Kindle job failed:', message.error);
    report('error', `Kindle job failed: ${message.error || 'unknown error'}`);
    if (message.capture?.groupId) spreadGroups.delete(message.capture.groupId);
    finishGroup();
  }

  async function handleSpreadSide(message) {
    const groupId = message.capture?.groupId;
    const side = message.capture?.side;
    const group = spreadGroups.get(groupId);
    if (!group || (side !== 'left' && side !== 'right')) return;
    if (!group.sides[side]) group.pending -= 1;
    group.sides[side] = message.imageDataUrl;
    if (group.pending > 0) return;

    try {
      const stitched = await stitchSpread(group.sides.left, group.sides.right);
      await applyKindle({
        type: 'FRANK_JOB_COMPLETE',
        site: 'kindle',
        pageId: group.pageId,
        imageDataUrl: stitched,
        capture: group.detection,
      });
    } finally {
      spreadGroups.delete(groupId);
      finishGroup();
    }
  }

  async function applyKindle(message) {
    const ok = await window.FrankOverlay?.applyKindleResult(message);
    if (ok) {
      report('info', `Kindle translated image applied: ${message.pageId || 'unknown page'}`);
      for (const delay of [800, 1800, 3500]) {
        window.setTimeout(() => window.FrankOverlay?.applyKindleResult(message), delay);
      }
    }
    return ok;
  }

  function finishGroup() {
    activeGroups = Math.max(0, activeGroups - 1);
    if (activeGroups === 0 && queuedDetection) {
      const next = queuedDetection;
      queuedDetection = null;
      window.setTimeout(() => scheduleSubmit(next), 250);
    }
  }

  function captureImage(target, part) {
    const rect = target.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const renderW = Math.max(1, Math.round(rect.width * dpr));
    const renderH = Math.max(1, Math.round(rect.height * dpr));
    const side = Math.max(renderW, renderH);
    const scale = side > MAX_CAPTURE_SIDE ? MAX_CAPTURE_SIDE / side : 1;
    const fullW = Math.max(1, Math.round(renderW * scale));
    const fullH = Math.max(1, Math.round(renderH * scale));
    const sourceW = target.naturalWidth || target.width;
    const sourceH = target.naturalHeight || target.height;
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;

    if (part === 'left' || part === 'right') {
      const halfSourceW = Math.floor(sourceW / 2);
      const sx = part === 'left' ? 0 : halfSourceW;
      const sw = part === 'left' ? halfSourceW : sourceW - halfSourceW;
      canvas.width = Math.max(1, Math.round(fullW * (sw / sourceW)));
      canvas.height = fullH;
      ctx.drawImage(target, sx, 0, sw, sourceH, 0, 0, canvas.width, canvas.height);
    } else {
      canvas.width = fullW;
      canvas.height = fullH;
      ctx.drawImage(target, 0, 0, fullW, fullH);
    }

    try {
      return canvas.toDataURL('image/png');
    } catch (error) {
      console.warn('[Frank] Kindle canvas capture blocked:', error);
      return null;
    }
  }

  async function stitchSpread(leftDataUrl, rightDataUrl) {
    const [left, right] = await Promise.all([loadImage(leftDataUrl), loadImage(rightDataUrl)]);
    const canvas = document.createElement('canvas');
    canvas.width = left.naturalWidth + right.naturalWidth;
    canvas.height = Math.max(left.naturalHeight, right.naturalHeight);
    const ctx = canvas.getContext('2d');
    ctx.drawImage(left, 0, 0);
    ctx.drawImage(right, left.naturalWidth, 0);
    return canvas.toDataURL('image/png');
  }

  function loadImage(src) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('failed to load translated spread half'));
      img.src = src;
    });
  }

  function findVisibleBlob() {
    const root = findReaderRoot();
    let imgs = Array.from(root.querySelectorAll('img'));
    if (!imgs.length) imgs = Array.from(document.querySelectorAll('img'));
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const rootRect = root.getBoundingClientRect ? root.getBoundingClientRect() : null;
    let best = null;
    let bestArea = 0;
    for (const img of imgs) {
      if (img.dataset.frankTranslated === 'true') continue;
      if (!img.src?.startsWith('blob:')) continue;
      const rect = img.getBoundingClientRect();
      if (rect.width < 100 || rect.height < 100) continue;
      let overlap = overlapAreaInViewport(rect, vw, vh);
      if (overlap < 2000) continue;
      if (rootRect && root !== document.body) {
        const rootOverlap = overlapArea(rect, rootRect);
        if (rootOverlap < 2000) continue;
        overlap = Math.min(overlap, rootOverlap);
      }
      if (overlap > bestArea) {
        bestArea = overlap;
        best = img;
      }
    }
    return best;
  }

  function findImageBySrc(src) {
    if (!src) return null;
    return Array.from(document.querySelectorAll('img')).find((img) => img.src === src) || null;
  }

  function findReaderRoot() {
    return document.querySelector(
      '#kr-renderer, #kindle-reader-content, .reader-content, ' +
      '[id*="kindle-reader"], [id*="kr-renderer"], [class*="reader-content"]',
    ) || document.body;
  }

  function loaderVisible() {
    const nodes = document.querySelectorAll('.kg-loader-wrapper, .kg-loader-container, [class*="loader"]');
    for (const el of nodes) {
      const style = window.getComputedStyle(el);
      if (!style || style.display === 'none' || style.visibility === 'hidden') continue;
      const opacity = Number.parseFloat(style.opacity || '1');
      if (Number.isFinite(opacity) && opacity <= 0.05) continue;
      const rect = el.getBoundingClientRect();
      const overlap = overlapAreaInViewport(rect, window.innerWidth, window.innerHeight);
      if (overlap > 1600) return true;
    }
    return false;
  }

  function findKindlePage() {
    const indicator = document.querySelector(
      '#kr-page-indicator, .page-number, [class*="pageNum"], [class*="page-count"], ' +
      '[class*="location"], [data-cfi], .cfi-marker',
    );
    const text = indicator?.textContent?.trim().slice(0, 30);
    if (text) return text;
    const slider = document.querySelector('input[type="range"], [role="slider"]');
    return slider ? `pos:${slider.value || slider.getAttribute('aria-valuenow') || ''}` : '';
  }

  function parseKindleMetadata(capture, pageId) {
    const asinMatch = /[/=](B[A-Z0-9]{9})/.exec(location.href);
    return {
      title: asinMatch?.[1] || 'kindle',
      chapter: '1',
      pageNumber: capture.kindlePage || String(capture.index || pageId),
      sourceUrl: location.href,
    };
  }

  function overlapAreaInViewport(rect, vw, vh) {
    const ox = Math.min(rect.right, vw) - Math.max(rect.left, 0);
    const oy = Math.min(rect.bottom, vh) - Math.max(rect.top, 0);
    return ox <= 0 || oy <= 0 ? 0 : ox * oy;
  }

  function overlapArea(a, b) {
    const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left);
    const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    return ox <= 0 || oy <= 0 ? 0 : ox * oy;
  }

  function reportNoTarget() {
    const now = Date.now();
    if (now - lastNoTargetReportAt < 15000) return;
    lastNoTargetReportAt = now;
    report('info', 'Kindle detector is running, but no visible blob page image was found yet');
  }

  function report(level, message) {
    chrome.runtime.sendMessage({ type: 'REPORT_EVENT', site: 'kindle', level, message }).catch(() => {});
  }
})();
