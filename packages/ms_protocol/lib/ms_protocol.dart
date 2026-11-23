/// Contratto tra client e hub di MineSync: modelli dell'API v1, codici di
/// errore, manifest con digest canonico e validazione dei percorsi.
/// Puro Dart, usabile anche sul web.
library;

export 'src/admin.dart';
export 'src/dl.dart';
export 'src/errors.dart';
export 'src/event_types.dart';
export 'src/exclusions.dart';
export 'src/history.dart';
export 'src/manifest.dart';
export 'src/pack.dart';
export 'src/models.dart' hide integer, obj, str, strings;
export 'src/paths.dart';
export 'src/telegram.dart';
export 'src/world.dart';
