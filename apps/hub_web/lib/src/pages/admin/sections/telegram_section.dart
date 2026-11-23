// Telegram: stato del bot (spento, attivo con chat e ultimo messaggio,
// errore), interruttore, token mai mostrato (ultime 4 cifre, Sostituisci,
// Rimuovi), chat con «Trova chat», lingua, cosa annunciare, tempi, topic
// per server con la prova riga per riga, anteprima e messaggio di prova.
// Gli errori di Telegram (400, 429, 502) si vedono sotto il pulsante.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../../l10n/l10n.dart';
import '../../../shell/feedback.dart';
import '../../../state/hub_state.dart';
import '../../../widgets/page.dart';
import '../admin_data.dart';
import '../admin_dialogs.dart';
import '../admin_widgets.dart';

const _tg = telegramSection;

class TelegramSection extends StatefulWidget {
  const TelegramSection({super.key});

  @override
  State<TelegramSection> createState() => _TelegramSectionState();
}

/// Esito della prova di un topic.
typedef _RowResult = ({bool ok, String text});

class _TelegramSectionState extends State<TelegramSection> {
  bool _howOpen = false;
  bool _finding = false;
  List<TelegramChat>? _chats;
  Object? _findError;
  bool _testing = false;
  Object? _testError;
  final _rows = <String, _RowResult>{};
  final _rowBusy = <String>{};

  AdminData get _d => AdminScope.read(context);

  /// Valori in bozza da provare senza salvarli.
  ({String? chat, String? language}) _drafts() => (
    chat: _d.isDraft(_tg, 'chat') ? _d.value(_tg, 'chat') as String? : null,
    language: _d.isDraft(_tg, 'language') ? _d.value(_tg, 'language') as String? : null,
  );

  Future<void> _sendTest() async {
    final s = context.s;
    final d = _d;
    setState(() {
      _testing = true;
      _testError = null;
    });
    try {
      final v = _drafts();
      final r = await d.app.api.testTelegram(chat: v.chat, language: v.language);
      if (mounted) {
        toast(context, s.admin.bot.testSent(s.fmt.clock(d.app.localTime(r.sentAt))));
      }
    } on Object catch (e) {
      if (mounted) setState(() => _testError = e);
    } finally {
      if (mounted) setState(() => _testing = false);
      unawaited(d.reloadTelegram());
    }
  }

  Future<void> _testRow(SpaceSummary sp) async {
    final s = context.s;
    final d = _d;
    setState(() => _rowBusy.add(sp.id));
    try {
      final v = _drafts();
      final topicDraft = d.isDraft(_tg, 'topics.${sp.id}');
      final r = await d.app.api.testTelegram(
        chat: v.chat,
        language: v.language,
        spaceId: topicDraft ? null : sp.id,
        topic: topicDraft ? d.value(_tg, 'topics.${sp.id}') as String? : null,
      );
      _rows[sp.id] = (ok: true, text: s.admin.bot.arrived(s.fmt.clock(d.app.localTime(r.sentAt))));
    } on Object catch (e) {
      _rows[sp.id] = (ok: false, text: errorText(s, e));
    } finally {
      if (mounted) setState(() => _rowBusy.remove(sp.id));
    }
  }

