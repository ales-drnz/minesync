// Interfaccia dell'hub per la web UI: tutto il contratto API v1 che serve
// al browser (protocol.md, "Endpoints" e "Hub web, Admin area and extras
// endpoints"). Le pagine parlano solo con HubApi; nel browser c'è
// HttpHubApi, nei test un finto in memoria con dati di esempio.
import 'package:ms_protocol/ms_protocol.dart';

import 'pack_file.dart';

export 'pack_file.dart';

/// L'hub non risponde (rete, ZeroTier spento, hub fermo).
final class HubOffline implements Exception {
  const HubOffline(this.reason);
  final String reason;

  @override
  String toString() => 'HubOffline: $reason';
}

/// Una pagina di eventi (`GET /events?after=…` o `?before=…`).
final class EventPage {
  const EventPage({required this.events, this.last = 0, this.oldest, this.more = false});

  /// Con `after` dal più vecchio; con `before` dal più nuovo (come l'hub).
  final List<HubEvent> events;

  /// Ultimo seq pubblicato dall'hub.
  final int last;

  /// Seq più vecchio ancora su disco.
  final int? oldest;

  /// Con `before`: ci sono eventi ancora più vecchi.
  final bool more;

  factory EventPage.fromJson(Object? j) {
    if (j is! Map<String, Object?>) throw const FormatException('events: atteso un oggetto');
    final list = j['events'];
    if (list is! List<Object?>) throw const FormatException('events: attesa una lista');
    return EventPage(
      events: [for (final e in list) HubEvent.fromJson(e)],
      last: j['last'] is int ? j['last']! as int : 0,
      oldest: j['oldest'] is int ? j['oldest']! as int : null,
      more: j['more'] == true,
    );
  }
}

/// Modifica di uno spazio (`PATCH /spaces/{id}`, admin): solo i campi
/// presenti cambiano.
final class SpacePatch {
  const SpacePatch({this.name, this.exclusions, this.overrides});

  final String? name;

  /// Esclusioni proprie dello spazio (sostituiscono le precedenti).
  final List<String>? exclusions;

  /// Sovrascritture per sezione (`sessions`, `history`, `protection`);
  /// `{}` per una sezione = eredita.
  final Map<String, Object?>? overrides;

  Map<String, Object?> toJson() => {
    'name': ?name,
    'exclusions': ?exclusions,
    'overrides': ?overrides,
  };
}

/// Cancellazione di una generazione: quante e quanti byte liberati.
typedef GenerationDeleted = ({int deleted, int bytes});

/// L'hub visto dalla web UI. Ogni metodo lancia [ApiError] (codici di
/// ms_protocol) se l'hub risponde con un errore e [HubOffline] se non
/// risponde.
abstract interface class HubApi {
  // --- hub e spazi --------------------------------------------------------

  /// `GET /hub`: nome, versione, disco, chi chiama. 401
  /// `unauthenticated` = il dispositivo non è nella rete.
  Future<HubInfo> hub();

  Future<List<SpaceSummary>> spaces();

  /// `POST /spaces` (admin).
  Future<SpaceDetails> createSpace(String name, Profile profile);

  Future<SpaceDetails> space(String id);

  /// `PATCH /spaces/{id}` (admin): rinomina, esclusioni, sovrascritture.
  Future<SpaceDetails> updateSpace(String id, SpacePatch patch);

  /// `DELETE /spaces/{id}` (admin; rifiutato con un lock vivo).
  Future<void> deleteSpace(String id);

  // --- metadati della HEAD ------------------------------------------------

  Future<WorldInfo> world(String id);

  /// `server-icon.png` della HEAD (404 se non c'è).
  Uri iconUrl(String id);

  Future<PlayerList> players(String id);
  Future<ModList> mods(String id);

  /// Icona di un jar (404 se non c'è).
  Uri modIconUrl(String id, String file);

  Future<SpaceStats> stats(String id);

  // --- pacchetto per i giocatori --------------------------------------------

  /// `GET /spaces/{id}/pack`: il pacchetto della HEAD (`available: false`
  /// senza minesync-pack.json, es. un server vanilla).
  Future<ClientPack> pack(String id);

