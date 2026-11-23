// Dati di un server condivisi tra le schede: dettaglio (impostazioni,
// esclusioni, spazio), mondo della HEAD e statistiche delle sessioni.
// Restano in memoria passando da una scheda all'altra e si rileggono da soli
// quando dal vivo cambia la HEAD (nuovo salvataggio) o il lock (sessione
// aperta o chiusa). Pezzi comuni alle schede: conteggi +~−, copia, numeri.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../api/hub_api.dart';
import '../../l10n/l10n.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';

/// Stato di un caricamento: valore, errore o in corso.
final class Loaded<T> {
  const Loaded._(this.value, this.error);
  const Loaded.loading() : this._(null, null);

  final T? value;
  final Object? error;

  bool get loading => value == null && error == null;
}

final class ServerData extends ChangeNotifier {
  ServerData._(this.api, this.id);

  final HubApi api;
  final String id;

  static final _cache = Expando<Map<String, ServerData>>();

  /// I dati di [id] per lo stato [app] (uno per server, finché vive lo stato).
  static ServerData of(HubState app, String id) =>
      (_cache[app] ??= <String, ServerData>{})[id] ??= ServerData._(app.api, id);

  Loaded<SpaceDetails> details = const Loaded.loading();
  Loaded<WorldInfo> world = const Loaded.loading();
  Loaded<SpaceStats> stats = const Loaded.loading();

  bool _started = false;
  String? _head;
  String? _lock;

  /// Allinea i dati al riassunto dal vivo [sp]: rilegge quello che è
  /// cambiato. Si chiama a ogni build della pagina (costa un confronto).
  void sync(SpaceSummary? sp) {
    final head = sp?.headDigest;
    final l = sp?.lock;
    final lock = l == null ? '' : '${l.memberId}/${l.since}/${l.stale}';
    if (!_started) {
      _started = true;
      _head = head;
      _lock = lock;
      reload();
      return;
    }
    if (sp == null) return;
    if (head != _head) {
      _head = head;
      _lock = lock;
      reload();
    } else if (lock != _lock) {
      _lock = lock;
      _load(() => api.stats(id), (v) => stats = v);
      _load(() => api.space(id), (v) => details = v);
    }
  }

  /// Rilegge tutto.
  Future<void> reload() => Future.wait([
    _load(() => api.space(id), (v) => details = v),
    _load(() => api.world(id), (v) => world = v),
    _load(() => api.stats(id), (v) => stats = v),
  ]);

  /// Rilegge solo il dettaglio (dopo una modifica dall'Amministrazione).
  Future<void> reloadDetails() => _load(() => api.space(id), (v) => details = v);

  /// Sostituisce il dettaglio con la risposta di un PATCH.
  void setDetails(SpaceDetails d) {
    details = Loaded._(d, null);
    notifyListeners();
  }

  Future<void> _load<T>(Future<T> Function() f, void Function(Loaded<T>) set) async {
    try {
      final v = await f();
      set(Loaded._(v, null));
    } on Object catch (e) {
      set(Loaded._(null, e));
    }
    notifyListeners();
  }
}

/// Fornisce i dati del server alle schede.
class ServerDataScope extends InheritedNotifier<ServerData> {
  const ServerDataScope({super.key, required ServerData data, required super.child})
    : super(notifier: data);

  static ServerData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServerDataScope>()!.notifier!;
}

/// Ore intere da millisecondi ("61 h"); sotto l'ora la durata breve.
String hoursOf(FormatStrings f, int ms) {
  final d = Duration(milliseconds: ms);
  return d.inHours < 1 ? f.duration(d) : '${d.inHours} h';
}

/// "+2 ~31 −0" colorati, con la frase per gli screen reader.
class ChangeCounts extends StatelessWidget {
  const ChangeCounts({super.key, required this.stats});
  final GenerationStats stats;

  @override
  Widget build(BuildContext context) {
    final s = context.s.server;
    return Semantics(
      label: s.changesLabel(stats.added, stats.changed, stats.removed),
      excludeSemantics: true,
      child: MsRow(
        gap: 6,
        wrap: false,
        children: [
          MsText.mono('+${stats.added}', tone: MsTextTone.ok),
          MsText.mono('~${stats.changed}', tone: MsTextTone.warn),
          MsText.mono('−${stats.removed}', tone: MsTextTone.err),
        ],
      ),
    );
  }
}

/// Un valore da copiare: testo mono e pulsante "Copia".
class CopyValue extends StatelessWidget {
  const CopyValue({super.key, required this.value, required this.copyLabel, this.strong = false});

  final String value;

  /// Etichetta per gli screen reader ("Copia indirizzo fisso").
  final String copyLabel;
  final bool strong;

  @override
  Widget build(BuildContext context) => MsRow(
    gap: 8,
    children: [
      MsText.mono(value, weight: strong ? 700 : null),
      MsButton(
        label: context.s.common.copy,
        size: MsButtonSize.sm,
        icon: const MsIcon(MsIcons.copy),
        semanticLabel: copyLabel,
        onPressed: () => copyText(context, value),
      ),
    ],
  );
}

/// Riquadro di caricamento o di errore con "Riprova".
class LoadState extends StatelessWidget {
  const LoadState({super.key, required this.error, required this.onRetry, this.title});

  final Object? error;
  final VoidCallback onRetry;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    if (error == null) {
      return const MsStack(
        gap: 12,
        children: [MsSkeleton.title(), MsSkeleton.text(), MsSkeleton.short()],
      );
    }
    return MsAlert(
      tone: MsAlertTone.err,
      title: title ?? s.server.loadError,
      text: errorText(s, error!),
      actions: [
        MsButton(
          label: s.common.retry,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.refresh),
          onPressed: onRetry,
        ),
      ],
    );
  }
}

/// Il lock è vivo (qualcuno ospita o salva adesso).
bool liveLock(SpaceSummary? sp) => sp?.lock != null && !sp!.lock!.stale;