  Future<void> _find() async {
    setState(() {
      _finding = true;
      _findError = null;
    });
    try {
      final r = await _d.app.api.findTelegramChats();
      if (mounted) setState(() => _chats = r);
    } on Object catch (e) {
      if (mounted) setState(() => _findError = e);
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  Future<void> _replaceToken() async {
    final d = _d;
    final s = context.s;
    final t = await showMsDialog<TelegramStatus>(
      context: context,
      builder: (_) => const _TokenDialog(),
    );
    if (t == null || !mounted) return;
    d.setTelegram(t);
    toast(context, s.admin.bot.tokenSaved);
  }

  Future<void> _removeToken() async {
    final d = _d;
    final b = context.s.admin.bot;
    final ok = await confirmAction(
      context,
      title: b.removeTitle,
      body: MsText(b.removeBody),
      confirmLabel: b.removeConfirm,
      icon: MsIcons.trash,
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      final enabled = d.telegram?.settings.enabled ?? false;
      d.setTelegram(
        await d.app.api.patchTelegram(
          TelegramPatch(removeToken: true, enabled: enabled ? false : null),
        ),
      );
      if (mounted) toast(context, b.tokenRemoved);
    } on Object catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s;
    final a = s.admin;
    final b = a.bot;
    final t = d.telegram;
    if (t == null) {
      return SectionPanel(
        title: a.telegram,
        icon: MsIcons.bell,
        children: [LoadState(error: d.telegramError, title: a.telegram, onRetry: d.reloadTelegram)],
      );
    }
    final g = PixelScope.of(context);
    return SectionPanel(
      title: a.telegram,
      icon: MsIcons.bell,
      actions: [
        MsPill(
          switch (t.state) {
            TelegramState.active => b.pillActive,
            TelegramState.disabled => b.pillOff,
            TelegramState.incomplete => b.pillIncomplete,
            TelegramState.error => b.pillError,
          },
          tone: switch (t.state) {
            TelegramState.active => MsStatusTone.ok,
            TelegramState.disabled => MsStatusTone.neutral,
            TelegramState.incomplete => MsStatusTone.warn,
            TelegramState.error => MsStatusTone.err,
          },
        ),
      ],
      children: [
        Padding(
          padding: EdgeInsets.only(top: g.d(4), bottom: g.d(4)),
          child: _StateAlert(status: t),
        ),
        SwitchSetting(
          section: _tg,
          field: 'enabled',
          label: b.enabled,
          hint: b.enabledHint,
          foot: false,
        ),
        _tokenRow(context, t),
        _chatRow(context),
        ChoiceSetting(
          section: _tg,
          field: 'language',
          label: b.language,
          options: [('hub', b.langHub), ('it', a.langIt), ('en', a.langEn)],
        ),
        _announceRow(context),
        NumberSetting(
          section: _tg,
          field: 'coalesceMinutes',
          label: b.coalesce,
          hint: b.coalesceHint,
          unit: a.unitMinutes,
          text: (v) => a.minutes(v! as int),
        ),
        NumberSetting(
          section: _tg,
          field: 'pushWarnMinutes',
          label: b.pushWarn,
          hint: b.pushWarnHint,
          unit: a.unitMinutes,
          text: (v) => a.minutes(v! as int),
        ),
        _topics(context, t),
        Padding(
          padding: EdgeInsets.symmetric(vertical: g.d(18)),
          child: _previewAndTest(context),
        ),
      ],
    );
  }

  Widget _tokenRow(BuildContext context, TelegramStatus t) {
    final b = context.s.admin.bot;
    final set = t.settings.tokenSet;
    return SettingRow(
      label: b.token,
      hint: b.tokenHint,
      // pulsante piccolo con il suo bordo esterno in basso
      line: 44,
      child: MsRow(
        gap: 8,
        children: [
          if (set)
            MsCode(masked(t.settings.tokenHint ?? '••••'))
          else
            MsText(b.tokenNone, tone: MsTextTone.secondary),
          MsButton(
            label: set ? b.replace : b.addToken,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.key),
            onPressed: _replaceToken,
          ),
          if (set)
            MsButton(
              label: b.removeToken,
              size: MsButtonSize.sm,
              variant: MsButtonVariant.ghost,
              icon: const MsIcon(MsIcons.trash),
              onPressed: _removeToken,
            ),
        ],
      ),
    );
  }

  Widget _chatRow(BuildContext context) {
    final s = context.s;
    final b = s.admin.bot;
    final chats = _chats;
    return SettingRow(
      label: b.chat,
      hint: b.chatHint,
      line: inputLine,
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextSettingInput(section: _tg, field: 'chat', mono: true, semanticLabel: b.chat),
          MsButton(
            label: b.chatHow,
            size: MsButtonSize.sm,
            variant: MsButtonVariant.ghost,
            icon: MsIcon(_howOpen ? MsIcons.chevDown : MsIcons.chev),
            onPressed: () => setState(() => _howOpen = !_howOpen),
          ),
          if (_howOpen) ...[
            for (final step in b.chatSteps) MsText.small(step, tone: MsTextTone.secondary),
            MsButton(
              label: b.findChat,
              size: MsButtonSize.sm,
              icon: const MsIcon(MsIcons.search),
              loading: _finding,
              onPressed: _finding ? null : _find,
            ),
            if (_findError != null) MsFieldError(errorText(s, _findError!)),
            if (chats != null && chats.isEmpty)
              MsText.small(b.findNone, tone: MsTextTone.secondary)
            else if (chats != null)
              MsList(
                children: [
                  for (final c in chats)
                    MsListRow(
                      title: c.title ?? c.id,
                      meta: listMeta([b.chatKind(c.type), c.id]),
                      trail: MsButton(
                        label: b.useChat,
                        size: MsButtonSize.sm,
                        onPressed: () => _d.set(_tg, 'chat', c.id),
                      ),
                    ),
                ],
              ),
          ],
          FieldFoot(section: _tg, field: 'chat', text: (v) => '$v'),
        ],
      ),
    );
  }

  Widget _announceRow(BuildContext context) {
    final d = AdminScope.of(context);
    final b = context.s.admin.bot;
    Widget box(String key, String label, String desc) => MsCheckbox(
      value: d.value(_tg, 'notify.$key') == true,
      label: label,
      description: desc,
      onChanged: (v) => d.set(_tg, 'notify.$key', v),
    );
    return SettingRow(
      label: b.announce,
      child: MsStack(
        gap: 8,
        children: [
          box('open', b.nOpen, b.nOpenD),
          box('close', b.nClose, b.nCloseD),
          box('alerts', b.nAlerts, b.nAlertsD),
          box('status', b.nStatus, b.nStatusD),
        ],
      ),
    );
  }

  Widget _topics(BuildContext context, TelegramStatus t) {
    final app = HubStateScope.of(context);
    final d = AdminScope.of(context);
    final b = context.s.admin.bot;
    final g = PixelScope.of(context);
    Widget result(SpaceSummary sp) {
      final r = _rows[sp.id];
      if (r != null) {
        return MsText.small(r.text, tone: r.ok ? MsTextTone.ok : MsTextTone.err);
      }
      if (t.missingTopics.contains(sp.id)) {
        return MsText.small(b.topicMissing, tone: MsTextTone.warn);
      }
      final v = (d.value(_tg, 'topics.${sp.id}') ?? '') as String;
      return v.isEmpty ? MsText.small(b.mainChat, tone: MsTextTone.tertiary) : const SizedBox();
    }

    return SettingRow(
      label: b.topics,
      hint: b.topicsHint,
      line: inputLine,
      child: MsStack(
        gap: 8,
        children: [
          for (final sp in app.spaces)
            MsStack(
              gap: 4,
              children: [
                Row(
                  children: [
                    SizedBox(width: g.d(96), child: MsText(sp.name, weight: 600, maxLines: 1)),
                    const PixelGap(8, 0),
                    Expanded(
                      child: TextSettingInput(
                        section: _tg,
                        field: 'topics.${sp.id}',
                        mono: true,
                        placeholder: b.topicPlaceholder(sp.name),
                        semanticLabel: b.topicPlaceholder(sp.name),
                      ),
                    ),
                    const PixelGap(8, 0),
                    MsButton(
                      label: b.testRow,
                      size: MsButtonSize.sm,
                      semanticLabel: b.testTopicFor(sp.name),
                      loading: _rowBusy.contains(sp.id),
                      onPressed: _rowBusy.contains(sp.id) ? null : () => _testRow(sp),
                    ),
                  ],
                ),
                Padding(
                  padding: EdgeInsets.only(left: g.d(104)),
                  child: result(sp),
                ),
                if (fieldError(context, d, _tg, 'topics.${sp.id}') case final e?)
                  Padding(
                    padding: EdgeInsets.only(left: g.d(104)),
                    child: MsFieldError(e),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _previewAndTest(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final b = s.admin.bot;
    final sp =
        app.spaces.where((x) => x.lock != null && !x.lock!.stale).firstOrNull ??
        app.spaces.firstOrNull;
    final lock = sp?.lock;
    final who = lock?.name ?? app.me?.name ?? '';
    final port = lock?.info.port ?? 25565;
    final ip = lock?.ip ?? '…';
    return MsStack(
      gap: 12,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText(b.preview, weight: 600),
        if (sp != null)
          MsSlot(
            child: MsStack(
              gap: 4,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsText(b.previewOpen(sp.name), weight: 700),
                MsText.small(b.previewHost(who, sp.dnsName ?? '$ip:$port')),
                MsRow(
                  gap: 8,
                  children: [
                    MsText.small(b.previewIp('$ip:$port')),
                    MsText.small(s.fmt.clock(app.now().toLocal()), tone: MsTextTone.tertiary),
                  ],
                ),
              ],
            ),
          ),
        MsButton(
          label: b.sendTest,
          variant: MsButtonVariant.primary,
          icon: const MsIcon(MsIcons.play),
          loading: _testing,
          onPressed: _testing ? null : _sendTest,
        ),
        if (_testError != null) MsFieldError('${b.testFailed}: ${errorText(s, _testError!)}'),
      ],
    );
  }
}

class _StateAlert extends StatelessWidget {
  const _StateAlert({required this.status});

  final TelegramStatus status;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final b = s.admin.bot;
    final app = HubStateScope.of(context);
    final t = status;
    String when(int ms) => s.fmt.when(app.localTime(ms), app.now());
    final missing = [for (final id in t.missingTopics) app.space(id)?.name ?? id];
    final main = switch (t.state) {
      TelegramState.disabled => MsAlert(title: b.offTitle, text: b.offText),
      TelegramState.incomplete => MsAlert(
        tone: MsAlertTone.warn,
        title: b.incompleteTitle,
        text: b.incompleteText,
      ),
      TelegramState.active => MsAlert(
        tone: MsAlertTone.ok,
        title: b.activeTitle(t.chatTitle),
        text: t.lastSentAt == null
            ? b.noMessage
            : b.lastSent(when(t.lastSentAt!), t.lastSent ?? ''),
      ),
      TelegramState.error => MsAlert(
        tone: MsAlertTone.err,
        title: b.errorTitle,
        text: b.errorText(t.lastErrorAt == null ? '—' : when(t.lastErrorAt!), t.lastError ?? ''),
      ),
    };
    return MsStack(
      gap: 8,
      children: [
        main,
        if (missing.isNotEmpty)
          MsAlert(tone: MsAlertTone.warn, title: b.missingTopics(s.fmt.names(missing))),
      ],
    );
  }
}

/// Dialogo per un token nuovo: si salva con `PATCH /telegram`, l'errore
/// dell'hub resta nel campo.
class _TokenDialog extends StatefulWidget {
  const _TokenDialog();

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.s;
    final v = _c.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TelegramStatus t = await HubStateScope.read(
        context,
      ).api.patchTelegram(TelegramPatch(token: v));
      if (mounted) Navigator.of(context).pop(t);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(s, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final b = s.admin.bot;
    return MsDialog(
      title: b.tokenDialogTitle,
      icon: const MsIcon(MsIcons.key),
      onDismiss: () => Navigator.of(context).pop(),
      body: MsField(
        label: b.token,
        help: b.tokenDialogHelp,
        error: _error,
        child: MsTextInput(
          controller: _c,
          mono: true,
          obscure: true,
          autofocus: true,
          error: _error != null,
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        MsButton(label: s.common.cancel, onPressed: () => Navigator.of(context).pop()),
        MsButton(
          label: s.common.save,
          variant: MsButtonVariant.primary,
          loading: _busy,
          onPressed: _busy ? null : _save,
        ),
      ],
    );
  }
}
