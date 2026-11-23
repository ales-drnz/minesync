// Testi comuni a tutte le pagine: errori dell'hub per codice (lo switch è
// esaustivo: un codice nuovo in ms_protocol non compila finché non ha il
// suo testo), azioni ricorrenti, conferme.
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';

abstract final class CommonStrings {
  static CommonStrings of(Lang l) => switch (l) {
    Lang.it => const _It(),
    Lang.en => const _En(),
  };

  /// Testo per l'utente di un errore dell'hub. [details] è
  /// `ApiError.details` (es. chi tiene il lock).
  String apiError(ErrorCode code, Map<String, Object?> details);

  String get offlineError;
  String unexpected(String what);

  String get cancel;
  String get confirm;
  String get save;
  String get copy;
  String get retry;
  String get loading;

  /// "Per confermare scrivi `nome` qui sotto".
  String get typeBefore;
  String get typeAfter;
}

String? _who(Map<String, Object?> d) {
  final l = d['lock'];
  return l is Map<String, Object?> ? l['name'] as String? : null;
}

Object? _d(Map<String, Object?> d, String k) => d[k] ?? '?';

final class _It implements CommonStrings {
  const _It();
  @override
  String apiError(ErrorCode code, Map<String, Object?> details) => switch (code) {
    ErrorCode.badRequest =>
      details['field'] != null ? 'Valore non valido: ${details['field']}' : 'Richiesta non valida',
    ErrorCode.badPath => 'Percorso non valido: ${_d(details, 'path')}',
    ErrorCode.unauthenticated => 'Questo dispositivo non è nella rete dell\'hub',
    ErrorCode.forbidden => 'Solo un admin può farlo',
    ErrorCode.notFound => 'Non trovato: potrebbe essere stato eliminato',
    ErrorCode.spaceGone => 'Questo server è stato eliminato',
    ErrorCode.staleBase => 'Un altro salvataggio è arrivato nel frattempo. Ricarica e riprova',
    ErrorCode.massDelete => 'Il salvataggio toglierebbe troppi file',
    ErrorCode.locked =>
      _who(details) == null
          ? 'Qualcuno sta giocando su questo server'
          : '${_who(details)} sta giocando su questo server',
    ErrorCode.lockLost => 'Il lock non appartiene più a questo dispositivo',
    ErrorCode.pushIncomplete => 'Salvataggio incompleto',
    ErrorCode.pushExpired => 'Salvataggio scaduto',
    ErrorCode.tooLarge => 'Troppo grande per l\'hub',
    ErrorCode.isHead => 'Non si può fare sulla versione attuale',
    ErrorCode.blobsMissing => 'Mancano dei file sull\'hub: questa versione non è completa',
    ErrorCode.notLocked => 'Il server non è aperto',
    ErrorCode.featureOff => 'Funzione disattivata nelle impostazioni dell\'hub',
    ErrorCode.fromConfig => 'Questo admin è fissato nella configurazione dell\'hub',
    ErrorCode.lastAdmin => 'Serve almeno un admin',
    ErrorCode.badHash => 'File ricevuto danneggiato',
    ErrorCode.rateLimited => 'Troppe richieste: riprova tra qualche secondo',
    ErrorCode.upstream =>
      details['error'] != null
          ? 'Errore del servizio esterno: ${details['error']}'
          : 'Il servizio esterno non risponde',
    ErrorCode.diskFull => 'Il disco dell\'hub è pieno',
    ErrorCode.internal => 'Errore interno dell\'hub',
  };
  @override
  String get offlineError => 'L\'hub non risponde';
  @override
  String unexpected(String what) => 'Errore inatteso: $what';
  @override
  String get cancel => 'Annulla';
  @override
  String get confirm => 'Conferma';
  @override
  String get save => 'Salva';
  @override
  String get copy => 'Copia';
  @override
  String get retry => 'Riprova';
  @override
  String get loading => 'Caricamento…';
  @override
  String get typeBefore => 'Per confermare scrivi ';
  @override
  String get typeAfter => ' qui sotto';
}

final class _En implements CommonStrings {
  const _En();
  @override
  String apiError(ErrorCode code, Map<String, Object?> details) => switch (code) {
    ErrorCode.badRequest =>
      details['field'] != null ? 'Invalid value: ${details['field']}' : 'Invalid request',
    ErrorCode.badPath => 'Invalid path: ${_d(details, 'path')}',
    ErrorCode.unauthenticated => 'This device is not on the hub\'s network',
    ErrorCode.forbidden => 'Only an admin can do this',
    ErrorCode.notFound => 'Not found: it may have been deleted',
    ErrorCode.spaceGone => 'This server was deleted',
    ErrorCode.staleBase => 'Another save arrived in the meantime. Reload and retry',
    ErrorCode.massDelete => 'The save would remove too many files',
    ErrorCode.locked =>
      _who(details) == null
          ? 'Someone is playing on this server'
          : '${_who(details)} is playing on this server',
    ErrorCode.lockLost => 'The lock no longer belongs to this device',
    ErrorCode.pushIncomplete => 'Incomplete save',
    ErrorCode.pushExpired => 'Save expired',
    ErrorCode.tooLarge => 'Too large for the hub',
    ErrorCode.isHead => 'Not allowed on the current version',
    ErrorCode.blobsMissing => 'Files are missing on the hub: this version is incomplete',
    ErrorCode.notLocked => 'The server is not open',
    ErrorCode.featureOff => 'Feature turned off in the hub settings',
    ErrorCode.fromConfig => 'This admin is set in the hub configuration',
    ErrorCode.lastAdmin => 'At least one admin is needed',
    ErrorCode.badHash => 'File received damaged',
    ErrorCode.rateLimited => 'Too many requests: retry in a few seconds',
    ErrorCode.upstream =>
      details['error'] != null
          ? 'External service error: ${details['error']}'
          : 'The external service is not responding',
    ErrorCode.diskFull => 'The hub\'s disk is full',
    ErrorCode.internal => 'Internal hub error',
  };
  @override
  String get offlineError => 'The hub is not responding';
  @override
  String unexpected(String what) => 'Unexpected error: $what';
  @override
  String get cancel => 'Cancel';
  @override
  String get confirm => 'Confirm';
  @override
  String get save => 'Save';
  @override
  String get copy => 'Copy';
  @override
  String get retry => 'Retry';
  @override
  String get loading => 'Loading…';
  @override
  String get typeBefore => 'To confirm, type ';
  @override
  String get typeAfter => ' below';
}
