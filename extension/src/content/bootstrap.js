(function frankBootstrap() {
  'use strict';

  if (window.__frankYomikBootstrapLoaded) return;
  window.__frankYomikBootstrapLoaded = true;

  const RETRY_MS = 5000;
  let retryTimer = null;

  const host = location.hostname.toLowerCase();
  const site = host === 'read.amazon.co.jp' || host === 'read.kindle.co.jp'
    ? 'kindle'
    : host === 'comic.naver.com' || host === 'm.comic.naver.com'
      ? 'webtoon'
      : null;

  if (!site) return;

  requestSettings();

  function requestSettings() {
    chrome.runtime.sendMessage({ type: 'GET_SETTINGS' }, (response) => {
      if (chrome.runtime.lastError || !response?.ok) {
        scheduleRetry();
        return;
      }

      handleSettings(response.settings || {});
    });
  }

  function handleSettings(settings) {
    if (!settings.configured) {
      console.info('[Frank] extension is installed but not configured');
      scheduleRetry();
      return;
    }
    if (site === 'kindle' && settings.kindleEnabled === false) {
      scheduleRetry();
      return;
    }
    if (site === 'webtoon' && settings.webtoonEnabled === false) {
      scheduleRetry();
      return;
    }
    if (site === 'kindle' && window.FrankKindle) {
      window.FrankKindle.start(settings);
      report('info', 'Kindle strategy start requested');
      return;
    }
    if (site === 'webtoon' && window.FrankWebtoon) {
      window.FrankWebtoon.start(settings);
      report('info', 'Webtoon strategy start requested');
      return;
    }
    console.info(`[Frank] ${site} extension bootstrap ready; strategy not loaded yet`);
    scheduleRetry();
  }

  function scheduleRetry() {
    if (retryTimer) return;
    retryTimer = window.setTimeout(() => {
      retryTimer = null;
      requestSettings();
    }, RETRY_MS);
  }

  function report(level, message) {
    chrome.runtime.sendMessage({ type: 'REPORT_EVENT', site, level, message }).catch(() => {});
  }
})();
