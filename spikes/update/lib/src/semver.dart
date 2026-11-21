// Semver minimale: MAJOR.MINOR.PATCH[-pre]; i metadati di build (+...) sono
// rifiutati per semplicità. Serve solo a decidere "più nuova o no".
class SemVer implements Comparable<SemVer> {
  final int major, minor, patch;
  final List<String> pre; // vuota = release

  SemVer(this.major, this.minor, this.patch, [this.pre = const []]);

  static final _re = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$');

  /// null se [s] non è semver valido (es. build "dev": non si aggiorna mai).
  static SemVer? tryParse(String s) {
    final m = _re.firstMatch(s);
    if (m == null) return null;
    return SemVer(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
        m[4]?.split('.') ?? const []);
  }

  @override
  int compareTo(SemVer o) {
    for (final d in [major - o.major, minor - o.minor, patch - o.patch]) {
      if (d != 0) return d.sign;
    }
    // Una release è più nuova di qualsiasi sua pre-release.
    if (pre.isEmpty && o.pre.isEmpty) return 0;
    if (pre.isEmpty) return 1;
    if (o.pre.isEmpty) return -1;
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final a = int.tryParse(pre[i]), b = int.tryParse(o.pre[i]);
      final c = (a != null && b != null)
          ? a.compareTo(b)
          : (a != null ? -1 : (b != null ? 1 : pre[i].compareTo(o.pre[i])));
      if (c != 0) return c.sign;
    }
    return (pre.length - o.pre.length).sign;
  }

  bool operator >(SemVer o) => compareTo(o) > 0;

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

/// true solo se entrambe sono semver e [candidate] è strettamente più nuova.
bool isNewer(String candidate, String current) {
  final a = SemVer.tryParse(candidate), b = SemVer.tryParse(current);
  return a != null && b != null && a > b;
}
