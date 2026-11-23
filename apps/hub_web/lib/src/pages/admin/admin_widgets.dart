// Pezzi comuni alle sezioni Admin: riquadro della sezione con «a caldo»,
// riga di un'impostazione (etichetta e aiuto a sinistra, controllo a
// destra, a capo su schermi stretti), piede del campo (errore,
// «Predefinito: …», «Modificato · era … · Ripristina»), campi numerici,
// interruttori, scelte, valori «impostato all'avvio».
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../shell/feedback.dart';
import '../../widgets/page.dart';
import 'admin_data.dart';

/// Formatta un valore di un campo per «Predefinito: …» e «era …».
typedef ValueText = String Function(Object? v);

/// Riquadro di una sezione: icona, titolo, «a caldo» (o altre azioni),
/// testo introduttivo e righe.
class SectionPanel extends StatelessWidget {
  const SectionPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.lead,
    this.hot = true,
    this.actions = const [],
    this.foot = const [],
  });

  final String title;
  final MsIconData icon;
  final String? lead;
  final bool hot;
  final List<Widget> actions;
  final List<Widget> children;
  final List<Widget> foot;

  @override
  Widget build(BuildContext context) {
    final s = context.s.admin;
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return MsPanel(
      semanticLabel: title,
      head: MsPanelHead(
        title: title,
        plain: true,
        leading: MsSlot(
          padding: const EdgeInsets.all(4),
          child: MsIcon(icon, color: c.accentInk),
        ),
        actions: [
          ...actions,
          // sul telefono «a caldo» toglierebbe posto al titolo
          if (hot && !narrow(context))
            HeadNote(s.hotChip, icon: MsIcons.signal, tone: MsTextTone.accent),
        ],
      ),
      foot: foot,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lead != null)
            Padding(
              padding: EdgeInsets.only(bottom: g.d(4)),
              child: MsText(lead!, tone: MsTextTone.secondary),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// Nota nella testa di un riquadro («senza riavvio», «Sola lettura»):
/// icona e testo piccolo senza cornice, così resta dentro i 40 px della
/// testa invece di toccarne i bordi come un [MsChip].
class HeadNote extends StatelessWidget {
  const HeadNote(this.label, {super.key, required this.icon, this.tone = MsTextTone.secondary});

  final String label;
  final MsIconData icon;
  final MsTextTone tone;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MsIcon(icon, size: 16, color: msToneColor(c, tone)),
        const PixelGap(6, 0),
        MsText.small(label, tone: tone, weight: 600, maxLines: 1),
      ],
    );
  }
}

/// Prima riga di un controllo con una casella di testo (44 px più i
/// bordi esterni), per [SettingRow.line].
const double inputLine = 48;

