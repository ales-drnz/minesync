// Dialogo "Nuovo server" (admin): nome fino a 40 caratteri e tipo. Alla
// creazione porta alla pagina del server.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';

/// Lunghezza massima del nome di un server (design).
const maxServerName = 40;

Future<void> showNewServerDialog(BuildContext context) async {
  final created = await showMsDialog<SpaceDetails>(
    context: context,
    builder: (_) => const NewServerDialog(),
  );
  if (created != null && context.mounted) {
    toast(context, context.s.overview.nsCreated(created.summary.name));
    context.go(HubRoutes.server(created.summary.id));
  }
}

class NewServerDialog extends StatefulWidget {
  const NewServerDialog({super.key});

  @override
  State<NewServerDialog> createState() => _NewServerDialogState();
}

class _NewServerDialogState extends State<NewServerDialog> {
  final _name = TextEditingController();
  var _profile = Profile.minecraft;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final s = context.s;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = s.overview.nsNameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await HubStateScope.read(context).createSpace(name, _profile);
      if (mounted) Navigator.of(context).pop(d);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(s, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final o = s.overview;
    return MsDialog(
      title: o.nsTitle,
      icon: const MsIcon(MsIcons.server),
      onDismiss: () => Navigator.of(context).pop(),
      body: MsStack(
        children: [
          MsField(
            label: o.nsName,
            help: o.nsNameHint,
            error: _error,
            trailingLabel: MsText.small(
              o.nsCounter(_name.text.characters.length, maxServerName),
              tone: MsTextTone.secondary,
              tabular: true,
            ),
            child: MsTextInput(
              controller: _name,
              autofocus: true,
              maxLength: maxServerName,
              error: _error != null,
              onSubmitted: (_) => _create(),
            ),
          ),
          MsField(
            label: o.nsType,
            help: _profile == Profile.minecraft ? o.nsMinecraftHint : o.nsGenericHint,
            child: MsSegmented<Profile>(
              semanticLabel: o.nsType,
              value: _profile,
              segments: [
                MsSegment(value: Profile.minecraft, label: o.nsMinecraft),
                MsSegment(value: Profile.generic, label: o.nsGeneric),
              ],
              onChanged: (p) => setState(() => _profile = p),
            ),
          ),
          MsText.small(o.nsAfter, tone: MsTextTone.secondary),
        ],
      ),
      actions: [
        MsButton(label: s.common.cancel, onPressed: () => Navigator.of(context).pop()),
        MsButton(
          label: o.nsCreate,
          variant: MsButtonVariant.primary,
          loading: _busy,
          onPressed: _busy ? null : _create,
        ),
      ],
    );
  }
}
