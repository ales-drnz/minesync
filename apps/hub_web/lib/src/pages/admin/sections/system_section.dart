// Sistema (sola lettura): versione, uptime, disco, indirizzo HTTP, DNS,
// host ammessi, cartella dati, admin iniziali, download e firma degli
// aggiornamenti, fuso orario, build della web UI. I valori che vengono
// dalle variabili d'ambiente dicono quale («impostato all'avvio»).
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../shell/feedback.dart';
import '../admin_data.dart';
import '../admin_widgets.dart';

/// Stato della firma degli aggiornamenti pubblicati.
enum SigningState { none, all, some, unsigned }

SigningState signingOf(List<UpdateChannel> u) {
  if (u.isEmpty) return SigningState.none;
  final n = u.where((c) => c.signed).length;
  return n == u.length
      ? SigningState.all
      : n == 0
      ? SigningState.unsigned
      : SigningState.some;
}

class SystemSection extends StatelessWidget {
  const SystemSection({super.key});

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s;
    final a = s.admin.access;
    final sys = d.system;
    final head = HeadNote(a.readOnly, icon: MsIcons.lock);
    if (sys == null) {
      return SectionPanel(
        title: s.admin.system,
        icon: MsIcons.terminal,
        hot: false,
        actions: [head],
        children: [LoadState(error: d.systemError, title: a.systemError, onRetry: d.reloadSystem)],
      );
    }
    Widget mono(String t) => MsText(t, kind: MsTextKind.mono);
    // [chip] per i valori con pillole o chip: con la variabile d'ambiente la
    // riga ha comunque il chip «impostato all'avvio»
    Widget row(
      String label,
      Widget value, {
      String? hint,
      String? env,
      bool chip = false,
      bool last = false,
    }) => SettingRow(
      label: label,
      hint: hint,
      dense: true,
      last: last,
      line: chip || env != null ? 36 : 24,
      child: EnvValue(value: value, variable: env),
    );
    final used = diskUsed(sys.disk);
    final dns = sys.dns;
    final signing = signingOf(sys.updates);
    return SectionPanel(
      title: s.admin.system,
      icon: MsIcons.terminal,
      hot: false,
      actions: [head],
      lead: a.systemLead,
      foot: [
        MsButton(
          label: a.copyDiag,
          icon: const MsIcon(MsIcons.copy),
          onPressed: () => copyText(context, diagnostics(sys)),
        ),
      ],
      children: [
        row(
          a.version,
          MsText(sys.build == null ? sys.version : a.versionBuild(sys.version, sys.build!)),
        ),
        row(a.uptime, MsText(a.uptimeValue(Duration(milliseconds: sys.time - sys.startedAt)))),
        row(
          a.disk,
          MsRow(
            gap: 8,
            children: [
              MsText(a.diskValue(s.fmt.size(sys.disk.free), s.fmt.size(sys.disk.total))),
              MsPill(s.fmt.percentSpaced(used), tone: diskTone(sys.disk)),
            ],
          ),
          chip: true,
        ),
        row(a.http, mono(sys.http), env: 'MINESYNC_ADDR'),
        row(
          a.dns,
          dns.zone == null
              ? MsText(a.dnsNone, tone: MsTextTone.secondary)
              : MsStack(
                  gap: 4,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsRow(
                      gap: 8,
                      children: [
                        mono(a.dnsValue(dns.zone!, dns.addr ?? ':53')),
                        MsPill(
                          dns.on ? a.dnsOn : a.dnsOff,
                          tone: dns.on ? MsStatusTone.ok : MsStatusTone.warn,
                        ),
                      ],
                    ),
                    if (dns.error != null) MsFieldError(a.dnsBindError(dns.error!)),
                  ],
                ),
          hint: a.dnsHint,
          env: 'MINESYNC_DNS_ZONE, _ADDR',
        ),
        row(
          a.hosts,
          sys.allowedHosts.isEmpty
              ? MsText(a.hostsNone, tone: MsTextTone.secondary)
              : MsRow(gap: 6, children: [for (final h in sys.allowedHosts) MsCode(h)]),
          hint: a.hostsHint,
          env: 'MINESYNC_HOSTS',
        ),
        row(a.dataDir, mono(sys.dataDir), env: 'MINESYNC_DATA'),
        row(
          a.admins,
          MsText(sys.admins.isEmpty ? a.adminsNone : sys.admins.join(', ')),
          env: 'MINESYNC_ADMINS',
        ),
        if (sys.minFreeEnv != null)
          row(a.minFreeEnv, MsText(s.fmt.size(sys.minFreeEnv!)), env: 'MINESYNC_MIN_FREE'),
        row(
          a.dl,
          sys.updates.isEmpty
              ? MsText(a.dlNone, tone: MsTextTone.secondary)
              : MsRow(
                  gap: 6,
                  children: [for (final u in sys.updates) MsChip('${u.platform} ${u.version}')],
                ),
          env: 'MINESYNC_DL',
        ),
        row(
          a.signing,
          switch (signing) {
            SigningState.none => MsPill(a.noUpdates),
            SigningState.all => MsPill(a.signed, tone: MsStatusTone.ok),
            SigningState.some => MsPill(a.partlySigned, tone: MsStatusTone.warn),
            SigningState.unsigned => MsPill(a.unsigned, tone: MsStatusTone.warn),
          },
          hint: a.signingHint,
          chip: true,
        ),
        row(a.tz, mono(sys.timeZone ?? '—'), env: 'TZ'),
        row(
          a.web,
          sys.webBuild == null
              ? const MsText('—', tone: MsTextTone.secondary)
              : mono(a.webValue(sys.webBuild!)),
          env: 'MINESYNC_WEB',
          last: true,
        ),
      ],
    );
  }
}

/// Testo da incollare in una segnalazione: niente nomi né indirizzi dei
/// membri, solo la configurazione dell'hub.
String diagnostics(SystemInfo s) => [
  'MineSync hub ${s.version}${s.build == null ? '' : ' (${s.build})'}',
  'uptime_s: ${(s.time - s.startedAt) ~/ 1000}',
  'disk: free=${s.disk.free} total=${s.disk.total} minFree=${s.disk.minFree}',
  'http: ${s.http}',
  'dns: on=${s.dns.on} zone=${s.dns.zone ?? '-'} addr=${s.dns.addr ?? '-'}'
      '${s.dns.error == null ? '' : ' error=${s.dns.error}'}',
  'hosts: ${s.allowedHosts.length}',
  'data: ${s.dataDir}',
  'minFreeEnv: ${s.minFreeEnv ?? '-'}',
  'dl: ${s.dlDir == null ? '-' : 'set'}',
  for (final u in s.updates) 'update ${u.platform} ${u.version} signed=${u.signed}',
  'tz: ${s.timeZone ?? '-'}',
  'web: ${s.webBuild ?? '-'}',
].join('\n');
