// Testi dei messaggi del bot, in italiano e inglese (HTML di Telegram). Ogni
// riga comincia con la sua emoji, così il messaggio si legge a colpo d'occhio
// nella lista delle chat (B-TG-04).

/// Sostituisce i caratteri speciali dell'HTML di Telegram.
String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Durata per le persone (B-TG-08): `""` sotto il minuto, `5m`, `1h 30m`.
String dur(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return '';
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}

/// Indirizzo diretto da mostrare: la porta solo se non è quella predefinita.
String hostAddress(String ip, int? port) {
  if (port == null || port == 25565) return ip;
  return ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
}

/// Una sessione aperta, per /status.
typedef OpenLine = ({
  String name,
  String host,
  Duration since,
  List<String> players,
  String? dnsName,
  String? address,
});

/// Testi in una lingua.
final class BotTexts {
  const BotTexts._(this.it);

  /// `it` o `en`; qualsiasi altro valore vale `en`.
  factory BotTexts.of(String lang) =>
      lang == 'it' ? const BotTexts._(true) : const BotTexts._(false);

  final bool it;

  String open({required String name, required String host, String? dnsName, String? address}) => [
    it ? '🟢 <b>${esc(name)}</b> è aperto' : '🟢 <b>${esc(name)}</b> is open',
    it ? '👤 hosta <b>${esc(host)}</b>' : '👤 hosted by <b>${esc(host)}</b>',
    if (dnsName != null) '🌐 <code>${esc(dnsName)}</code>',
    if (address != null) '📡 <code>${esc(address)}</code>',
  ].join('\n');

  String close({required String name, required Duration session, String? notResponding}) {
    final d = dur(session);
    return [
      it ? '🔴 <b>${esc(name)}</b> è chiuso' : '🔴 <b>${esc(name)}</b> is closed',
      if (notResponding != null)
        it
            ? '⚠️ il client di ${esc(notResponding)} non risponde più'
            : '⚠️ the client of ${esc(notResponding)} is not responding',
      if (d.isNotEmpty) it ? '⏱ sessione di $d' : '⏱ session of $d',
    ].join('\n');
  }

  String notSaving({required String name, required String host, required Duration since}) => it
      ? '⚠️ <b>${esc(name)}</b> è aperto ma non salva sull\'hub da ${dur(since)}\n'
            '👤 host <b>${esc(host)}</b>: i salvataggi automatici non arrivano, lo stato '
            'recente non è protetto'
      : '⚠️ <b>${esc(name)}</b> is open but has not saved to the hub for ${dur(since)}\n'
            '👤 host <b>${esc(host)}</b>: autosaves are not arriving, recent progress is not '
            'protected';

  String disk({required int free, required int minFree, required bool full}) {
    final f = _bytes(free), m = _bytes(minFree);
    if (full) {
      return it
          ? '💾 <b>Disco dell\'hub pieno</b>: liberi $f, soglia $m\n⛔ i salvataggi vengono rifiutati'
          : '💾 <b>Hub disk full</b>: $f free, threshold $m\n⛔ saves are being refused';
    }
    return it
        ? '💾 <b>Disco dell\'hub quasi pieno</b>: liberi $f, soglia $m'
        : '💾 <b>Hub disk almost full</b>: $f free, threshold $m';
  }

  String status(List<(String name, OpenLine? open)> spaces) {
    final lines = [it ? '📊 <b>Stato dei server</b>' : '📊 <b>Server status</b>'];
    for (final (name, o) in spaces) {
      if (o == null) {
        lines.add(it ? '⚪ <b>${esc(name)}</b> — chiuso' : '⚪ <b>${esc(name)}</b> — closed');
        continue;
      }
      final sb = StringBuffer(
        it
            ? '🟢 <b>${esc(name)}</b> — hosta ${esc(o.host)}'
            : '🟢 <b>${esc(name)}</b> — hosted by ${esc(o.host)}',
      );
      final d = dur(o.since);
      if (d.isNotEmpty) sb.write(it ? ' da $d' : ' for $d');
      final n = o.players.length;
      if (n == 0) {
        sb.write(it ? ', nessuno in gioco' : ', nobody playing');
      } else if (n <= 6) {
        final p = esc(o.players.join(', '));
        sb.write(it ? ', in gioco: $p' : ', playing: $p');
      } else {
        sb.write(it ? ', $n in gioco' : ', $n playing');
      }
      lines.add(sb.toString());
      if (o.dnsName != null) {
        lines.add('   🌐 <code>${esc(o.dnsName!)}</code>');
      } else if (o.address != null) {
        lines.add('   📡 <code>${esc(o.address!)}</code>');
      }
    }
    if (spaces.isEmpty) lines.add(it ? 'Nessun server configurato.' : 'No servers yet.');
    return lines.join('\n');
  }

  String test({String? space}) => space == null
      ? (it
            ? '✅ <b>MineSync</b>: messaggio di prova. Il bot è configurato correttamente.'
            : '✅ <b>MineSync</b>: test message. The bot is set up correctly.')
      : (it
            ? '✅ <b>MineSync</b>: messaggio di prova per <b>${esc(space)}</b>. Gli annunci di '
                  'questo server arriveranno qui.'
            : '✅ <b>MineSync</b>: test message for <b>${esc(space)}</b>. This server\'s '
                  'announcements will arrive here.');

  /// Errore registrato quando il topic di uno spazio non c'è più (B-TG-21).
  String topicMissing(String space) => it
      ? 'topic di $space non trovato su Telegram (eliminato?): i messaggi vanno nella chat '
            'principale'
      : 'topic of $space not found on Telegram (deleted?): messages go to the main chat';

  String _bytes(int b) {
    const gib = 1 << 30, mib = 1 << 20;
    final s = b >= gib ? '${(b / gib).toStringAsFixed(1)} GB' : '${(b / mib).round()} MB';
    return it ? s.replaceAll('.', ',') : s;
  }
}

/// Prima riga di un messaggio senza HTML (per `lastSent`).
String firstLine(String html) {
  final l = html.split('\n').first.replaceAll(RegExp('<[^>]*>'), '');
  return l.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
}
