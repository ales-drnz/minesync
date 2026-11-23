// Esporta l'icona dell'app (il logo "Blocco Sync", palette prato) in tutti i
// formati delle app: ico di Windows, AppIcon.appiconset e icns di macOS, PNG
// per Linux, favicon e icone del manifest web.
//
//   dart run tool/export_icon.dart          scrive i file
//   dart run tool/export_icon.dart --check  esce con 1 se un file non è aggiornato
//
// Solo ingrandimenti interi senza filtri, nessun ricampionamento. PNG, ICO e
// ICNS sono scritti a mano e compressi con il deflate in Dart puro di
// package:archive (non lo zlib della piattaforma), così i byte sono gli
// stessi a ogni esecuzione e su ogni macchina.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoderWeb;
import 'package:ms_ui/src/icons/icon_data.dart';
import 'package:ms_ui/src/icons/icons.g.dart';

/// Un'immagine quadrata RGBA da disegnare.
typedef IconSpec = ({int size, int? content, bool maskable});

IconSpec _full(int size) => (size: size, content: null, maskable: false);

/// Il 1024 di macOS e le icone del manifest hanno un margine trasparente
/// (Identity.dc.html: "24 e 1024 vanno composti con margine trasparente",
/// "PNG 180 e 192 con margine"); 24, 20 e 40 lo hanno già perché non sono
/// multipli delle griglie.
IconSpec _margin(int size, int content) => (size: size, content: content, maskable: false);

/// Icona "maskable" del manifest: fondo pieno fino ai bordi e logo dentro la
/// zona sicura (cerchio di raggio 40 %: il quadrato inscritto è 0,8/√2).
IconSpec _maskable(int size) =>
    (size: size, content: (size * 0.8 / math.sqrt2).floor(), maskable: true);

const ico = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const linux = [16, 24, 32, 48, 64, 128, 256, 512];
const mac = [16, 32, 64, 128, 256, 512, 1024];
const favicon = [16, 32, 48];

/// Voci dell'icns: tipo -> dimensione (solo voci PNG).
const icns = {
  'ic11': 32,
  'ic12': 64,
  'ic07': 128,
  'ic13': 256,
  'ic08': 256,
  'ic14': 512,
  'ic09': 512,
  'ic10': 1024,
};

IconSpec _macSpec(int size) => size == 1024 ? _margin(1024, 960) : _full(size);

/// Pixel RGBA del logo per [spec]; [background] (ARGB) per le maskable.
Uint8List renderRgba(IconSpec spec, {required int background}) {
  final s = spec.size;
  final px = Uint8List(s * s * 4);
  if (spec.maskable) {
    for (var i = 0; i < s * s; i++) {
      _put(px, i, background);
    }
  }
  final l = logoLayout(msLogoArt, s, content: spec.content);
  final colors = msLogoPrato.roles;
  final r = l.art.runs;
  for (var i = 0; i < r.length; i += 4) {
    final c = colors[r[i + 3]];
    for (var y = 0; y < l.scale; y++) {
      final row = l.offset + r[i + 1] * l.scale + y;
      final x0 = l.offset + r[i] * l.scale;
      for (var x = 0; x < r[i + 2] * l.scale; x++) {
        _put(px, row * s + x0 + x, c);
      }
    }
  }
  return px;
}

void _put(Uint8List px, int i, int argb) {
  px[i * 4] = (argb >> 16) & 0xff;
  px[i * 4 + 1] = (argb >> 8) & 0xff;
  px[i * 4 + 2] = argb & 0xff;
  px[i * 4 + 3] = (argb >> 24) & 0xff;
}

// --- PNG -------------------------------------------------------------------

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

void _u32(BytesBuilder b, int v) =>
    b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

void _chunk(BytesBuilder out, String type, List<int> data) {
  final body = [...ascii.encode(type), ...data];
  _u32(out, data.length);
  out.add(body);
  _u32(out, _crc32(body));
}

/// PNG RGBA a 8 bit, filtro "Sub" su ogni riga (le corse piene diventano zeri).
Uint8List encodePng(Uint8List rgba, int size) {
  final raw = BytesBuilder(copy: false);
  final stride = size * 4;
  for (var y = 0; y < size; y++) {
    final row = Uint8List(stride + 1)..[0] = 1;
    for (var x = 0; x < stride; x++) {
      final left = x >= 4 ? rgba[y * stride + x - 4] : 0;
      row[x + 1] = (rgba[y * stride + x] - left) & 0xff;
    }
    raw.add(row);
  }
  final ihdr = BytesBuilder();
  _u32(ihdr, size);
  _u32(ihdr, size);
  ihdr.add([8, 6, 0, 0, 0]); // 8 bit, RGBA, deflate, filtri adattivi, no interlace
  final out = BytesBuilder(copy: false)..add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  _chunk(out, 'IHDR', ihdr.toBytes());
  _chunk(out, 'IDAT', const ZLibEncoderWeb().encodeBytes(raw.toBytes(), level: 9));
  _chunk(out, 'IEND', const []);
  return out.toBytes();
}

// --- ICO e ICNS ------------------------------------------------------------

void _le16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
void _le32(BytesBuilder b, int v) =>
    b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

