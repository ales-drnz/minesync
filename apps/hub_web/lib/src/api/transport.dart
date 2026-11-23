// Trasporto HTTP e SSE dell'hub web, astratto: nel browser è fetch +
// EventSource (browser_transport.dart), nei test un finto in memoria. Così
// la decodifica e la riconnessione si provano sulla VM, senza browser.

/// Risposta HTTP: stato e corpo già letto come testo.
final class TransportResponse {
  const TransportResponse(this.status, this.body, {this.headers = const {}});

  final int status;
  final String body;

  /// Intestazioni con nome in minuscolo.
  final Map<String, String> headers;
}

/// La richiesta non è arrivata all'hub (rete, timeout, hub spento).
final class TransportFailure implements Exception {
  const TransportFailure(this.reason);
  final String reason;

  @override
  String toString() => 'TransportFailure: $reason';
}

/// Chi riceve gli eventi di una connessione SSE.
abstract interface class EventSourceListener {
  /// La connessione è aperta (anche dopo una riconnessione del browser).
  void onOpen();

  /// Un messaggio: `id:` (null se assente) e `data:`.
  void onMessage(String? id, String data);

  /// Errore. [closed]: il browser non riproverà da solo (es. risposta
  /// HTTP di errore); altrimenti sta già riprovando con `Last-Event-ID`.
  void onError({required bool closed});
}

/// Una connessione SSE aperta.
abstract interface class EventSourceConnection {
  void close();
}

/// Trasporto verso l'hub.
abstract interface class HubTransport {
  /// Una richiesta. [body] è JSON già codificato. Lancia
  /// [TransportFailure] se l'hub non risponde.
  Future<TransportResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  });

  /// Apre uno stream SSE su [url]. [eventTypes] sono i nomi `event:` da
  /// ascoltare oltre ai messaggi senza nome.
  EventSourceConnection openEvents(
    Uri url,
    EventSourceListener listener, {
    List<String> eventTypes = const [],
  });
}
