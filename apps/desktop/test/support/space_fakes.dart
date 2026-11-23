// Sonde finte del PC e orologio fisso per i test delle schermate dei
// server: niente file system, niente Java vero, ore in UTC.
import 'package:flutter/foundation.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';

/// Istante "adesso" dei dati di esempio.
final sampleNow = DateTime.utc(2026, 11, 22, 18, 4);

const sampleJavas = [
  JavaRuntime(path: '/usr/lib/jvm/java-21/bin/java', major: 21, version: '21.0.5', bits: 64),
  JavaRuntime(path: '/usr/lib/jvm/java-17/bin/java', major: 17, version: '17.0.13', bits: 64),
];

/// Sonde che rispondono subito con dati fissi.
class FakeLocalProbe extends LocalProbe {
  const FakeLocalProbe({this.free = 212 << 30, this.javas = sampleJavas, this.scans = const {}});

  final int free;
  final List<JavaRuntime> javas;

  /// Cartella → contenuto; le altre risultano assenti.
  final Map<String, LocalScan> scans;

  @override
  Future<LocalScan> scan(String folder) =>
      SynchronousFuture(scans[folder] ?? LocalScan(disk: DiskSpace(free, 1000 << 30)));

  @override
  Future<DiskSpace?> disk(String path) => SynchronousFuture(DiskSpace(free, 1000 << 30));

  @override
  Future<List<JavaRuntime>> java({String? serverRoot}) => SynchronousFuture(javas);

  @override
  Future<void> openFolder(String folder) => SynchronousFuture(null);
}

/// Rende deterministici orologio e sonde di [s].
void useFakes(AppState s, {LocalProbe probe = const FakeLocalProbe()}) {
  s
    ..localProbe = probe
    ..now = (() => sampleNow)
    ..localTime = ((ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true));
}
