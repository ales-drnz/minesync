import 'dart:ui' show PointerDeviceKind, SemanticsRole;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/golden.dart';
import 'support.dart';

void _noop() {}

Finder _btn(String label) => find.byWidgetPredicate((w) => w is MsButton && w.label == label);

Widget _p(String text) => Text(text);

Widget _dialogs() => Builder(
  builder: (context) => ColoredBox(
    color: MsTheme.colorsOf(context).scrim,
    child: Padding(
      padding: EdgeInsets.all(PixelScope.of(context).d(24)),
      child: column([
        MsDialog(
          title: 'Aggiornamento pronto',
          icon: const TestIcon(),
          body: _p('MineSync 0.1.1 è stato scaricato e verificato.'),
          actions: [
            const MsButton(label: 'Non ora', variant: MsButtonVariant.ghost, onPressed: _noop),
            const MsButton(
              label: 'Riavvia',
              variant: MsButtonVariant.primary,
              forcedStates: MsStates.focus,
              onPressed: _noop,
            ),
          ],
        ),
        MsDialog(
          title: 'Forzare Survival?',
          icon: const TestIcon(),
          tone: MsDialogTone.danger,
          step: 'Conferma 1 di 2 · solo admin',
          body: _p('alice sta giocando adesso, con 2 amici.'),
          actions: const [
            MsButton(label: 'Annulla', forcedStates: MsStates.focus, onPressed: _noop),
            MsButton(label: 'Continua…', variant: MsButtonVariant.danger, onPressed: _noop),
          ],
        ),
        MsTypeToConfirmDialog(
          title: 'Eliminare il server?',
          icon: const TestIcon(),
          step: 'Ultima chiamata · irreversibile',
          body: _p('Verranno cancellate 128 generazioni di Survival.'),
          expected: 'Survival',
          initialText: 'Surv',
          promptBefore: 'Scrivi ',
          promptAfter: ' per confermare',
          help: 'Il pulsante si attiva quando il nome coincide.',
          cancelLabel: 'Annulla',
          confirmLabel: 'Elimina per sempre',
          onConfirm: _noop,
          onCancel: _noop,
        ),
        MsDialog(
          title: 'Modifiche locali non salvate',
          tone: MsDialogTone.warn,
          icon: const TestIcon(),
          stackedActions: true,
          body: _p('Su questo PC c\'è una versione di Creativo diversa da quella dell\'hub.'),
          actions: const [
            MsButton(
              label: 'Usa la versione dell\'hub',
              variant: MsButtonVariant.primary,
              block: true,
              onPressed: _noop,
            ),
            MsButton(
              label: 'Carica le mie come nuova versione…',
              variant: MsButtonVariant.danger,
              block: true,
              onPressed: _noop,
            ),
          ],
        ),
      ], gap: 24),
    ),
  ),
);

Widget _feedback() => width(
  460,
  column([
    const MsToastStack(
      children: [
        MsToast(
          tone: MsToastTone.ok,
          icon: TestIcon(),
          title: 'Mondo caricato sull\'hub',
          text: 'Generazione #129 · 48 file cambiati · 3 s',
          closeLabel: 'Chiudi notifica',
          onClose: _noop,
        ),
        MsToast(
          tone: MsToastTone.err,
          icon: TestIcon(),
          title: 'Download interrotto',
          text: 'Hub non raggiungibile da 30 s.',
          closeLabel: 'Chiudi notifica',
          onClose: _noop,
          progress: .6,
        ),
        MsToast(
          tone: MsToastTone.warn,
          icon: TestIcon(),
          title: 'Il server è in affanno',
          closeLabel: 'Chiudi notifica',
          onClose: _noop,
        ),
        MsToast(
          icon: TestIcon(),
          title: 'Indirizzo copiato',
          text: 'bob.example',
          closeLabel: 'Chiudi notifica',
        ),
      ],
    ),
    hrow([const MsKbd('Ctrl S'), const MsKbd('Invio'), const MsKbd('D')], gap: 12),
    const MsTooltipBubble(message: 'Salva ora il mondo sull\'hub', shortcut: 'Ctrl S'),
  ], gap: 24),
);

Future<void> _pumpHost(WidgetTester t, Widget child) => t.pumpWidget(host(child));

