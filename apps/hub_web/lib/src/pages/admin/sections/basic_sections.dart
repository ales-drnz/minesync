// Sezioni Admin semplici: Generale (nome e lingua), Sessioni di gioco
// (valori predefiniti, server con valori propri), Protezioni (soglia con
// l'esempio su un server vero), Statistiche.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../router.dart';
import '../../../state/hub_state.dart';
import '../admin_data.dart';
import '../admin_widgets.dart';

class GeneralSection extends StatelessWidget {
  const GeneralSection({super.key});

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final name = (d.value('general', 'name') ?? '') as String;
    return SectionPanel(
      title: s.general,
      icon: MsIcons.gear,
      children: [
        SettingRow(
          label: s.nameLabel,
          hint: s.nameHint,
          line: inputLine,
          child: MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextSettingInput(
                section: 'general',
                field: 'name',
                maxLength: maxHubName,
                semanticLabel: s.nameLabel,
                validate: (v) => v.isEmpty ? s.nameRequired : null,
              ),
              FieldFoot(
                section: 'general',
                field: 'name',
                text: (v) => '$v',
                extra: s.nameCount(name.characters.length, maxHubName),
              ),
            ],
          ),
        ),
        ChoiceSetting(
          section: 'general',
          field: 'language',
          label: s.langLabel,
          hint: s.langHint,
          last: true,
          options: [('auto', s.langAuto), ('it', s.langIt), ('en', s.langEn)],
        ),
      ],
    );
  }
}

/// Avviso «N server hanno valori propri» con il link alla loro scheda
/// Amministrazione.
class OwnValuesAlert extends StatelessWidget {
  const OwnValuesAlert({super.key, required this.section, required this.describe});

  final String section;

  /// Descrizione dei campi sovrascritti di un server.
  final String Function(Map<String, Object?> fields) describe;

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final own = d.overriding(section);
    if (own.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
        top: PixelScope.of(context).d(4),
        bottom: PixelScope.of(context).d(18),
      ),
      child: MsAlert(
        title: s.ownValues(own.length),
        text: s.ownValuesText([for (final (sp, f) in own) '${sp.name}: ${describe(f)}'].join('; ')),
        actions: [
          for (final (sp, _) in own.take(3))
            MsButton(
              label: s.openServer(sp.name),
              size: MsButtonSize.sm,
              onPressed: () => context.go(HubRoutes.server(sp.id, ServerTab.admin)),
            ),
        ],
      ),
    );
  }
}

String describeSessions(AdminStrings s, Map<String, Object?> f) => [
  if (f['autosaveMinutes'] case final int m) s.ovAutosave(m),
  if (f['autostop'] == false) s.ovAutostopOff,
  if (f['autostop'] != false && f['autostopMinutes'] is int)
    s.ovAutostop(f['autostopMinutes']! as int),
  if (f['crashRestarts'] case final int n) s.ovCrash(n),
  if (f['portTest'] case final bool on) s.ovPort(on),
].join(', ');

class SessionsSection extends StatelessWidget {
  const SessionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final stop = d.value('sessions', 'autostop') == true;
    final defStop = d.defaultOf('sessions', 'autostopMinutes')! as int;
    return SectionPanel(
      title: s.sessions,
      icon: MsIcons.play,
      lead: s.sessionsLead,
      children: [
        NumberSetting(
          section: 'sessions',
          field: 'autosaveMinutes',
          label: s.autosave,
          hint: s.autosaveHint,
          unit: s.unitMinutes,
          text: (v) => s.minutes(v! as int),
        ),
        SwitchSetting(
          section: 'sessions',
          field: 'autostop',
          label: s.autostop,
          hint: s.autostopHint,
          foot: false,
          after: MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsRow(
                gap: 10,
                children: [
                  MsText(s.autostopAfter, tone: MsTextTone.secondary),
                  NumberInput(
                    section: 'sessions',
                    field: 'autostopMinutes',
                    enabled: stop,
                    semanticLabel: s.autostopUnit,
                  ),
                  MsText(s.autostopUnit, tone: MsTextTone.secondary),
                ],
              ),
              FieldFoot(
                section: 'sessions',
                field: 'autostop',
                text: (v) => onOff(context, v),
                defaultText: s.autostopDefault(defStop),
              ),
              FieldFoot(
                section: 'sessions',
                field: 'autostopMinutes',
                text: (v) => s.minutes(v! as int),
                defaultText: '',
              ),
            ],
          ),
        ),
        NumberSetting(
          section: 'sessions',
          field: 'crashRestarts',
          label: s.crash,
          hint: s.crashHint,
          unit: s.unitAttempts,
          text: (v) => '$v',
        ),
        SwitchSetting(
          section: 'sessions',
          field: 'portTest',
          label: s.portTest,
          hint: s.portTestHint,
          last: true,
        ),
        OwnValuesAlert(section: 'sessions', describe: (f) => describeSessions(s, f)),
      ],
    );
  }
}

