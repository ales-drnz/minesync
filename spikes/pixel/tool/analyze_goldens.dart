// Analisi dei PNG golden: purezza della palette (tolleranza zero) e spessore
// dei bordi per la geometria, quantità di antialiasing per il testo.
// Scrive anche ingrandimenti nearest-neighbour in goldens/zoom/.
//   dart run tool/analyze_goldens.dart [cartella_goldens] [--json out.json]
// Exit code 0 solo se la geometria è pura a tutti i dpr e Silkscreen
// (allineato) non ha antialiasing.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:pixel_spike/analysis.dart';
import 'package:pixel_spike/ms/palette_hex.dart';
import 'package:pixel_spike/specimen_list.dart';

const dprs = [1.0, 1.25, 1.5, 2.0];
int unitPx(double dpr) => (dpr * 2 + 1e-6).floor().clamp(1, 1 << 20);

Px load(String path) {
  final img = im.decodePng(File(path).readAsBytesSync())!;
  final rgba = img.convert(numChannels: 4).getBytes(order: im.ChannelOrder.rgba);
  return Px(img.width, img.height, Uint8List.fromList(rgba));
}

void zoom(String src, String dst, int x, int y, int w, int h, int k) {
  final img = im.decodePng(File(src).readAsBytesSync())!;
  final c = im.copyCrop(img, x: x, y: y, width: w, height: h);
  final z = im.copyResize(c, width: w * k, height: h * k, interpolation: im.Interpolation.nearest);
  File(dst)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(im.encodePng(z));
}

void main(List<String> args) {
  final root = args.isNotEmpty && !args.first.startsWith('--') ? args.first : 'goldens';
  final jsonIdx = args.indexOf('--json');
  final report = <String, Object>{};
  var pass = true;
  final palette = geometryPalette();

  stdout.writeln('== Geometria (tolleranza zero) ==');
  for (final d in dprs) {
    final dir = '$root/dpr_${d.toStringAsFixed(2)}';
    final u = unitPx(d);
    for (final name in ['geom_buttons', 'geom_panel']) {
      final f = '$dir/$name.png';
      if (!File(f).existsSync()) {
        stdout.writeln('MANCA $f');
        pass = false;
        continue;
      }
      final px = load(f);
      final p = checkPurity(px, palette);
      final r = checkRuns(px, MsHex.pxOutline, u);
      final ok = p.ok && r.bad == 0;
      pass &= ok;
      stdout.writeln('${ok ? 'OK  ' : 'FAIL'} dpr $d $name ${px.width}x${px.height} '
          'fuori-palette=${p.bad} bordi(${r.runs} tratti, lunghezze ${r.lengths.keys.toList()..sort()}) '
          'non-multipli-di-$u=${r.bad}');
      report['$d/$name'] = {'bad': p.bad, 'runs': r.runs, 'badRuns': r.bad, 'unitPx': u};
    }
  }

  stdout.writeln('\n== Testo: antialiasing per campione (pixel intermedi / pixel d\'inchiostro) ==');
  for (final d in dprs) {
    final dir = '$root/dpr_${d.toStringAsFixed(2)}';
    for (final e in textSamples.entries) {
      final f = '$dir/${e.key}.png';
      if (!File(f).existsSync()) continue;
      final bands = textBands(load(f), MsHex.bg, MsHex.text);
      if (bands.length != e.value.length) {
        stdout.writeln('ATTENZIONE dpr $d ${e.key}: ${bands.length} bande per ${e.value.length} campioni');
      }
      for (var i = 0; i < bands.length && i < e.value.length; i++) {
        final s = e.value[i];
        final b = bands[i];
        stdout.writeln('dpr ${d.toString().padRight(4)} ${s.id.padRight(14)} '
            'AA ${(b.aaRatio * 100).toStringAsFixed(1).padLeft(5)}%  '
            'copertura 25-75% ${(b.midRatio * 100).toStringAsFixed(1).padLeft(5)}%  (inchiostro ${b.ink} px)');
        report['$d/${s.id}'] = {'aa': b.aaRatio, 'mid': b.midRatio, 'ink': b.ink};
        // criterio: Silkscreen allineato alla griglia senza antialiasing
        if (s.font == 'silkscreen' && s.snap && b.partial > 0) pass = false;
      }
    }
  }

  // Ingrandimenti per il proprietario (x8 a dpr 1, x4 a dpr 2).
  for (final d in dprs) {
    final dir = '$root/dpr_${d.toStringAsFixed(2)}';
    final k = d >= 2 ? 4 : (d >= 1.5 ? 5 : 8);
    int s(num u) => (u * d).round();
    if (File('$dir/components.png').existsSync()) {
      zoom('$dir/components.png', '$root/zoom/dpr_${d.toStringAsFixed(2)}_gioca_angolo.png', 0, 0, s(150), s(110), k);
    }
    if (File('$dir/text_silkscreen.png').existsSync()) {
      zoom('$dir/text_silkscreen.png', '$root/zoom/dpr_${d.toStringAsFixed(2)}_silkscreen.png', 0, 0, s(200), s(140), k ~/ 2 + 1);
    }
    if (File('$dir/text_pixelify.png').existsSync()) {
      zoom('$dir/text_pixelify.png', '$root/zoom/dpr_${d.toStringAsFixed(2)}_pixelify.png', 0, 0, s(200), s(120), k ~/ 2 + 1);
    }
  }

  if (jsonIdx >= 0 && jsonIdx + 1 < args.length) {
    File(args[jsonIdx + 1]).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
  }
  stdout.writeln('\nRISULTATO: ${pass ? 'PASS' : 'FAIL'}');
  exitCode = pass ? 0 : 1;
}
