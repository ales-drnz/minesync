// Come appare il lock di un server: libero, in gioco, stale. Usato dalle
// card della Panoramica e dalla pagina Server.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';

enum LockView { free, play, stale }

LockView lockViewOf(SpaceSummary sp) {
  final l = sp.lock;
  if (l == null) return LockView.free;
  return l.stale ? LockView.stale : LockView.play;
}

/// Il server è aperto in gioco adesso (lock vivo di una sessione, non di
/// un salvataggio dall'app).
bool isOpenNow(SpaceSummary sp) {
  final l = sp.lock;
  return l != null && !l.stale && l.info.action != 'push';
}

/// Il lock di [sp] come [MsLock].
Widget lockBadge(BuildContext context, SpaceSummary sp, {bool big = false}) {
  final s = context.s.overview;
  final l = sp.lock;
  return switch (lockViewOf(sp)) {
    LockView.free => MsLock(label: s.lockFree, big: big),
    LockView.play => MsLock(label: s.lockPlay, state: MsLockState.play, meta: l!.name, big: big),
    LockView.stale => MsLock(label: s.lockStale, state: MsLockState.stale, meta: l!.name, big: big),
  };
}

/// Minecraft 1.21.1, Fabric, 42 mod: i dati del chip della HEAD, da
/// mostrare come etichette ([MsMeta]).
List<String> worldItems(WebStrings s, SpaceSummary sp) {
  final o = s.overview;
  if (sp.profile == Profile.generic) return [o.genericFolder];
  final w = sp.world;
  return [
    o.minecraft(w?.mcVersion),
    if (w?.loader case final l? when l != Loader.vanilla) o.loader(loaderName(l), null),
    if (w?.loader == Loader.vanilla) 'vanilla',
    if (w != null && w.mods > 0) o.mods(w.mods),
  ];
}

String loaderName(Loader l) => switch (l) {
  Loader.vanilla => 'vanilla',
  Loader.fabric => 'Fabric',
  Loader.quilt => 'Quilt',
  Loader.forge => 'Forge',
  Loader.neoforge => 'NeoForge',
  Loader.paper => 'Paper',
};
