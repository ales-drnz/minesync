/// Aggiornamento firmato dell'app desktop: formato dell'installazione,
/// manifest, verifica della firma e preparazione delle versioni nuove.
/// Lo usano l'app (che scarica) e il launcher (che avvia e fa rollback).
library;

export 'src/install.dart';
export 'src/manifest.dart';
export 'src/pack.dart';
export 'src/semver.dart';
export 'src/stager.dart';