/// Riga di un'impostazione: etichetta e aiuto a sinistra (almeno 260 px),
/// controllo a destra (almeno 320 px), una sotto l'altra se non c'è posto.
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.last = false,
    this.dense = false,
    this.line = 24,
  });

  final String label;
  final String? hint;
  final Widget child;

  /// Altezza in px di design della prima riga del controllo (36 per chip e
  /// pillole, 44 per caselle e scelte): affiancata, l'etichetta scende di
  /// metà della differenza con la sua riga di 24 px e si centra su di essa.
  final double line;

  /// Ultima riga del riquadro: niente linea sotto.
  final bool last;

  /// Righe più basse (Sistema).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final c = MsTheme.colorsOf(context);
    final left = MsStack(
      gap: 4,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText(label, weight: 600),
        if (hint != null) MsText.small(hint!, tone: MsTextTone.secondary),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(color: c.pxShadow, width: g.d(2)),
              ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: g.d(dense ? 14 : 18)),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth < g.d(260 + 32 + 320)) {
              return MsStack(gap: 12, children: [left, child]);
            }
            final drop = (line - 24) / 2;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: g.d(32),
              children: [
                Expanded(
                  flex: 260,
                  child: drop <= 0
                      ? left
                      : Padding(
                          padding: EdgeInsets.only(top: g.d(drop)),
                          child: left,
                        ),
                ),
                Expanded(flex: 320, child: child),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Testo dell'errore di un campo: quello locale o, se l'hub l'ha rifiutato
/// (testo vuoto), i limiti del campo.
String? fieldError(BuildContext context, AdminData d, String section, String field) {
  final e = d.errorOf(section, field);
  if (e == null) return null;
  if (e.isNotEmpty) return e;
  final r = fieldRanges['$section.$field'];
  final s = context.s.admin;
  return r == null ? s.invalid : s.rangeError(r.$1, r.$2);
}

/// Piede di un campo: errore, «Predefinito: …» (con «Usa il predefinito»
/// se diverso), «Modificato · era … · Ripristina».
class FieldFoot extends StatelessWidget {
  const FieldFoot({
    super.key,
    required this.section,
    required this.field,
    required this.text,
    this.defaultText,
    this.extra,
  });

  final String section;
  final String field;
  final ValueText text;

  /// Testo del predefinito al posto di «Predefinito: valore».
  final String? defaultText;

  /// Riga in più prima del predefinito (es. «12 di 40 caratteri»).
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final err = fieldError(context, d, section, field);
    final def = d.defaultOf(section, field);
    final mod = d.modified(section, field);
    final differs = def != null && !sameValue(def, d.value(section, field));
    final defLine = [
      defaultText ?? (def == null ? null : s.defaultIs(text(def))),
      ?extra,
    ].whereType<String>().join(', ');
    return MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (err != null) MsFieldError(err),
        if (defLine.isNotEmpty)
          MsRow(
            gap: 8,
            children: [
              MsText.small(defLine, tone: MsTextTone.tertiary),
              if (differs && mod == null)
                MsButton(
                  label: s.useDefault,
                  size: MsButtonSize.sm,
                  variant: MsButtonVariant.ghost,
                  onPressed: () => d.set(section, field, def),
                ),
            ],
          ),
        if (mod != null)
          MsRow(
            gap: 8,
            children: [
              MsPill(s.modified, tone: MsStatusTone.warn),
              MsText.small(s.was(text(mod.was)), tone: MsTextTone.secondary),
              MsButton(
                label: s.restore,
                size: MsButtonSize.sm,
                variant: MsButtonVariant.ghost,
                semanticLabel: '${s.restore} ${s.was(text(mod.was))}',
                onPressed: () => d.set(section, field, mod.was),
              ),
            ],
          ),
      ],
    );
  }
}

/// Casella numerica (112 px) che segue il valore del campo e scrive le
/// bozze; il testo non valido resta scritto con l'errore.
class NumberInput extends StatefulWidget {
  const NumberInput({
    super.key,
    required this.section,
    required this.field,
    this.width = 112,
    this.semanticLabel,
    this.enabled = true,
  });

  final String section;
  final String field;
  final double width;
  final String? semanticLabel;
  final bool enabled;

  @override
  State<NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<NumberInput> {
  final _c = TextEditingController();
  int? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = AdminScope.of(context).value(widget.section, widget.field) as int?;
    // il valore è cambiato da fuori (Ripristina, un altro admin): si riscrive
    if (v != _shown && int.tryParse(_c.text.trim()) != v) _c.text = v?.toString() ?? '';
    _shown = v;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String raw) {
    final d = AdminScope.read(context);
    final s = context.s.admin;
    final r = fieldRanges['${widget.section}.${widget.field}'];
    final v = int.tryParse(raw.trim());
    if (v == null || (r != null && (v < r.$1 || v > r.$2))) {
      d.set(
        widget.section,
        widget.field,
        null,
        invalid: r == null ? s.invalid : s.rangeError(r.$1, r.$2),
      );
      return;
    }
    _shown = v;
    d.set(widget.section, widget.field, v);
  }

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    return SizedBox(
      width: PixelScope.of(context).d(widget.width),
      child: MsTextInput(
        controller: _c,
        mono: true,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        error: d.errorOf(widget.section, widget.field) != null,
        semanticLabel: widget.semanticLabel,
        onChanged: _changed,
      ),
    );
  }
}

