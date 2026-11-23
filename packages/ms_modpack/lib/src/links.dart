// Collegamenti esterni che l'app mostra invece di fare da sola: Java da
// installare (mai scaricato in automatico) e le mod di CurseForge da
// scaricare a mano. CurseForge: solo il modello (nessun client dell'API, che
// vuole una chiave per app); una mod con la distribuzione vietata
// dall'autore si scarica dalla sua pagina e si indica il file.
import 'pack.dart';

/// Pagina di download di Eclipse Temurin per il major [major] di Java.
String temurinUrl(int major) =>
    major > 0 ? 'https://adoptium.net/temurin/releases/?version=$major' : 'https://adoptium.net/';

/// Pagina di un progetto CurseForge di Minecraft dallo slug.
String curseForgeProjectUrl(String slug) =>
    'https://www.curseforge.com/minecraft/mc-mods/${Uri.encodeComponent(slug)}';

/// La voce di una mod di CurseForge il cui file l'admin ha scaricato a mano
/// dalla pagina [pageUrl]: hash dal file, lato scelto dall'admin (default
/// solo server), nessun URL (non va mai nel pacchetto: ogni giocatore la
/// scarica dalla stessa pagina).
PackMod curseForgeEntry(
  LocalFile f, {
  required String pageUrl,
  int? projectId,
  int? fileId,
  PackSide side = PackSide.server,
  bool optional = false,
  String? name,
  bool allowDistribution = false,
}) {
  final m = manualEntry(f, side: side, name: name);
  return m.copyWith(
    source: PackSource.curseforge,
    optional: optional,
    curseforge: CurseForgeRef(
      projectId: projectId,
      fileId: fileId,
      pageUrl: pageUrl,
      allowDistribution: allowDistribution,
    ),
  );
}