void main() {
  setUpAll(loadMsFonts);

  goldenSuite('dialogs', _dialogs, size: const Size(700, 1500));
  goldenSuite('feedback', _feedback, size: const Size(600, 700));

  group('dialoghi', () {
    testWidgets('showMsDialog: Esc chiude e restituisce null; focus sul pulsante sicuro', (
      t,
    ) async {
      Future<String?>? result;
      await _pumpHost(
        t,
        Builder(
          builder: (context) => MsButton(
            label: 'Apri',
            onPressed: () => result = showMsDialog<String>(
              context: context,
              builder: (ctx) => MsDialog(
                title: 'Titolo',
                body: const SizedBox(),
                actions: [
                  MsButton(
                    label: 'Annulla',
                    autofocus: true,
                    onPressed: () => Navigator.of(ctx).pop('no'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.bySemanticsLabel('Apri'));
      await t.pumpAndSettle();
      expect(find.byType(MsDialog), findsOneWidget);
      // Invio attiva il pulsante a fuoco (Annulla)
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(await result, 'no');
      await t.tap(find.bySemanticsLabel('Apri'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(MsDialog), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('doppia conferma: solo la seconda conferma', (t) async {
      Future<bool>? result;
      await _pumpHost(
        t,
        Builder(
          builder: (context) => MsButton(
            label: 'Forza',
            onPressed: () => result = showMsTwoStepConfirm(
              context: context,
              secondCancelGoesBack: true,
              first: const MsConfirmStep(
                title: 'Forzare Survival?',
                step: 'Conferma 1 di 2',
                body: SizedBox(),
                cancelLabel: 'Annulla',
                confirmLabel: 'Continua…',
              ),
              second: const MsConfirmStep(
                title: 'Sei proprio sicuro?',
                step: 'Ultima chiamata · 2 di 2',
                body: SizedBox(),
                cancelLabel: 'No, aspetto',
                confirmLabel: 'Sì, forza e gioca',
              ),
            ),
          ),
        ),
      );
      await t.tap(find.bySemanticsLabel('Forza'));
      await t.pumpAndSettle();
      await t.tap(find.bySemanticsLabel('Continua…'));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel('Sì, forza e gioca'), findsOneWidget);
      // annulla al secondo passo: torna al primo
      await t.tap(find.bySemanticsLabel('No, aspetto'));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel('Continua…'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Continua…'));
      await t.pumpAndSettle();
      await t.tap(find.bySemanticsLabel('Sì, forza e gioca'));
      await t.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('scrivi il nome: il pulsante si attiva solo se coincide', (t) async {
      Future<bool>? result;
      await _pumpHost(
        t,
        Builder(
          builder: (context) => MsButton(
            label: 'Elimina',
            onPressed: () => result = showMsTypeToConfirm(
              context: context,
              title: 'Eliminare il server?',
              body: const SizedBox(),
              expected: 'Survival',
              promptBefore: 'Scrivi ',
              promptAfter: ' per confermare',
              cancelLabel: 'Annulla',
              confirmLabel: 'Elimina per sempre',
            ),
          ),
        ),
      );
      await t.tap(find.bySemanticsLabel('Elimina'));
      await t.pumpAndSettle();
      MsButton confirm() => t.widget<MsButton>(
        find.byWidgetPredicate((w) => w is MsButton && w.label == 'Elimina per sempre'),
      );
      await t.enterText(find.byType(EditableText), 'Surv');
      await t.pump();
      expect(confirm().onPressed, isNull);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(find.byType(MsTypeToConfirmDialog), findsOneWidget);
      await t.enterText(find.byType(EditableText), 'Survival');
      await t.pump();
      expect(confirm().onPressed, isNotNull);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('azioni a sinistra: separate da quelle a destra, a capo se stretto', (t) async {
      Widget dialog(double w) => SizedBox(
        width: w,
        child: const MsDialog(
          title: 'Sodium',
          body: SizedBox(),
          leadingActions: [
            MsButton(label: 'Rimuovi…', variant: MsButtonVariant.ghost, onPressed: _noop),
          ],
          actions: [MsButton(label: 'Chiudi', variant: MsButtonVariant.primary, onPressed: _noop)],
        ),
      );
      await _pumpHost(t, Align(alignment: Alignment.topLeft, child: dialog(560)));
      final dlg = t.getRect(find.byType(MsDialog));
      final remove = t.getRect(_btn('Rimuovi…'));
      final close = t.getRect(_btn('Chiudi'));
      // stessa riga: «Rimuovi…» a sinistra, «Chiudi» a destra
      expect((remove.center.dy - close.center.dy).abs(), lessThan(8));
      expect(remove.left - dlg.left, lessThan(dlg.width / 4));
      expect(dlg.right - close.right, lessThan(dlg.width / 4));
      // stretto: tutto a capo senza overflow, l'azione principale resta a destra
      await _pumpHost(t, Align(alignment: Alignment.topLeft, child: dialog(300)));
      expect(t.takeException(), isNull);
      final dlg2 = t.getRect(find.byType(MsDialog));
      final close2 = t.getRect(_btn('Chiudi'));
      expect(dlg2.right - close2.right, lessThan(dlg2.width / 4));
    });

    testWidgets('ruolo alertdialog per i dialoghi di pericolo', (t) async {
      final h = t.ensureSemantics();
      await _pumpHost(
        t,
        const SizedBox(
          width: 600,
          child: MsDialog(
            title: 'Pericolo',
            tone: MsDialogTone.danger,
            body: SizedBox(),
            actions: [],
          ),
        ),
      );
      final d = t.getSemantics(find.byType(MsDialog)).getSemanticsData();
      expect(d.role, SemanticsRole.alertDialog);
      h.dispose();
    });
  });

  group('tooltip', () {
    testWidgets('compare con l\'hover dopo l\'attesa e sparisce all\'uscita', (t) async {
      await _pumpHost(
        t,
        const Padding(
          padding: EdgeInsets.all(80),
          child: MsTooltip(
            message: 'Salva ora',
            shortcut: 'Ctrl S',
            child: MsButton.icon(icon: TestIcon(), semanticLabel: 'Salva', onPressed: _noop),
          ),
        ),
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.byType(MsButton)));
      await t.pump();
      expect(find.byType(MsTooltipBubble), findsNothing);
      await t.pump(MsDuration.d4);
      expect(find.byType(MsTooltipBubble), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await t.pump();
      expect(find.byType(MsTooltipBubble), findsNothing);
    });

    testWidgets('compare subito con il focus da tastiera; Esc lo chiude', (t) async {
      await _pumpHost(
        t,
        const Padding(
          padding: EdgeInsets.all(80),
          child: MsTooltip(
            message: 'Salva ora',
            child: MsButton.icon(icon: TestIcon(), semanticLabel: 'Salva', onPressed: _noop),
          ),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(find.byType(MsTooltipBubble), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(find.byType(MsTooltipBubble), findsNothing);
    });
  });

  group('toast', () {
    testWidgets('host: mostra, chiude da solo dopo la durata, chiusura manuale', (t) async {
      final ctl = MsToastController();
      addTearDown(ctl.dispose);
      await _pumpHost(
        t,
        SizedBox(
          width: 800,
          height: 600,
          child: MsToastHost(
            controller: ctl,
            closeLabel: 'Chiudi notifica',
            child: const SizedBox.expand(),
          ),
        ),
      );
      ctl.show(const MsToastData(title: 'Caricato', duration: Duration(seconds: 2)));
      final id = ctl.show(const MsToastData(title: 'Fisso', duration: null));
      await t.pump();
      await t.pump(MsDuration.d3);
      expect(find.byType(MsToast), findsNWidgets(2));
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.byType(MsToast), findsOneWidget);
      expect(ctl.items.single.$1, id);
      await t.tap(find.bySemanticsLabel('Chiudi notifica'));
      await t.pumpAndSettle();
      expect(find.byType(MsToast), findsNothing);
    });

    testWidgets('ruoli: status, alert per gli errori', (t) async {
      final h = t.ensureSemantics();
      await _pumpHost(
        t,
        const SizedBox(
          width: 420,
          child: Column(
            children: [
              MsToast(title: 'Ok', tone: MsToastTone.ok, closeLabel: 'x'),
              MsToast(title: 'Errore', tone: MsToastTone.err, closeLabel: 'x'),
            ],
          ),
        ),
      );
      final ok = t.getSemantics(find.byType(MsToast).first).getSemanticsData();
      final err = t.getSemantics(find.byType(MsToast).last).getSemanticsData();
      expect(ok.role, SemanticsRole.status);
      expect(err.role, SemanticsRole.alert);
      h.dispose();
    });
  });
}