/// Riga con un numero e la sua unità.
class NumberSetting extends StatelessWidget {
  const NumberSetting({
    super.key,
    required this.section,
    required this.field,
    required this.label,
    required this.unit,
    required this.text,
    this.hint,
    this.defaultText,
    this.extra,
    this.last = false,
    this.below,
  });

  final String section;
  final String field;
  final String label;
  final String? hint;
  final String unit;
  final ValueText text;
  final String? defaultText;
  final String? extra;
  final bool last;

  /// Sotto la casella, prima del piede (esempi, anteprime brevi).
  final Widget? below;

  @override
  Widget build(BuildContext context) => SettingRow(
    label: label,
    hint: hint,
    last: last,
    line: inputLine,
    child: MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsRow(
          gap: 10,
          children: [
            NumberInput(section: section, field: field, semanticLabel: label),
            MsText(unit, tone: MsTextTone.secondary),
          ],
        ),
        ?below,
        FieldFoot(
          section: section,
          field: field,
          text: text,
          defaultText: defaultText,
          extra: extra,
        ),
      ],
    ),
  );
}

/// Riga con un interruttore «Attivo».
class SwitchSetting extends StatelessWidget {
  const SwitchSetting({
    super.key,
    required this.section,
    required this.field,
    required this.label,
    this.hint,
    this.last = false,
    this.foot = true,
    this.after,
  });

  final String section;
  final String field;
  final String label;
  final String? hint;
  final bool last;
  final bool foot;

  /// Controlli che dipendono dall'interruttore (es. i minuti).
  final Widget? after;

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final s = context.s.admin;
    final on = d.value(section, field) == true;
    return SettingRow(
      label: label,
      hint: hint,
      last: last,
      line: 40,
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsSwitch(
            value: on,
            label: on ? s.on : s.off,
            semanticLabel: label,
            onChanged: (v) => d.set(section, field, v),
          ),
          ?after,
          if (foot) FieldFoot(section: section, field: field, text: (v) => onOff(context, v)),
        ],
      ),
    );
  }
}

/// «attivo» / «spento» per i predefiniti.
String onOff(BuildContext context, Object? v) =>
    v == true ? context.s.admin.defaultOn : context.s.admin.off.toLowerCase();

/// Riga con una scelta a segmenti.
class ChoiceSetting extends StatelessWidget {
  const ChoiceSetting({
    super.key,
    required this.section,
    required this.field,
    required this.label,
    required this.options,
    this.hint,
    this.last = false,
  });

  final String section;
  final String field;
  final String label;
  final String? hint;
  final List<(String, String)> options;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    String text(Object? v) => options.firstWhere((o) => o.$1 == v, orElse: () => ('', '$v')).$2;
    return SettingRow(
      label: label,
      hint: hint,
      last: last,
      line: 40,
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsSegmented<String>(
            semanticLabel: label,
            value: d.value(section, field)! as String,
            segments: [for (final o in options) MsSegment(value: o.$1, label: o.$2)],
            onChanged: (v) => d.set(section, field, v),
          ),
          FieldFoot(section: section, field: field, text: text),
        ],
      ),
    );
  }
}

/// «impostato all'avvio» con il nome della variabile d'ambiente: il nome
/// allineato a destra e il chip in fondo alla riga, così da una riga
/// all'altra il chip sta sempre nella stessa colonna.
class EnvTag extends StatelessWidget {
  const EnvTag(this.variable, {super.key});

