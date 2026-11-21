// Driver: salva i risultati di perf_test in .tmp/perf.json
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        final f = File('.tmp/perf.json')..createSync(recursive: true);
        // senza gli array dei singoli fotogrammi
        final slim = <String, Object?>{};
        data?.forEach((k, v) {
          if (v is Map) {
            slim[k] = Map.fromEntries(v.entries.where((e) => e.value is! List).map((e) => MapEntry('${e.key}', e.value)));
          } else {
            slim[k] = v;
          }
        });
        f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(slim));
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(slim));
      },
    );