  /// `/spaces/{id}/pack.mrpack`: si scarica con un link.
  Uri packUrl(String id);

  /// `/spaces/{id}/pack-mods.zip`: solo le mod per i giocatori.
  Uri packModsUrl(String id);

  /// Il minesync-pack.json della HEAD (manifest + blob), per il lato di ogni
  /// mod; null se non c'è o non si legge.
  Future<PackFile?> packFile(String id);

  // --- storia -------------------------------------------------------------

  /// Dalla più nuova; [before] per le pagine successive.
  Future<List<GenerationSummary>> generations(String id, {int? before, int? limit});

  /// Generazione [n] con il manifest, o la HEAD se null.
  Future<Generation> generation(String id, {int? n});

  Future<GenerationChanges> diff(String id, int n, {int? limit});

  /// ZIP della generazione [n] (o della HEAD): si scarica con un link.
  Uri zipUrl(String id, {int? n});

  /// Byte che si libererebbero cancellando [n] (admin).
  Future<int> freed(String id, int n);

  /// Cancella una generazione non HEAD (admin, irreversibile).
  Future<GenerationDeleted> deleteGeneration(String id, int n);

  /// Nuova HEAD uguale alla generazione [n] (admin).
  Future<GenerationSummary> restore(String id, int n, {String message = ''});

  /// Ripristina un solo file (admin).
  Future<GenerationSummary> restoreFile(String id, RestoreFileRequest request);

  // --- lock ---------------------------------------------------------------

  /// Rilascio forzato del lock di un altro (admin).
  Future<void> forceReleaseLock(String id);

  /// Rilancia il test della porta (409 `not_locked`, `feature_off`, 429).
  Future<PortCheck> portCheck(String id);

  // --- pulizia e spazio ---------------------------------------------------

  /// Anteprima della pulizia di [space] o di tutto l'hub (admin): con
  /// [keep] manuale, con [history] regole in bozza, senza nessuno dei due le
  /// regole salvate.
  Future<GcPreview> gcPreview({String? space, int? keep, HistorySettings? history});

  /// Pulizia ora (admin).
  Future<GcReport> gc({String? space, int? keep});

  Future<HubUsage> usage();

  /// Prova un percorso contro le esclusioni (admin).
  Future<ExclusionTest> testExclusion({
    required String path,
    Profile? profile,
    String? spaceId,
    List<String>? patterns,
  });

  // --- membri, sistema, impostazioni (admin) ------------------------------

  Future<MemberList> members();
  Future<MemberInfo> setRole(String memberId, MemberRole role);

  /// Rilegge subito i membri da ZTNET ("controlla ora").
  Future<ZtnetStatus> refreshMembers();

  Future<SystemInfo> system();
  Future<HubSettings> settings();

  /// `PATCH /settings/{section}` con i soli campi cambiati.
  Future<HubSettings> patchSettings(String section, Map<String, Object?> fields);

  // --- Telegram (admin) ---------------------------------------------------

  Future<TelegramStatus> telegram();
  Future<TelegramStatus> patchTelegram(TelegramPatch patch);

  /// Messaggio di prova; i valori passati si provano senza salvarli.
  Future<TelegramTestResult> testTelegram({
    String? token,
    String? chat,
    String? language,
    String? spaceId,
    String? topic,
  });

  /// Chat viste dal bot ("Trova chat").
  Future<List<TelegramChat>> findTelegramChats({String? token});

  // --- download -----------------------------------------------------------

  Future<DlListing> downloads();

  /// `/dl/<file>`, fuori da /api/v1.
  Uri downloadUrl(String file);

  // --- eventi -------------------------------------------------------------

  /// `GET /events`: con [after] i nuovi dal più vecchio, con [before] i
  /// precedenti dal più nuovo. [space] e [types] filtrano.
  Future<EventPage> events({
    int? after,
    int? before,
    int? limit,
    String? space,
    List<String>? types,
  });

  /// Eventi dal vivo (SSE). Non finisce da solo: si riconnette e riprende
  /// da dopo l'ultimo seq visto. Gli errori di connessione arrivano come
  /// errori dello stream (che resta aperto); si chiude cancellando.
  Stream<HubEvent> eventStream({int? after});
}