  final String variable;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: MsText(variable, kind: MsTextKind.mono, tone: MsTextTone.secondary, maxLines: 1),
      ),
      const PixelGap(8, 0),
      MsChip(context.s.admin.envSet, icon: const MsIcon(MsIcons.lock)),
    ],
  );
}

/// Valore di sola lettura con la sua variabile d'ambiente: il valore a
/// sinistra, [EnvTag] contro il bordo destro e centrato sul valore; se non
/// c'è posto, [EnvTag] va sulla riga sotto, sempre a destra.
class EnvValue extends StatelessWidget {
  const EnvValue({super.key, required this.value, this.variable});

  final Widget value;
  final String? variable;

  @override
  Widget build(BuildContext context) {
    // senza variabile il valore resta largo quanto il suo contenuto
    if (variable == null) return Align(alignment: Alignment.centerLeft, child: value);
    final g = PixelScope.of(context);
    return _EnvLine(gap: g.d(12), runGap: g.d(8), dpr: g.dpr, children: [value, EnvTag(variable!)]);
  }
}

class _EnvLine extends MultiChildRenderObjectWidget {
  const _EnvLine({required this.gap, required this.runGap, required this.dpr, super.children});

  final double gap;
  final double runGap;
  final double dpr;

  @override
  _RenderEnvLine createRenderObject(BuildContext context) =>
      _RenderEnvLine(gap: gap, runGap: runGap, dpr: dpr);

  @override
  void updateRenderObject(BuildContext context, _RenderEnvLine renderObject) {
    renderObject
      ..gap = gap
      ..runGap = runGap
      ..dpr = dpr;
  }
}

class _EnvParentData extends ContainerBoxParentData<RenderBox> {}

/// Render di [_EnvLine]: due figli, il valore e l'etichetta.
class _RenderEnvLine extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EnvParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EnvParentData> {
  _RenderEnvLine({required double gap, required double runGap, required double dpr})
    : _gap = gap,
      _runGap = runGap,
      _dpr = dpr;

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _runGap;
  set runGap(double v) {
    if (v == _runGap) return;
    _runGap = v;
    markNeedsLayout();
  }

