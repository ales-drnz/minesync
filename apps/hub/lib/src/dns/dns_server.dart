// DNS autoritativo minimale per la zona dell'hub (B-DNS-01…07), senza
// dipendenze: UDP e, se la porta è libera, anche TCP.
//
//   zerotier.<spazio>.<zona>                 A    -> IP di chi ospita adesso
//   _minecraft._tcp.zerotier.<spazio>.<zona> SRV  -> 0 0 <porta> zerotier.<spazio>.<zona>
//                                                    + glue A in ADDITIONAL
//
// Le risposte leggono un'istantanea del lock (mai il mutex dello spazio): un
// commit lungo non rallenta il DNS. TTL 5 s, perché chi ospita cambia spesso.
// Orizzonte diviso: se chiede proprio chi ospita, riceve il suo indirizzo LAN.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart' show DnsStatus;

import '../members.dart' show canonicalIp;
import '../state.dart' show LockState, SpaceState;

/// TTL di ogni record (anche del caching negativo).
const int dnsTtl = 5;

const _typeA = 1, _typeSOA = 6, _typeSRV = 33, _classIN = 1;
const _rcOk = 0, _rcNxDomain = 3, _rcRefused = 5;

/// Chi ospita uno spazio, come lo vede il DNS.
final class DnsHost {
  const DnsHost({required this.ip, this.lan, this.port = 25565});

  /// Indirizzo visto sul socket (`LockHolder.ip`).
  final String ip;

  /// Indirizzo LAN pubblicato dal client (`LockInfo.lan`), solo per chi ospita.
  final String? lan;
  final int port;
}

/// Esito della ricerca di uno spazio: [exists] falso = NXDOMAIN; [host]
/// null = nessuno ospita.
typedef DnsEntry = ({bool exists, DnsHost? host});

/// Risolve un id di spazio (già minuscolo). Deve essere sincrona e veloce:
/// legge istantanee in memoria.
typedef DnsLookup = DnsEntry Function(String spaceId);

/// Adattatore per lo stato dell'hub: [space] restituisce lo stato in memoria
/// (null se lo spazio non esiste), [isStale] dice se un lock è scaduto.
DnsLookup lockLookup(SpaceState? Function(String id) space, bool Function(LockState l) isStale) {
  return (id) {
    final st = space(id);
    if (st == null || st.deleted) return (exists: false, host: null);
    final l = st.lock;
    if (l == null || l.ip == null || l.info.action != 'play' || isStale(l)) {
      return (exists: true, host: null);
    }
    return (exists: true, host: DnsHost(ip: l.ip!, lan: l.info.lan, port: l.info.port ?? 25565));
  };
}

