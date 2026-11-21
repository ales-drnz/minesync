// Verifica i risultati di integration_test/perf_test.dart (.tmp/perf.json).
// PASS se, durante lo scroll continuo della console (2000 righe), i fotogrammi
// effettivi sono >= 95% di min(60, refresh) e nessun fotogramma supera il
// budget di 16,7 ms né in build né in raster (anche per fling e GIOCA).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final d = jsonDecode(File(args.isEmpty ? '.tmp/perf.json' : args.first).readAsStringSync()) as Map;
  final env = d['env'] as Map;
  final refresh = (env['refreshRate'] as num).toDouble();
  final target = 0.95 * (refresh > 0 && refresh < 60 ? refresh : 60);
  final fps = (d['console_scroll_fps'] as num).toDouble();
  var ok = fps >= target;
  stdout.writeln('ambiente: $env');
  stdout.writeln('scroll console: ${fps.toStringAsFixed(1)} fps effettivi (soglia ${target.toStringAsFixed(1)})');
  for (final k in ['console_scroll', 'console_fling', 'play_press']) {
    final v = d[k] as Map;
    final miss = (v['missed_frame_build_budget_count'] as int) + (v['missed_frame_rasterizer_budget_count'] as int);
    stdout.writeln('$k: ${v['frame_count']} fotogrammi, build media/p99/peggiore '
        '${v['average_frame_build_time_millis']}/${v['99th_percentile_frame_build_time_millis']}/${v['worst_frame_build_time_millis']} ms, '
        'raster ${v['average_frame_rasterizer_time_millis']}/${v['99th_percentile_frame_rasterizer_time_millis']}/${v['worst_frame_rasterizer_time_millis']} ms, '
        'oltre budget: $miss');
    ok &= miss == 0;
  }
  stdout.writeln('PERF: ${ok ? 'PASS' : 'FAIL'}');
  exitCode = ok ? 0 : 1;
}