/// Il server su cui fare l'esempio: quello con più file nella HEAD.
SpaceSummary? exampleSpace(List<SpaceSummary> spaces) {
  SpaceSummary? best;
  for (final sp in spaces) {
    final f = sp.head?.stats.files ?? 0;
    if (f > (best?.head?.stats.files ?? 0)) best = sp;
  }
  return best;
}

class ProtectionSection extends StatelessWidget {
  const ProtectionSection({super.key});

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final app = HubStateScope.of(context);
    final pct = d.value('protection', 'massDeletePercent')! as int;
    final minFiles = d.value('protection', 'massDeleteMinFiles')! as int;
    final ex = exampleSpace(app.spaces);
    Widget? example;
    if (ex != null) {
      final files = ex.head!.stats.files;
      example = files < minFiles
          ? MsText.small(s.exampleSmall(ex.name, s.number(files), s.number(minFiles)))
          : MsText.rich([
              for (final (t, b) in s.example(
                ex.name,
                s.number(files),
                s.number(files * pct ~/ 100),
              ))
                MsSpan(t, strong: b),
            ], kind: MsTextKind.small);
    }
    return SectionPanel(
      title: s.protection,
      icon: MsIcons.shield,
      lead: s.protectionLead,
      children: [
        SettingRow(
          label: s.ratio,
          hint: s.ratioHint,
          child: MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: MsSlider(
                      value: pct.clamp(1, 100).toDouble(),
                      min: 1,
                      max: 100,
                      step: 1,
                      semanticLabel: s.ratioSlider,
                      semanticFormatter: (v) => s.percent(v.round()),
                      onChanged: (v) => d.set('protection', 'massDeletePercent', v.round()),
                    ),
                  ),
                  const PixelGap(12, 0),
                  NumberInput(
                    section: 'protection',
                    field: 'massDeletePercent',
                    width: 80,
                    semanticLabel: s.ratio,
                  ),
                  const PixelGap(10, 0),
                  MsText(s.unitPercentFiles, tone: MsTextTone.secondary),
                ],
              ),
              ?example,
              FieldFoot(
                section: 'protection',
                field: 'massDeletePercent',
                text: (v) => s.percent(v! as int),
              ),
            ],
          ),
        ),
        NumberSetting(
          section: 'protection',
          field: 'massDeleteMinFiles',
          label: s.minFiles,
          hint: s.minFilesHint,
          unit: s.unitFiles,
          text: (v) => s.number(v! as int),
          last: true,
        ),
        OwnValuesAlert(
          section: 'protection',
          describe: (f) => f['massDeleteRatio'] is num
              ? s.ovProtection(((f['massDeleteRatio']! as num) * 100).round())
              : s.minFiles,
        ),
      ],
    );
  }
}

class StatsSection extends StatelessWidget {
  const StatsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s.admin;
    return SectionPanel(
      title: s.stats,
      icon: MsIcons.chart,
      children: [
        NumberSetting(
          section: 'stats',
          field: 'sessionsKept',
          label: s.statsKept,
          hint: s.statsKeptHint,
          unit: s.unitSessions,
          text: (v) => '$v',
          last: true,
        ),
      ],
    );
  }
}