/// Server DNS della zona [zone].
final class DnsServer {
  DnsServer({required String zone, required this.lookup, void Function(String)? log})
    : zone = zone.toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), ''),
      _log = log ?? ((m) => stderr.writeln(m));

  /// Zona servita, minuscola e senza punti ai lati.
  final String zone;
  final DnsLookup lookup;
  final void Function(String) _log;

  RawDatagramSocket? _udp;
  ServerSocket? _tcp;
  final _conns = <Socket>{};
  String? _addr;
  String? _error;

  /// Porta UDP effettiva (utile con la porta 0 nei test).
  int? get port => _udp?.port;

  /// Porta TCP, se il TCP è partito.
  int? get tcpPort => _tcp?.port;

  bool get running => _udp != null;

  /// Stato per la pagina Sistema.
  DnsStatus get status => DnsStatus(on: running, zone: zone, addr: _addr, error: _error);

  /// Si mette in ascolto. Non lancia mai: un bind fallito (porta 53 occupata,
  /// permessi) resta nello stato e l'hub continua senza DNS.
  Future<bool> start(InternetAddress address, int port) async {
    String fmt(int p) => address.type == InternetAddressType.IPv6
        ? '[${address.address}]:$p'
        : '${address.address}:$p';
    _addr = fmt(port);
    try {
      // senza SO_REUSEADDR: una porta già occupata deve dare errore
      final s = await RawDatagramSocket.bind(address, port, reuseAddress: false);
      _udp = s;
      _addr = fmt(s.port);
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          final out = answer(d!.data, d.address);
          if (out != null) s.send(out, d.address, d.port);
        }
      });
    } catch (e) {
      _error = '$e';
      _log('dns: avvio non riuscito su $_addr: $e');
      return false;
    }
    _error = null;
    try {
      // TCP sulla stessa porta (con la porta 0 quella scelta per l'UDP)
      final t = await ServerSocket.bind(address, _udp!.port);
      _tcp = t;
      t.listen(_serveTcp);
    } catch (e) {
      _log('dns: TCP non disponibile su $_addr: $e (resta solo UDP)');
    }
    return true;
  }

  Future<void> stop() async {
    _udp?.close();
    _udp = null;
    await _tcp?.close();
    _tcp = null;
    for (final c in _conns.toList()) {
      c.destroy();
    }
    _conns.clear();
  }

  /// Ogni messaggio TCP è preceduto dalla sua lunghezza su 2 byte.
  void _serveTcp(Socket c) {
    _conns.add(c);
    final buf = BytesBuilder();
    Timer? idle;
    void arm() {
      idle?.cancel();
      idle = Timer(const Duration(seconds: 10), c.destroy);
    }

    arm();
    c.listen(
      (chunk) {
        arm();
        buf.add(chunk);
        var data = buf.takeBytes();
        while (data.length >= 2) {
          final n = data[0] << 8 | data[1];
          if (data.length < 2 + n) break;
          final out = answer(Uint8List.sublistView(data, 2, 2 + n), c.remoteAddress);
          if (out != null) {
            c.add([out.length >> 8, out.length & 0xff, ...out]);
          }
          data = Uint8List.sublistView(data, 2 + n);
        }
        if (data.length > 4096) {
          c.destroy(); // nessuna query è così lunga
          return;
        }
        buf.add(data);
      },
      onDone: () {
        idle?.cancel();
        _conns.remove(c);
        c.destroy();
      },
      onError: (Object _) {
        idle?.cancel();
        _conns.remove(c);
        c.destroy();
      },
      cancelOnError: true,
    );
  }

  /// Risposta a una query, o null per scartarla in silenzio: messaggi
  /// malformati, risposte (QR=1), opcode diversi da QUERY, classi non IN
  /// (niente riflessione né amplificazione, B-DNS-06).
  Uint8List? answer(Uint8List req, InternetAddress from) {
    if (req.length < 12) return null;
    if (req[2] & 0x80 != 0 || (req[2] >> 3) & 0x0f != 0) return null;
    final qd = req[4] << 8 | req[5];
    if (qd != 1) return null;
    final q = _question(req);
    if (q == null || q.qclass != _classIN) return null;
    final r = _Reply(req[0], req[1], rd: req[2] & 0x01 != 0, question: q.raw);

    final labels = [for (final l in q.labels) l.toLowerCase()];
    final zl = zone.split('.');
    if (labels.length < zl.length || !_endsWith(labels, zl)) {
      r.rcode = _rcRefused; // non è roba nostra (B-DNS-05)
      return r.bytes();
    }
    var core = labels.sublist(0, labels.length - zl.length);
    final srv = core.length >= 2 && core[0] == '_minecraft' && core[1] == '_tcp';
    if (srv) core = core.sublist(2);
    if (core.length != 2 || core[0] != 'zerotier') {
      r.rcode = _rcNxDomain;
      return r.finish(zone);
    }
    final id = core[1];
    final e = lookup(id);
    if (!e.exists) {
      r.rcode = _rcNxDomain;
      return r.finish(zone);
    }
    final host = e.host;
    final ip = host == null ? null : _pick(host, canonicalIp(from));
    final target = ['zerotier', id, ...zl];
    if (ip != null) {
      if (q.qtype == _typeA && !srv) {
        r.answers.add(_rr(const [], _typeA, ip.rawAddress, pointer: true));
      } else if (q.qtype == _typeSRV && srv) {
        final rd = BytesBuilder()
          ..add(_u16(0)) // priorità
          ..add(_u16(0)) // peso
          ..add(_u16(host!.port))
          ..add(_name(target));
        r.answers.add(_rr(const [], _typeSRV, rd.takeBytes(), pointer: true));
        r.additional.add(_rr(target, _typeA, ip.rawAddress));
      }
    }
    // AAAA e altri tipi: NOERROR vuoto (il client non aspetta l'IPv6)
    return r.finish(zone);
  }

  /// Orizzonte diviso (B-DNS-02): a chi ospita il suo indirizzo LAN, a tutti
  /// gli altri quello visto dall'hub. Solo IPv4 (record A).
  static InternetAddress? _pick(DnsHost h, String from) {
    final ip = InternetAddress.tryParse(h.ip);
    final lan = h.lan == null ? null : InternetAddress.tryParse(h.lan!);
    InternetAddress? v4(InternetAddress? a) =>
        a != null && a.type == InternetAddressType.IPv4 ? a : null;
    if (from == h.ip && v4(lan) != null) return lan;
    return v4(ip);
  }

  static bool _endsWith(List<String> a, List<String> suffix) {
    for (var i = 0; i < suffix.length; i++) {
      if (a[a.length - suffix.length + i] != suffix[i]) return false;
    }
    return true;
  }
}

