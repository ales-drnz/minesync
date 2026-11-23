{{flutter_js}}
{{flutter_build_config}}
// Avvio della web UI servita dall'hub (docs/design/protocol.md, "Static web
// UI"). Tutto arriva da /b/<id-build>/ (cache immutabile): nessuna risorsa da
// CDN esterni, la rete ZeroTier può non avere internet. L'id della build lo
// scrive l'hub in index.html (<meta name="minesync-build">); se manca (file
// aperto fuori dall'hub) si usa la radice.
(function () {
  'use strict';
  const meta = document.querySelector('meta[name="minesync-build"]');
  const id = meta && /^[0-9a-f]{12}$/.test(meta.content) ? meta.content : '';
  const base = id ? '/b/' + id + '/' : '/';

  // Testo della splash nella lingua del browser (IT o EN).
  const it = (navigator.language || '').toLowerCase().startsWith('it');
  document.documentElement.lang = it ? 'it' : 'en';
  const msg = document.querySelector('#splash .msg');
  if (msg) msg.textContent = it ? "Caricamento dell'hub…" : 'Loading the hub…';

  const config = {
    entrypointBaseUrl: base,
    assetBase: base,
    // CanvasKit e skwasm locali: serve `flutter build web --no-web-resources-cdn`
    canvasKitBaseUrl: base + 'canvaskit/',
    // niente fonts.gstatic.com: i font dell'app sono negli asset
    fontFallbackBaseUrl: base + 'fallback-fonts/',
    // l'hub è in HTTP semplice: niente SharedArrayBuffer, skwasm a un thread
    suppressMultithreadingWarning: true,
  };

  _flutter.loader.load({
    config,
    onEntrypointLoaded: async function (engineInitializer) {
      // la config va ripassata al motore (assetBase, fontFallbackBaseUrl)
      const appRunner = await engineInitializer.initializeEngine(config);
      await appRunner.runApp();
      document.body.classList.add('ready');
    },
  });
})();
