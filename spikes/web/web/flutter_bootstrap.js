{{flutter_js}}
{{flutter_build_config}}
// Configurazione del loader: tutti gli asset da /b/<id>/ (cache immutabile),
// nessuna risorsa da CDN esterni (la rete ZeroTier può non avere internet
// e comunque non vogliamo dipendere da gstatic).
const config = {
  entrypointBaseUrl: '/b/__BUILD__/',
  assetBase: '/b/__BUILD__/',
  canvasKitBaseUrl: '/b/__BUILD__/canvaskit/',
  fontFallbackBaseUrl: '/b/__BUILD__/fallback-fonts/',
  suppressMultithreadingWarning: true,
  // ?renderer=canvaskit forza la build JS (confronto nelle misure).
  renderer: new URLSearchParams(location.search).get('renderer') || undefined,
};
_flutter.loader.load({
  config,
  onEntrypointLoaded: async (engineInitializer) => {
    // La config va ripassata al motore: assetBase, fontFallbackBaseUrl...
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
    document.body.classList.add('ready');
  },
});