typedef _Question = ({List<String> labels, int qtype, int qclass, Uint8List raw});

/// La question all'offset 12. Le query dei client non usano compressione.
_Question? _question(Uint8List m) {
  var off = 12;
  final labels = <String>[];
  var total = 0;
  while (true) {
    if (off >= m.length) return null;
    final l = m[off];
    if (l == 0) {
      off++;
      break;
    }
    if (l & 0xc0 != 0) return null;
    off++;
    if (off + l > m.length) return null;
    total += l + 1;
    if (total > 255) return null;
    labels.add(String.fromCharCodes(m, off, off + l));
    off += l;
  }
  if (off + 4 > m.length) return null;
  return (
    labels: labels,
    qtype: m[off] << 8 | m[off + 1],
    qclass: m[off + 2] << 8 | m[off + 3],
    raw: Uint8List.sublistView(m, 12, off + 4),
  );
}

final class _Reply {
  _Reply(this.id0, this.id1, {required this.rd, required this.question});
  final int id0, id1;
  final bool rd;
  final Uint8List question;
  int rcode = _rcOk;
  final answers = <Uint8List>[];
  final authority = <Uint8List>[];
  final additional = <Uint8List>[];

  /// SOA in AUTHORITY sulle risposte negative (NXDOMAIN e NODATA) per il
  /// caching negativo (RFC 2308); mai sulle REFUSED né sulle positive.
  Uint8List finish(String zone) {
    if (answers.isEmpty && rcode != _rcRefused) authority.add(_soa(zone));
    return bytes();
  }

  Uint8List bytes() {
    // QR=1, opcode 0, AA=1 (solo nella nostra zona), RD copiato, RCODE
    var flags = 0x8000 | rcode;
    if (rcode != _rcRefused) flags |= 0x0400;
    if (rd) flags |= 0x0100;
    final b = BytesBuilder()
      ..add([id0, id1])
      ..add(_u16(flags))
      ..add(_u16(1))
      ..add(_u16(answers.length))
      ..add(_u16(authority.length))
      ..add(_u16(additional.length))
      ..add(question);
    for (final rr in [...answers, ...authority, ...additional]) {
      b.add(rr);
    }
    return b.takeBytes();
  }
}

/// Un record: con [pointer] il nome è il puntatore alla question (0xC00C).
Uint8List _rr(List<String> owner, int type, List<int> rdata, {bool pointer = false}) {
  final b = BytesBuilder()
    ..add(pointer ? const [0xc0, 0x0c] : _name(owner))
    ..add(_u16(type))
    ..add(_u16(_classIN))
    ..add(_u32(dnsTtl))
    ..add(_u16(rdata.length))
    ..add(rdata);
  return b.takeBytes();
}

/// SOA dell'apice della zona: contano solo MINIMUM e il TTL del record.
Uint8List _soa(String zone) {
  final zl = zone.split('.');
  final rd = BytesBuilder()
    ..add(_name(['hub', ...zl]))
    ..add(_name(['hostmaster', ...zl]))
    ..add(_u32(1)) // serial
    ..add(_u32(3600)) // refresh
    ..add(_u32(600)) // retry
    ..add(_u32(604800)) // expire
    ..add(_u32(dnsTtl)); // minimum
  return _rr(zl, _typeSOA, rd.takeBytes());
}

Uint8List _name(List<String> labels) {
  final b = BytesBuilder();
  for (final l in labels) {
    b
      ..addByte(l.length)
      ..add(l.codeUnits);
  }
  b.addByte(0);
  return b.takeBytes();
}

List<int> _u16(int v) => [v >> 8 & 0xff, v & 0xff];
List<int> _u32(int v) => [v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff];
