// DNS autoritativo minimale (A e SRV) su RawDatagramSocket, stesso
// comportamento di server/internal/mcdns della 3.x:
//   zerotier.<spazio>.<zona>                 A    -> IP dell'host
//   _minecraft._tcp.zerotier.<spazio>.<zona> SRV  -> 0 0 <porta> zerotier.<spazio>.<zona>
//                                                    + glue A in ADDITIONAL
// TTL 5 s; fuori zona REFUSED; nome sconosciuto NXDOMAIN + SOA (RFC 2308);
// altri tipi (AAAA...) NOERROR vuoto + SOA. Le risposte (QR=1) e gli opcode
// diversi da QUERY si scartano in silenzio (niente amplificazione).
// Nello spike i record vengono dalla configurazione (nel prodotto: dal lock).
import 'dart:io';
import 'dart:typed_data';

const ttlSec = 5;
const _typeA = 1, _typeSOA = 6, _typeSRV = 33, _classIN = 1;
const _rcOk = 0, _rcNx = 3, _rcRefused = 5;

class DnsHost {
  DnsHost(this.ip, this.port);
  final InternetAddress ip;
  final int port;
}

class DnsServer {
  DnsServer(String zone, this.hosts)
      : zone = zone.toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '');
  final String zone;

  /// spazio -> host attuale (null = spazio esistente ma nessuno hosta)
  final Map<String, DnsHost?> hosts;
  RawDatagramSocket? _sock;
  int served = 0;

  Future<int> start(InternetAddress addr, int port) async {
    final s = await RawDatagramSocket.bind(addr, port);
    _sock = s;
    s.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = s.receive()) != null) {
        final resp = handle(d!.data);
        if (resp != null) {
          s.send(resp, d.address, d.port);
          served++;
        }
      }
    });
    return s.port;
  }

  void close() => _sock?.close();

  Uint8List? handle(Uint8List req) {
    if (req.length < 12) return null;
    if (req[2] & 0x80 != 0 || (req[2] >> 3) & 0x0F != 0) return null;
    // question: etichette non compresse
    final labels = <String>[];
    var off = 12;
    while (true) {
      if (off >= req.length) return null;
      final l = req[off];
      if (l == 0) {
        off++;
        break;
      }
      if (l & 0xC0 != 0 || off + 1 + l > req.length) return null;
      labels.add(String.fromCharCodes(req, off + 1, off + 1 + l).toLowerCase());
      off += 1 + l;
    }
    if (off + 4 > req.length) return null;
    final qtype = req[off] << 8 | req[off + 1];
    final qclass = req[off + 2] << 8 | req[off + 3];
    if (qclass != _classIN) return null;
    final m = _Reply(req[0], req[1], req[2] & 0x01 != 0,
        Uint8List.sublistView(req, 12, off + 4));

    if (labels.isEmpty || labels.last != zone) {
      m.rcode = _rcRefused;
      return m.finish(zone);
    }
    var core = labels.sublist(0, labels.length - 1);
    if (core.length >= 2 && core[0] == '_minecraft' && core[1] == '_tcp') {
      core = core.sublist(2);
    }
    if (core.length != 2 || core[0] != 'zerotier' || !hosts.containsKey(core[1])) {
      m.rcode = _rcNx;
      return m.finish(zone);
    }
    final h = hosts[core[1]];
    if (h != null) {
      final target = ['zerotier', core[1], zone];
      if (qtype == _typeA) {
        m.answers.add(_rr(const [0xC0, 0x0C], _typeA, h.ip.rawAddress));
      } else if (qtype == _typeSRV) {
        final rd = BytesBuilder()
          ..add(_u16(0))
          ..add(_u16(0))
          ..add(_u16(h.port))
          ..add(_name(target));
        m.answers.add(_rr(const [0xC0, 0x0C], _typeSRV, rd.takeBytes()));
        m.additional.add(_rr(_name(target), _typeA, h.ip.rawAddress));
      }
    }
    return m.finish(zone);
  }
}

class _Reply {
  _Reply(this.id0, this.id1, this.rd, this.question);
  final int id0, id1;
  final bool rd;
  final Uint8List question;
  int rcode = _rcOk;
  final answers = <List<int>>[], authority = <List<int>>[], additional = <List<int>>[];

  Uint8List finish(String zone) {
    if (answers.isEmpty && rcode != _rcRefused) authority.add(_soa(zone));
    var flags = 0x8000 | 0x0400 | rcode; // QR, AA
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

List<int> _u16(int v) => [v >> 8 & 0xFF, v & 0xFF];
List<int> _u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];

List<int> _name(List<String> labels) => [
      for (final l in labels) ...[l.length, ...l.codeUnits],
      0,
    ];

List<int> _rr(List<int> owner, int type, List<int> rdata) => [
      ...owner,
      ..._u16(type),
      ..._u16(_classIN),
      ..._u32(ttlSec),
      ..._u16(rdata.length),
      ...rdata,
    ];

List<int> _soa(String zone) => _rr(_name([zone]), _typeSOA, [
      ..._name(['hub', zone]),
      ..._name(['hostmaster', zone]),
      ..._u32(1),
      ..._u32(3600),
      ..._u32(600),
      ..._u32(604800),
      ..._u32(ttlSec),
    ]);