/// ICO con voci PNG (Windows Vista e successivi).
Uint8List encodeIco(List<(int, Uint8List)> pngs) {
  final b = BytesBuilder(copy: false);
  _le16(b, 0);
  _le16(b, 1); // icona
  _le16(b, pngs.length);
  var offset = 6 + 16 * pngs.length;
  for (final (size, png) in pngs) {
    b.add([size >= 256 ? 0 : size, size >= 256 ? 0 : size, 0, 0]);
    _le16(b, 1); // piani
    _le16(b, 32); // bit per pixel
    _le32(b, png.length);
    _le32(b, offset);
    offset += png.length;
  }
  for (final (_, png) in pngs) {
    b.add(png);
  }
  return b.toBytes();
}

/// ICNS con sole voci PNG.
Uint8List encodeIcns(List<(String, Uint8List)> entries) {
  final body = BytesBuilder(copy: false);
  for (final (type, png) in entries) {
    body.add(ascii.encode(type));
    _u32(body, png.length + 8);
    body.add(png);
  }
  final b = BytesBuilder(copy: false)..add(ascii.encode('icns'));
  _u32(b, body.length + 8);
  b.add(body.toBytes());
  return b.toBytes();
}

// --- Manifest e Contents.json ------------------------------------------------

const _macContents = [
  (16, 1, 16),
  (16, 2, 32),
  (32, 1, 32),
  (32, 2, 64),
  (128, 1, 128),
  (128, 2, 256),
  (256, 1, 256),
  (256, 2, 512),
  (512, 1, 512),
  (512, 2, 1024),
];

/// Contents.json nel formato di Xcode.
String macContentsJson() {
  final images = [
    for (final (size, scale, file) in _macContents)
      '    {\n'
          '      "size" : "${size}x$size",\n'
          '      "idiom" : "mac",\n'
          '      "filename" : "app_icon_$file.png",\n'
          '      "scale" : "${scale}x"\n'
          '    }',
  ];
  return '{\n  "images" : [\n${images.join(',\n')}\n  ],\n'
      '  "info" : {\n    "version" : 1,\n    "author" : "xcode"\n  }\n}\n';
}

/// Il manifest web con nome e colori di MineSync (il resto resta com'è).
String manifestJson(String current, String color) {
  final m = jsonDecode(current) as Map<String, Object?>;
  m
    ..['name'] = 'MineSync'
    ..['short_name'] = 'MineSync'
    ..['background_color'] = color
    ..['theme_color'] = color;
  return '${const JsonEncoder.withIndent('    ').convert(m)}\n';
}

// --- Tutti i file ------------------------------------------------------------

/// Contenuto atteso di ogni file, per percorso relativo alla radice del
/// repository. [msUi] è la cartella di packages/ms_ui.
Map<String, List<int>> renderAll(String msUi) {
  final tokens =
      jsonDecode(File('$msUi/tokens/tokens.json').readAsStringSync()) as Map<String, Object?>;
  final bgHex =
      ((tokens['colors']! as Map<String, Object?>)['prato-dark']! as Map<String, Object?>)['bg']!
          as String;
  final bg = 0xff000000 | int.parse(bgHex.substring(1), radix: 16);

  final cache = <IconSpec, Uint8List>{};
  Uint8List png(IconSpec s) =>
      cache.putIfAbsent(s, () => encodePng(renderRgba(s, background: bg), s.size));

  const web = 'apps/hub_web/web';
  const appiconset = 'apps/desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset';
  final manifest = File('$msUi/../../$web/manifest.json').readAsStringSync();
  return {
    'apps/desktop/windows/runner/resources/app_icon.ico': encodeIco([
      for (final s in ico) (s, png(_full(s))),
    ]),
    for (final s in mac) '$appiconset/app_icon_$s.png': png(_macSpec(s)),
    '$appiconset/Contents.json': utf8.encode(macContentsJson()),
    'packages/ms_ui/assets/brand/MineSync.icns': encodeIcns([
      for (final MapEntry(:key, :value) in icns.entries) (key, png(_macSpec(value))),
    ]),
    for (final s in linux) 'packages/ms_ui/assets/brand/minesync-$s.png': png(_full(s)),
    '$web/favicon.png': png(_full(32)),
    '$web/favicon.ico': encodeIco([for (final s in favicon) (s, png(_full(s)))]),
    '$web/icons/Icon-192.png': png(_margin(192, 168)),
    '$web/icons/Icon-512.png': png(_margin(512, 448)),
    '$web/icons/Icon-maskable-192.png': png(_maskable(192)),
    '$web/icons/Icon-maskable-512.png': png(_maskable(512)),
    '$web/manifest.json': utf8.encode(manifestJson(manifest, bgHex)),
  };
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main(List<String> args) {
  final msUi = File(Platform.script.toFilePath()).parent.parent.path;
  final root = Directory('$msUi/../..').absolute.path;
  final check = args.contains('--check');
  var stale = 0;
  for (final MapEntry(key: path, value: bytes) in renderAll(msUi).entries) {
    final f = File('$root/$path');
    if (check) {
      if (!f.existsSync() || !_same(f.readAsBytesSync(), bytes)) {
        stderr.writeln('non aggiornato: $path');
        stale++;
      }
    } else {
      f
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      stdout.writeln('${bytes.length.toString().padLeft(8)}  $path');
    }
  }
  if (stale > 0) {
    stderr.writeln('icone non aggiornate: dart run tool/export_icon.dart');
    exit(1);
  }
}