  double _dpr;
  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EnvParentData) child.parentData = _EnvParentData();
  }

  RenderBox get _value => firstChild!;
  RenderBox get _tag => lastChild!;

  // posizione sul pixel fisico
  double _snap(double v) => (v * _dpr).roundToDouble() / _dpr;

  bool _fits(double width) =>
      _value.getMaxIntrinsicWidth(double.infinity) +
          _gap +
          _tag.getMaxIntrinsicWidth(double.infinity) <=
      width + 1e-6;

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(_value.getMinIntrinsicWidth(height), _tag.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _value.getMaxIntrinsicWidth(height) + _gap + _tag.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) {
    final vh = _value.getMaxIntrinsicHeight(width);
    final th = _tag.getMaxIntrinsicHeight(width);
    return _fits(width) ? math.max(vh, th) : math.max(vh, th) + _runGap + th;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final tag = _tag.getDryLayout(BoxConstraints(maxWidth: w));
    if (_fits(w)) {
      final value = _value.getDryLayout(BoxConstraints(maxWidth: w - tag.width - _gap));
      return constraints.constrain(Size(w, math.max(value.height, tag.height)));
    }
    final value = _value.getDryLayout(BoxConstraints(maxWidth: w));
    final first = math.max(value.height, tag.height);
    return constraints.constrain(Size(w, first + _runGap + tag.height));
  }

  @override
  void performLayout() {
    final w = constraints.maxWidth;
    _tag.layout(BoxConstraints(maxWidth: w), parentUsesSize: true);
    final ts = _tag.size;
    final vd = _value.parentData! as _EnvParentData;
    final td = _tag.parentData! as _EnvParentData;
    // larghezza naturale del valore (senza a capo) per decidere se entra
    // accanto all'etichetta; misurata con un layout e non con le misure
    // intrinseche, che PixelFrame non dà in forma «dry»
    _value.layout(const BoxConstraints(), parentUsesSize: true);
    if (_value.size.width + _gap + ts.width <= w + 1e-6) {
      final vs = _value.size;
      final h = math.max(vs.height, ts.height);
      vd.offset = Offset(0, _snap((h - vs.height) / 2));
      td.offset = Offset(_snap(w - ts.width), _snap((h - ts.height) / 2));
      size = constraints.constrain(Size(w, h));
      return;
    }
    // a capo: la prima riga resta alta almeno quanto l'etichetta, così
    // l'etichetta della riga (SettingRow.line) si centra comunque sul valore
    _value.layout(BoxConstraints(maxWidth: w), parentUsesSize: true);
    final vs = _value.size;
    final first = math.max(vs.height, ts.height);
    vd.offset = Offset(0, _snap((first - vs.height) / 2));
    td.offset = Offset(_snap(w - ts.width), _snap(first + _runGap));
    size = constraints.constrain(Size(w, first + _runGap + ts.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Valore mascherato: «•••••••••••• 7f2a».
String masked(String? hint) => hint == null ? '' : '•••••••••••• $hint';

/// Colore del disco: errore sotto la soglia, avviso sotto il doppio.
MsStatusTone diskTone(DiskInfo d) => d.free < d.minFree
    ? MsStatusTone.err
    : d.free < d.minFree * 2
    ? MsStatusTone.warn
    : MsStatusTone.ok;

/// Quota di disco usata, 0–1.
double diskUsed(DiskInfo d) => d.total <= 0 ? 0 : (1 - d.free / d.total).clamp(0.0, 1.0);

/// Contenuto mentre una parte non è ancora arrivata o è fallita.
class LoadState extends StatelessWidget {
  const LoadState({super.key, this.error, required this.title, this.onRetry});

  final Object? error;
  final String title;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const MsStack(
        gap: 12,
        children: [MsSkeleton.title(), MsSkeleton.text(), MsSkeleton.short()],
      );
    }
    final s = context.s;
    return MsAlert(
      tone: MsAlertTone.err,
      title: title,
      text: errorText(s, error!),
      actions: [
        if (onRetry != null)
          MsButton(
            label: s.common.retry,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.refresh),
            onPressed: onRetry,
          ),
      ],
    );
  }
}

/// Casella di testo legata a un campo (nome dell'hub, chat, topic); il
/// testo si salva senza spazi ai lati.
class TextSettingInput extends StatefulWidget {
  const TextSettingInput({
    super.key,
    required this.section,
    required this.field,
    this.validate,
    this.mono = false,
    this.placeholder,
    this.maxLength,
    this.semanticLabel,
  });

  final String section;
  final String field;

  /// Testo dell'errore per un valore non accettabile, altrimenti null.
  final String? Function(String value)? validate;
  final bool mono;
  final String? placeholder;
  final int? maxLength;
  final String? semanticLabel;

  @override
  State<TextSettingInput> createState() => _TextSettingInputState();
}

class _TextSettingInputState extends State<TextSettingInput> {
  final _c = TextEditingController();
  String? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = (AdminScope.of(context).value(widget.section, widget.field) ?? '') as String;
    if (v != _shown && _c.text.trim() != v) _c.text = v;
    _shown = v;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String raw) {
    final v = raw.trim();
    final err = widget.validate?.call(v);
    if (err == null) _shown = v;
    AdminScope.read(context).set(widget.section, widget.field, v, invalid: err);
  }

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    return MsTextInput(
      controller: _c,
      mono: widget.mono,
      placeholder: widget.placeholder,
      maxLength: widget.maxLength,
      error: d.errorOf(widget.section, widget.field) != null,
      semanticLabel: widget.semanticLabel,
      onChanged: _changed,
    );
  }
}

/// Finestra da telefono (meno di 600 px di design).
bool narrow(BuildContext context) => designWidth(context, MediaQuery.sizeOf(context).width) < 600;
