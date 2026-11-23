// Riconosce il sistema del visitatore dallo user agent, per proporre il
// download giusto. Telefoni e tablet non hanno un'app: null.
import 'package:ms_protocol/ms_protocol.dart';

/// Sistema e architettura del visitatore.
final class ClientOs {
  const ClientOs(this.os, {this.arch});

  final DlOs os;

  /// `x64` o `arm64` quando lo user agent lo dice (spesso non lo dice).
  final String? arch;

  /// Da [userAgent]; null per telefoni, tablet e sistemi sconosciuti.
  static ClientOs? detect(String userAgent) {
    final ua = userAgent.toLowerCase();
    if (ua.contains('android') ||
        ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('ipod') ||
        ua.contains('mobile')) {
      return null;
    }
    String? arch;
    if (ua.contains('arm64') || ua.contains('aarch64')) {
      arch = 'arm64';
    } else if (ua.contains('x86_64') ||
        ua.contains('x64') ||
        ua.contains('win64') ||
        ua.contains('amd64')) {
      arch = 'x64';
    }
    if (ua.contains('windows')) return ClientOs(DlOs.windows, arch: arch);
    if (ua.contains('mac os') || ua.contains('macintosh')) return ClientOs(DlOs.macos, arch: arch);
    if (ua.contains('cros')) return null;
    if (ua.contains('linux') || ua.contains('x11')) return ClientOs(DlOs.linux, arch: arch);
    return null;
  }

  /// Il file migliore per questo sistema tra [files], o null.
  DlFile? pick(List<DlFile> files) {
    final mine = files.where((f) => f.os == os).toList();
    if (mine.isEmpty) return null;
    int score(DlFile f) {
      if (arch != null && f.arch == arch) return 3;
      if (f.arch == 'universal') return 2;
      // senza indicazioni si propone x64 (Windows, Linux) o arm64 (Mac)
      if (arch == null && f.arch == (os == DlOs.macos ? 'arm64' : 'x64')) return 2;
      if (f.arch == null) return 1;
      return 0;
    }

    mine.sort((a, b) => score(b).compareTo(score(a)));
    return mine.first;
  }
}
