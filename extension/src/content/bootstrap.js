(function frankBootstrap() {
  'use strict';

  if (window.__frankYomikBootstrapLoaded) return;
  window.__frankYomikBootstrapLoaded = true;

  const host = location.hostname.toLowerCase();
  const site = host === 'read.amazon.co.jp' || host === 'read.kindle.co.jp'
    ? 'kindle'
    : host === 'comic.naver.com' || host === 'm.comic.naver.com'
      ? 'webtoon'
      : null;

  if (!site) return;

  chrome.runtime.sendMessage({ type: 'GET_SETTINGS' }, (response) => {
    if (chrome.runtime.lastError || !response?.ok) return;
    const settings = response.settings || {};
    if (!settings.configured) {
      console.info('[Frank] extension is installed but not configured');
      return;
    }
    if (site === 'kindle' && settings.kindleEnabled === false) return;
    if (site === 'webtoon' && settings.webtoonEnabled === false) return;
    if (site === 'kindle' && window.FrankKindle) {
      window.FrankKindle.start(settings);
      return;
    }
    if (site === 'webtoon' && window.FrankWebtoon) {
      window.FrankWebtoon.start(settings);
      return;
    }
    console.info(`[Frank] ${site} extension bootstrap ready; strategy not loaded yet`);
  });
})();
