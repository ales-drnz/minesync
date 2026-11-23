// Codici di errore dell'API: stato HTTP e nome sul filo. I client traducono
// dal codice; il messaggio inglese serve solo ai log.

enum ErrorCode {
  badRequest(400, 'bad_request'),
  badPath(400, 'bad_path'),
  unauthenticated(401, 'unauthenticated'),
  forbidden(403, 'forbidden'),
  notFound(404, 'not_found'),
  spaceGone(404, 'space_gone'),
  staleBase(409, 'stale_base'),
  massDelete(409, 'mass_delete'),
  locked(409, 'locked'),
  lockLost(409, 'lock_lost'),
  pushIncomplete(409, 'push_incomplete'),
  pushExpired(410, 'push_expired'),
  tooLarge(413, 'too_large'),
  isHead(409, 'is_head'),
  blobsMissing(409, 'blobs_missing'),
  notLocked(409, 'not_locked'),
  featureOff(409, 'feature_off'),
  fromConfig(409, 'from_config'),
  lastAdmin(409, 'last_admin'),
  badHash(422, 'bad_hash'),
  rateLimited(429, 'rate_limited'),
  upstream(502, 'upstream'),
  diskFull(507, 'disk_full'),
  internal(500, 'internal');

  const ErrorCode(this.status, this.wire);

  final int status;
  final String wire;

  static ErrorCode? fromWire(String s) {
    for (final c in values) {
      if (c.wire == s) return c;
    }
    return null;
  }
}

/// Errore dell'API, come viaggia nel corpo della risposta.
final class ApiError implements Exception {
  const ApiError(this.code, this.message, {this.details = const {}, this.status});

  /// Decodifica `{"error": {...}}`. [status] è lo stato HTTP ricevuto.
  factory ApiError.fromJson(Object? json, {int? status}) {
    final e = json is Map<String, Object?> ? json['error'] : null;
    if (e is! Map<String, Object?>) {
      return ApiError(ErrorCode.internal, 'risposta di errore non valida', status: status);
    }
    final code = ErrorCode.fromWire(e['code'] as String? ?? '') ?? ErrorCode.internal;
    final details = e['details'];
    return ApiError(
      code,
      e['message'] as String? ?? '',
      details: details is Map<String, Object?> ? details : const {},
      status: status,
    );
  }

  final ErrorCode code;
  final String message;
  final Map<String, Object?> details;

  /// Stato HTTP ricevuto (lato client); lato hub vale [ErrorCode.status].
  final int? status;

  int get httpStatus => status ?? code.status;

  Map<String, Object?> toJson() => {
    'error': {'code': code.wire, 'message': message, if (details.isNotEmpty) 'details': details},
  };

  @override
  String toString() => 'ApiError(${code.wire}): $message';
}
