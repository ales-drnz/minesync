// Accesso e membri: stato di ZTNET con «Verifica ora», URL/token/rete in
// sola lettura (mascherati, dalle variabili d'ambiente), tabella dei membri
// con ricerca e cambio di ruolo (gli admin da configurazione non si
// toccano), tempi di fiducia e di aggiornamento.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../shell/feedback.dart';
import '../../../state/hub_state.dart';
import '../admin_data.dart';
import '../admin_dialogs.dart';
import '../admin_widgets.dart';

class MembersSection extends StatefulWidget {
  const MembersSection({super.key});

  @override
  State<MembersSection> createState() => _MembersSectionState();
}

class _MembersSectionState extends State<MembersSection> {
  final _q = TextEditingController();
  bool _checking = false;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final d = AdminScope.read(context);
    final s = context.s.admin.access;
    setState(() => _checking = true);
    try {
      d.setZtnet(await d.app.api.refreshMembers());
      unawaited(d.reloadMembers());
      if (mounted) toast(context, s.checked);
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _setRole(MemberInfo m, MemberRole role) async {
    final d = AdminScope.read(context);
    final s = context.s.admin.access;
    final app = d.app;
    final name = m.name.isEmpty ? m.id : m.name;
    final self = m.id == app.me?.id;
    final promote = role == MemberRole.admin;
    final ok = await confirmAction(
      context,
      title: promote ? s.promoteTitle(name) : s.demoteTitle(name),
      icon: promote ? MsIcons.crown : MsIcons.user,
      danger: !promote && self,
      confirmLabel: promote ? s.makeAdmin : s.makeMember,
      body: MsStack(
        gap: 12,
        children: [
          MsText(promote ? s.promoteBody(name) : s.demoteBody(name)),
          if (self && !promote) MsText(s.demoteSelf, tone: MsTextTone.err, weight: 600),
        ],
      ),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = m.id);
    try {
      await app.api.setRole(m.id, role);
      if (mounted) toast(context, s.roleDone(name, promote));
      await d.reloadMembers();
      // il proprio ruolo cambia anche l'header e l'accesso a questa pagina
      if (self) unawaited(app.retry());
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final a = s.access;
    final ml = d.members;
    final z = ml?.ztnet;
    return SectionPanel(
      title: s.members,
      icon: MsIcons.players,
      lead: a.membersLead,
      actions: [
        if (z != null)
          MsPill(
            'ZTNET ${_pill(s, z.state)}',
            tone: switch (z.state) {
              ZtnetState.ok => MsStatusTone.ok,
              ZtnetState.error => MsStatusTone.err,
              ZtnetState.off => MsStatusTone.neutral,
            },
          ),
      ],
      children: [
        if (ml == null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(12)),
            child: LoadState(error: d.membersError, title: a.colMember, onRetry: d.reloadMembers),
          )
        else ...[
          Padding(
            padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(12)),
            child: _ZtnetCard(status: z!, checking: _checking, onCheck: _check),
          ),
          _envRow(context, a.ztUrl, MsText(z.url ?? a.notSet, kind: MsTextKind.mono), 'ZTNET_URL'),
          _envRow(context, a.ztToken, _maskedOr(context, z.tokenHint), 'ZTNET_API_TOKEN'),
          _envRow(context, a.ztNetwork, _maskedOr(context, z.networkHint), 'ZTNET_NETWORK_ID'),
          Padding(
            padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(12)),
            child: MsText.small(a.secretsNote, tone: MsTextTone.secondary),
          ),
          _membersTable(context, ml),
        ],
        NumberSetting(
          section: 'members',
          field: 'trustHours',
          label: a.trust,
          hint: a.trustHint,
          unit: s.unitHours,
          text: (v) => s.hours(v! as int),
        ),
        NumberSetting(
          section: 'members',
          field: 'refreshSeconds',
          label: a.refresh,
          hint: a.refreshHint,
          unit: s.unitSeconds,
          text: (v) => s.seconds(v! as int),
          defaultText: a.refreshDefault(d.defaultOf('members', 'refreshSeconds')! as int, 10),
          last: true,
        ),
      ],
    );
  }

  static String _pill(AdminStrings s, ZtnetState st) => switch (st) {
    ZtnetState.ok => s.pillOk,
    ZtnetState.error => s.pillError,
    ZtnetState.off => s.pillOff,
  };

  Widget _maskedOr(BuildContext context, String? hint) => hint == null
      ? MsText(context.s.admin.access.notSet, tone: MsTextTone.secondary)
      : MsCode(masked(hint));

  Widget _envRow(BuildContext context, String label, Widget value, String variable) => SettingRow(
    label: label,
    dense: true,
    line: 36,
    child: EnvValue(value: value, variable: variable),
  );

  Widget _membersTable(BuildContext context, MemberList ml) {
    final g = PixelScope.of(context);
    final s = context.s;
    final a = s.admin.access;
    final app = HubStateScope.of(context);
    final q = _q.text.trim().toLowerCase();
    final shown = [
      for (final m in ml.members)
        if (q.isEmpty ||
            m.name.toLowerCase().contains(q) ||
            m.id.toLowerCase().contains(q) ||
            (m.ip ?? '').contains(q))
          m,
    ];
    Widget last(MemberInfo m) {
      final t = m.lastSeen;
      if (t == null) return MsText.small(a.never, tone: MsTextTone.secondary);
      final when = app.localTime(t);
      if (app.now().difference(when).inMinutes < 2) return MsText.small(a.now);
      return MsText.small(s.fmt.ago(when, app.now()));
    }

    Widget role(MemberInfo m) => MsStack(
      gap: 4,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.role == MemberRole.admin)
          MsChip(a.roleAdmin, tone: MsChipTone.accent, icon: const MsIcon(MsIcons.crown))
        else
          MsText.small(a.roleMember),
        if (m.fromConfig) MsText.small(a.fromConfig, tone: MsTextTone.secondary),
      ],
    );

    Widget action(MemberInfo m) {
      final name = m.name.isEmpty ? m.id : m.name;
      if (!m.authorized) {
        return MsStack(
          gap: 4,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MsPill(a.notAuthorized, tone: MsStatusTone.warn),
            MsText.small(a.authorizeInZtnet, tone: MsTextTone.secondary),
          ],
        );
      }
      if (m.fromConfig) return MsText.small(a.notRemovable, tone: MsTextTone.tertiary);
      final admin = m.role == MemberRole.admin;
      return MsButton(
        label: admin ? a.makeMember : a.makeAdmin,
        size: MsButtonSize.sm,
        loading: _busy == m.id,
        semanticLabel: admin ? a.makeMemberFor(name) : a.makeAdminFor(name),
        onPressed: _busy != null
            ? null
            : () => _setRole(m, admin ? MemberRole.member : MemberRole.admin),
      );
    }

    final rows = [
      for (final m in shown)
        [
          MsRow(
            gap: 10,
            wrap: false,
            children: [
              MsAvatar(m.name.isEmpty ? m.id : m.name, size: MsAvatarSize.small),
              // il node id sotto il nome: la tabella resta larga come il riquadro
              MsStack(
                gap: 0,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MsText(
                    m.name.isEmpty ? a.noName : m.name,
                    weight: 700,
                    tone: m.name.isEmpty ? MsTextTone.secondary : MsTextTone.primary,
                  ),
                  MsText(m.id, kind: MsTextKind.mono, tone: MsTextTone.secondary),
                ],
              ),
              if (m.id == app.me?.id) MsChip(a.you),
            ],
          ),
          MsText(m.ip ?? '—', kind: MsTextKind.mono),
          last(m),
          role(m),
          action(m),
        ],
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: g.d(12)),
      child: MsStack(
        gap: 12,
        children: [
          MsRow(
            gap: 12,
            children: [
              MsText.label(a.seenTitle(ml.members.length)),
              SizedBox(
                width: g.d(260),
                child: MsTextInput(
                  controller: _q,
                  placeholder: a.searchMember,
                  semanticLabel: a.searchMember,
                ),
              ),
            ],
          ),
          if (shown.isEmpty)
            MsText(a.noMatch, tone: MsTextTone.secondary)
          else
            MsScrollX(
              child: MsTable(
                semanticLabel: a.seenTitle(ml.members.length),
                columns: [
                  MsTableColumn(a.colMemberNode),
                  MsTableColumn(a.colIp),
                  MsTableColumn(a.colLast),
                  MsTableColumn(a.colRole),
                  MsTableColumn(a.colActions, end: true),
                ],
                rows: rows,
              ),
            ),
          MsText.rich(
            [for (final (t, b) in a.membersNote) MsSpan(t, strong: b)],
            kind: MsTextKind.small,
            tone: MsTextTone.secondary,
          ),
        ],
      ),
    );
  }
}

