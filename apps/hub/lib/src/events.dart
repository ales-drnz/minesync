// Registro degli eventi: file JSON lines in sola aggiunta sotto events/,
// con seq crescente anche dopo un riavvio. Gli ultimi eventi restano in
// memoria per GET /events e per riprendere uno stream SSE.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

import 'clock.dart';
import 'mutex.dart';

final class EventLog {
  EventLog(
    this.dir, {
    required Clock clock,
    this.memory = 1000,
    this.segmentEvents = 10000,
    this.keepSegments = 20,
  }) : _clock = clock;

  final String dir;
  final Clock _clock;

  /// Eventi tenuti in memoria.
  final int memory;

  /// Eventi per file prima di passare al successivo.
  final int segmentEvents;

  /// File conservati (i più vecchi si cancellano).
  final int keepSegments;

  final _ring = <HubEvent>[];
  final _live = StreamController<HubEvent>.broadcast(sync: true);
  final _io = Mutex();
  int _seq = 0;
  RandomAccessFile? _file;
  int _inSegment = 0;

  int get lastSeq => _seq;

  /// Primo seq di ogni file su disco, in ordine (dal nome del file).
  final _segFirst = <int>[];

  /// Eventi nuovi, appena pubblicati.
  Stream<HubEvent> get live => _live.stream;

  Future<void> open() async {
    await Directory(dir).create(recursive: true);
    final segs = await _segments();
    _segFirst.addAll(segs.map(_firstOf));
    // ricarica gli ultimi eventi; righe rovinate (scrittura interrotta) si saltano
    final loaded = <HubEvent>[];
    for (final f in segs.reversed) {
      final evs = <HubEvent>[];
      for (final line in await File(f).readAsLines()) {
        try {
          evs.add(HubEvent.fromJson(jsonDecode(line)));
        } catch (_) {
          // riga parziale o illeggibile
        }
      }
      if (f == segs.last) _inSegment = evs.length;
      loaded.insertAll(0, evs);
      if (loaded.length >= memory) break;
    }
    for (final e in loaded) {
      if (e.seq > _seq) _seq = e.seq;
    }
    final start = loaded.length > memory ? loaded.length - memory : 0;
    _ring.addAll(loaded.sublist(start));
    if (segs.isNotEmpty && _inSegment < segmentEvents) {
      _file = await File(segs.last).open(mode: FileMode.append);
    }
  }

  static int _firstOf(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    return int.tryParse(name.substring(0, name.length - '.jsonl'.length)) ?? 0;
  }

  Future<List<String>> _segments() async {
    final out = <String>[];
    await for (final e in Directory(dir).list()) {
      if (e is File && e.path.endsWith('.jsonl')) out.add(e.path);
    }
    out.sort();
    return out;
  }

  /// Pubblica un evento: subito in memoria e agli stream, poi su disco.
  HubEvent publish(
    String type, {
    String? space,
    String? actor,
    Map<String, Object?> data = const {},
  }) {
    final e = HubEvent(
      seq: ++_seq,
      ts: _clock.wallMs(),
      type: type,
      space: space,
      actor: actor,
      data: data,
    );
    _ring.add(e);
    if (_ring.length > memory) _ring.removeRange(0, _ring.length - memory);
    _io.run(() => _append(e)).ignore();
    if (!_live.isClosed) _live.add(e);
    return e;
  }

  Future<void> _append(HubEvent e) async {
    try {
      if (_file == null || _inSegment >= segmentEvents) {
        await _file?.close();
        final name = '$dir/${e.seq.toString().padLeft(12, '0')}.jsonl';
        _file = await File(name).open(mode: FileMode.append);
        _inSegment = 0;
        final segs = await _segments();
        for (var i = 0; i < segs.length - keepSegments; i++) {
          await File(segs[i]).delete();
        }
        _segFirst
          ..clear()
          ..addAll(
            segs.skip(segs.length > keepSegments ? segs.length - keepSegments : 0).map(_firstOf),
          );
      }
      await _file!.writeString('${jsonEncode(e.toJson())}\n');
      _inSegment++;
    } catch (err) {
      stderr.writeln('eventi: scrittura fallita: $err');
    }
  }

  static bool _match(HubEvent e, String? space, Set<String>? types) =>
      (space == null || e.space == space) && (types == null || types.contains(e.type));

  /// Eventi con seq > [after], al più [limit], in ordine; solo dello spazio
  /// [space] e dei tipi [types], se dati.
  List<HubEvent> after(int after, {int limit = 1000, String? space, Set<String>? types}) {
    final out = <HubEvent>[];
    for (final e in _ring) {
      if (e.seq > after && _match(e, space, types)) {
        out.add(e);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// Eventi con seq < [before], dal più recente, al più [limit]: prima dalla
  /// memoria, poi dai file su disco. [more] dice se ce ne sono di più vecchi.
  Future<({List<HubEvent> events, bool more})> before(
    int before, {
    int limit = 100,
    String? space,
    Set<String>? types,
  }) => _io.run(() async {
    final out = <HubEvent>[];
    for (var i = _ring.length - 1; i >= 0 && out.length <= limit; i--) {
      final e = _ring[i];
      if (e.seq < before && _match(e, space, types)) out.add(e);
    }
    // sotto il più vecchio in memoria si legge da disco
    var bound = _ring.isEmpty ? before : (_ring.first.seq < before ? _ring.first.seq : before);
    if (out.length <= limit) {
      final segs = await _segments();
      for (final f in segs.reversed) {
        if (out.length > limit) break;
        if (_firstOf(f) >= bound) continue;
        final evs = <HubEvent>[];
        try {
          for (final line in await File(f).readAsLines()) {
            try {
              final e = HubEvent.fromJson(jsonDecode(line));
              if (e.seq < bound && _match(e, space, types)) evs.add(e);
            } catch (_) {
              // riga parziale o illeggibile
            }
          }
        } on FileSystemException {
          continue; // file appena cancellato dalla rotazione
        }
        evs.sort((a, b) => b.seq.compareTo(a.seq));
        out.addAll(evs);
        bound = _firstOf(f);
      }
    }
    final more = out.length > limit;
    return (events: more ? out.sublist(0, limit) : out, more: more);
  });

  /// Il seq più vecchio ancora conservato (su disco o in memoria; 0 se
  /// nessuno).
  int get oldestSeq {
    if (_segFirst.isNotEmpty && _segFirst.first > 0) {
      final r = _ring.isEmpty ? _segFirst.first : _ring.first.seq;
      return r < _segFirst.first ? r : _segFirst.first;
    }
    return _ring.isEmpty ? 0 : _ring.first.seq;
  }

  Future<void> close() async {
    await _io.run(() async {
      await _file?.flush();
      await _file?.close();
      _file = null;
    });
    await _live.close();
  }
}
