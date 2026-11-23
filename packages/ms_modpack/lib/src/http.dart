// Trasporto HTTP astratto: i modelli e il client Modrinth restano puro Dart
// (anche web); lib/io.dart dà l'implementazione con dart:io, i test un
// falso. Mai rete vera nei test.
import 'dart:async';
import 'dart:typed_data';

/// Una richiesta.
final class HttpReq {
  const HttpReq(this.method, this.url, {this.headers = const {}, this.body});

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;

  @override
  String toString() => '$method $url';
}

/// Una risposta con il corpo in streaming.
final class HttpRes {
  HttpRes(this.status, Map<String, String> headers, this.body, {this.contentLength})
    : headers = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

  /// Risposta con il corpo già in memoria (per i falsi dei test).
  factory HttpRes.bytes(int status, List<int> body, {Map<String, String> headers = const {}}) =>
      HttpRes(status, headers, Stream.value(body), contentLength: body.length);

  final int status;

  /// Intestazioni con il nome in minuscolo.
  final Map<String, String> headers;
  final Stream<List<int>> body;

  /// Lunghezza dichiarata, se nota.
  final int? contentLength;

  bool get ok => status >= 200 && status < 300;

  /// Tutto il corpo, al più [max] byte ([HttpBodyTooLarge] oltre).
  Future<Uint8List> readAll({int max = 64 << 20}) async {
    final b = BytesBuilder(copy: false);
    await for (final c in body) {
      b.add(c);
      if (b.length > max) throw HttpBodyTooLarge(max);
    }
    return b.takeBytes();
  }

  /// Scarta il corpo.
  Future<void> drain() => body.drain<void>().catchError((Object _) {});
}

/// Corpo più grande del tetto.
final class HttpBodyTooLarge implements Exception {
  const HttpBodyTooLarge(this.max);
  final int max;
  @override
  String toString() => 'HttpBodyTooLarge($max)';
}

/// Errore di rete (connessione rifiutata, DNS, timeout): il servizio non
/// risponde.
final class HttpUnavailable implements Exception {
  const HttpUnavailable(this.url, this.cause);
  final Uri url;
  final Object cause;
  @override
  String toString() => 'HttpUnavailable($url): $cause';
}

/// Il trasporto. Lancia [HttpUnavailable] se non c'è risposta.
abstract interface class HttpTransport {
  Future<HttpRes> send(HttpReq req);
}
