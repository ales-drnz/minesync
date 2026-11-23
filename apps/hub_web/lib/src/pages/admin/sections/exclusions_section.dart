// Esclusioni predefinite per profilo (minecraft/generico, con quanti server
// le usano): pattern di sistema bloccati, aggiungi/togli, «prova un
// percorso» con `POST /exclusions/test` sulla lista in bozza.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../shell/feedback.dart';
import '../../../state/hub_state.dart';
import '../../../widgets/page.dart';
import '../admin_data.dart';
import '../admin_widgets.dart';

class ExclusionsSection extends StatefulWidget {
  const ExclusionsSection({super.key});

  @override
  State<ExclusionsSection> createState() => _ExclusionsSectionState();
}

class _ExclusionsSectionState extends State<ExclusionsSection> {
  var _profile = Profile.minecraft;
  final _add = TextEditingController();
  final _path = TextEditingController();
  String? _addError;
  ExclusionTest? _result;
  Object? _testError;
  bool _testing = false;

  @override
  void dispose() {
    _add.dispose();
    _path.dispose();
    super.dispose();
  }

  String get _field => _profile.name;

  List<String> _list(AdminData d) => List<String>.from(d.value('exclusions', _field)! as List);

  void _addPattern() {
    final d = AdminScope.read(context);
    final b = context.s.admin.bot;
    final p = _add.text.trim();
    if (p.isEmpty) return;
    final list = _list(d);
    if (list.contains(p) || systemExclusions.contains(p)) {
      setState(() => _addError = b.duplicate);
      return;
    }
    if (p.length > 256) {
      setState(() => _addError = b.tooLong);
      return;
    }
    setState(() => _addError = null);
    _add.clear();
    d.set('exclusions', _field, [...list, p]);
  }

  void _remove(String p) {
    final d = AdminScope.read(context);
    d.set('exclusions', _field, _list(d)..remove(p));
  }

  Future<void> _test() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final d = AdminScope.read(context);
    setState(() => _testing = true);
    try {
      final r = await d.app.api.testExclusion(path: path, profile: _profile, patterns: _list(d));
      if (mounted) {
        setState(() {
          _result = r;
          _testError = null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _testError = e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final app = HubStateScope.of(context);
    final s = context.s;
    final b = s.admin.bot;
    final g = PixelScope.of(context);
    final c = MsTheme.colorsOf(context);
    int count(Profile p) => app.spaces.where((sp) => sp.profile == p).length;
    final list = _list(d);
    Widget row(Widget child, {required bool locked}) => DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.pxShadow, width: g.d(2)),
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: g.d(44)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(g.d(8), g.d(locked ? 6 : 2), g.d(2), g.d(locked ? 6 : 2)),
          child: child,
        ),
      ),
    );
    final listPane = MsStack(
      gap: 12,
      children: [
        MsField(
          label: b.profile,
          child: MsSegmented<Profile>(
            semanticLabel: b.profile,
            value: _profile,
            segments: [
              MsSegment(
                value: Profile.minecraft,
                label: b.profileCount(b.minecraft, count(Profile.minecraft)),
              ),
              MsSegment(
                value: Profile.generic,
                label: b.profileCount(b.generic, count(Profile.generic)),
              ),
            ],
            onChanged: (p) => setState(() {
              _profile = p;
              _result = null;
              _addError = null;
            }),
          ),
        ),
        MsSlot(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in systemExclusions)
                row(
                  locked: true,
                  Row(
                    children: [
                      Expanded(child: MsText(p, kind: MsTextKind.mono)),
                      MsChip(b.system, icon: const MsIcon(MsIcons.lock)),
                    ],
                  ),
                ),
              for (final p in list)
                row(
                  locked: false,
                  Row(
                    children: [
                      Expanded(child: MsText(p, kind: MsTextKind.mono)),
                      MsButton.icon(
                        icon: const MsIcon(MsIcons.x),
                        semanticLabel: b.removePattern(p),
                        size: MsButtonSize.sm,
                        variant: MsButtonVariant.ghost,
                        onPressed: () => _remove(p),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        MsInputGroup(
          input: MsTextInput(
            controller: _add,
            mono: true,
            placeholder: b.newPatternHint,
            semanticLabel: b.newPattern,
            error: _addError != null,
            onSubmitted: (_) => _addPattern(),
          ),
          actions: [
            MsButton(label: b.add, icon: const MsIcon(MsIcons.plus), onPressed: _addPattern),
          ],
        ),
        if (_addError != null) MsFieldError(_addError!),
        FieldFoot(
          section: 'exclusions',
          field: _field,
          text: (v) => '${(v! as List).length} pattern',
        ),
      ],
    );
    final r = _result;
    final testPane = MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText(b.testTitle, weight: 600),
        MsText.small(b.testHint, tone: MsTextTone.secondary),
        MsInputGroup(
          input: MsTextInput(
            controller: _path,
            mono: true,
            placeholder: b.testPlaceholder,
            semanticLabel: b.testTitle,
            onSubmitted: (_) => _test(),
          ),
          actions: [
            MsButton(
              label: b.testButton,
              icon: const MsIcon(MsIcons.search),
              loading: _testing,
              onPressed: _testing ? null : _test,
            ),
          ],
        ),
        if (_testError != null)
          MsFieldError(errorText(s, _testError!))
        else if (r != null)
          r.excluded
              ? MsRow(
                  gap: 8,
                  children: [
                    MsPill(b.excluded, tone: MsStatusTone.info),
                    MsText(r.path, kind: MsTextKind.mono, tone: MsTextTone.secondary),
                    if (r.source == ExclusionSource.system)
                      MsText.small(b.bySystem)
                    else
                      MsText.small(b.byRule),
                    if (r.pattern != null) MsCode(r.pattern!),
                  ],
                )
              : MsRow(
                  gap: 8,
                  children: [
                    MsText(r.path, kind: MsTextKind.mono, tone: MsTextTone.secondary),
                    MsPill(b.goesToHub, tone: MsStatusTone.ok),
                  ],
                ),
        MsText.small(b.exNote, tone: MsTextTone.secondary),
      ],
    );
    return SectionPanel(
      title: b.exTitle,
      icon: MsIcons.filter,
      children: [
        MsText(b.exLead, tone: MsTextTone.secondary),
        Padding(
          padding: EdgeInsets.only(top: g.d(8)),
          child: MsRow(
            gap: 16,
            children: [
              for (final (code, what) in b.exSyntax)
                MsRow(
                  gap: 6,
                  children: [
                    MsCode(code),
                    MsText.small(what, tone: MsTextTone.secondary),
                  ],
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: g.d(18)),
          child: Columns(minWidth: 300, children: [(3, listPane), (2, testPane)]),
        ),
      ],
    );
  }
}
