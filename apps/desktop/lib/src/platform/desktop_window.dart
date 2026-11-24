// Finestra principale vera (window_manager): senza cornice del sistema, con
// la barra del titolo disegnata dall'app, dimensione minima, posizione e
// dimensione ricordate nelle preferenze, chiusura intercettata.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'platform.dart';

/// Dimensione minima della finestra all'avvio (scala 1); poi la aggiorna
/// [DesktopWindow.setMinimumSize] secondo la dimensione dell'interfaccia.
const minWindowSize = minWindowDesignSize;

/// Dimensione al primo avvio.
const defaultWindowSize = Size(1280, 800);

/// Rettangolo salvato nelle preferenze, se ancora sensato: deve stare almeno
/// in parte (una fascia della barra del titolo) dentro uno degli schermi
/// attuali, altrimenti (monitor staccato) si ricomincia dal centro.
Rect? restorableBounds(Object? saved, List<Rect> screens) {
  if (saved is! Map) return null;
  double? n(String k) => switch (saved[k]) {
    final num v => v.toDouble(),
    _ => null,
  };
  final x = n('x'), y = n('y'), w = n('w'), h = n('h');
  if (x == null || y == null || w == null || h == null) return null;
  final r = Rect.fromLTWH(
    x,
    y,
    w < minWindowSize.width ? minWindowSize.width : w,
    h < minWindowSize.height ? minWindowSize.height : h,
  );
  if (screens.isEmpty) return r; // schermi sconosciuti: ci si fida
  final grip = Rect.fromLTWH(r.left, r.top, r.width, 40);
  final visible = screens.any((s) {
    final i = s.intersect(grip);
    return i.width >= 120 && i.height >= 20;
  });
  return visible ? r : null;
}

/// Preferenza da salvare per [bounds].
Map<String, Object?> boundsPref(Rect bounds, {required bool maximized}) => {
  'x': bounds.left.round(),
  'y': bounds.top.round(),
  'w': bounds.width.round(),
  'h': bounds.height.round(),
  'max': maximized,
};

final class DesktopWindow with WindowListener implements WindowService {
  DesktopWindow._();

  /// Inizializza il plugin; lancia se non è disponibile.
  static Future<DesktopWindow> create() async {
    await windowManager.ensureInitialized();
    final w = DesktopWindow._();
    windowManager.addListener(w);
    await windowManager.setPreventClose(true);
    return w;
  }

  Future<bool> Function()? _onClose;
  void Function(Map<String, Object?>)? _saveBounds;
  Timer? _saveTimer;
  Rect? _normal;

  /// Se c'è un'icona nella barra di sistema da cui riaprire la finestra:
  /// senza, "nascondi" riduce a icona (altrimenti l'app sparirebbe).
  bool Function() trayAvailable = () => false;

  /// Chiamato quando la chiusura è confermata, prima di distruggere la
  /// finestra (si chiudono l'icona e il lock dell'istanza).
  Future<void> Function()? beforeQuit;

  /// Dimensione, posizione e stato salvati; mostra la finestra a meno che
  /// [hidden] (avvio con il sistema: resta nella barra di sistema).
  Future<void> setup({
    required Object? saved,
    required List<Rect> screens,
    required void Function(Map<String, Object?>) save,
    required String title,
    bool hidden = false,
  }) async {
    _saveBounds = save;
    final bounds = restorableBounds(saved, screens);
    _normal = bounds;
    final options = WindowOptions(
      size: bounds?.size ?? defaultWindowSize,
      minimumSize: minWindowSize,
      center: bounds == null,
      title: title,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () {});
    if (bounds != null) await windowManager.setBounds(bounds);
    if (saved is Map && saved['max'] == true) await windowManager.maximize();
    if (hidden && trayAvailable()) {
      await windowManager.hide();
    } else {
      await show();
    }
  }

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<bool> get isMaximized => windowManager.isMaximized();

  @override
  Future<void> hide() async {
    if (trayAvailable()) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  @override
  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  set onCloseRequested(Future<bool> Function()? handler) => _onClose = handler;

  /// Chiusura chiesta dal sistema (Alt+F4, Cmd+Q, menu del dock) o da "Esci"
  /// nella barra di sistema: se il gestore dice di no (sessione in corso e
  /// l'utente annulla) non succede niente.
  Future<void> requestQuit() async {
    final ok = await (_onClose?.call() ?? Future.value(true));
    if (!ok) return;
    await _flushBounds();
    await beforeQuit?.call();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() => unawaited(requestQuit());

  @override
  void onWindowResized() => _scheduleSave();
  @override
  void onWindowMoved() => _scheduleSave();
  // Su Linux arrivano solo gli eventi "durante".
  @override
  void onWindowResize() => _scheduleSave();
  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () => unawaited(_flushBounds()));
  }

  Future<void> _flushBounds() async {
    _saveTimer?.cancel();
    final save = _saveBounds;
    if (save == null) return;
    try {
      if (await windowManager.isMinimized()) return;
      final max = await windowManager.isMaximized();
      // Da massimizzata si salva il rettangolo di prima, così togliendo la
      // massimizzazione al prossimo avvio si torna lì.
      if (!max) _normal = await windowManager.getBounds();
      final r = _normal ?? await windowManager.getBounds();
      save(boundsPref(r, maximized: max));
    } on Object {
      // finestra già distrutta
    }
  }
}

/// Su Linux, senza cornice del sistema, i bordi per ridimensionare li
/// disegna l'app; altrove restano quelli nativi.
Widget resizableFrame(Widget child) {
  if (!Platform.isLinux) return child;
  return Directionality(
    textDirection: TextDirection.ltr,
    child: DragToResizeArea(resizeEdgeSize: 6, child: child),
  );
}
