/// Modpack di MineSync: il file `minesync-pack.json`, il client dell'API v2
/// di Modrinth (con trasporto iniettato), il formato `.mrpack`, il
/// risolutore e i piani di installazione. Puro Dart, usabile anche sul web;
/// file, HTTP vero e installer dei server stanno in `io.dart`.
library;

export 'package:ms_protocol/ms_protocol.dart' show ClientPack, Loader, PackMissingMod;

export 'src/catalog_loader.dart';
export 'src/description_text.dart';
export 'src/http.dart';
export 'src/install_plan.dart';
export 'src/links.dart';
export 'src/modrinth.dart';
export 'src/modrinth_models.dart';
export 'src/mrpack.dart';
export 'src/pack.dart';
export 'src/resolver.dart';
export 'src/server_split.dart';