class _ZtnetCard extends StatelessWidget {
  const _ZtnetCard({required this.status, required this.checking, required this.onCheck});

  final ZtnetStatus status;
  final bool checking;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.admin.access;
    final app = HubStateScope.of(context);
    final now = app.now();
    final parts = <String>[
      if (status.state == ZtnetState.off)
        a.ztOffText
      else if (status.lastRefresh != null)
        a.ztRefreshed(s.fmt.ago(app.localTime(status.lastRefresh!), now), status.members)
      else
        a.ztNever,
      if (status.lastError != null)
        a.ztLastError(
          status.lastErrorAt == null ? '—' : s.fmt.when(app.localTime(status.lastErrorAt!), now),
          status.lastError!,
        ),
    ];
    return MsAlert(
      tone: switch (status.state) {
        ZtnetState.ok => MsAlertTone.ok,
        ZtnetState.error => MsAlertTone.err,
        ZtnetState.off => MsAlertTone.info,
      },
      title: switch (status.state) {
        ZtnetState.ok => a.ztOk,
        ZtnetState.error => a.ztErr,
        ZtnetState.off => a.ztOff,
      },
      text: parts.join(' '),
      actions: [
        if (status.state != ZtnetState.off)
          MsButton(
            label: a.checkNow,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.refresh),
            loading: checking,
            onPressed: checking ? null : onCheck,
          ),
      ],
    );
  }
}
