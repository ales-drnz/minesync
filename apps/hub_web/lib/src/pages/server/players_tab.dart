// Scheda Giocatori: una card per giocatore (avatar generato dal nome, mai
// la skin di Mojang; OP, whitelist, online; tempo di gioco, morti, mob
// uccisi, distanza), ricerca, ordinamento e classifiche per gioco.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../state/hub_state.dart';
import '../../widgets/page.dart';
import 'overview_tab.dart' show RankRow;
import 'server_data.dart';

/// Criterio di ordinamento delle card.
enum PlayerSort { time, deaths, mobs, distance }

int _metric(PlayerInfo p, PlayerSort k) => switch (k) {
  PlayerSort.time => p.playTicks,
  PlayerSort.deaths => p.deaths,
  PlayerSort.mobs => p.mobKills,
  PlayerSort.distance => p.distanceCm,
};

/// Nome da mostrare: quello noto o l'inizio dell'uuid.
String playerName(PlayerInfo p) => p.name ?? p.uuid.split('-').first;

class PlayersTab extends StatefulWidget {
  const PlayersTab({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<PlayersTab> createState() => _PlayersTabState();
}

class _PlayersTabState extends State<PlayersTab> {
  late Future<PlayerList> _list;
  final _query = TextEditingController();
  var _sort = PlayerSort.time;

  @override
  void initState() {
    super.initState();
    _load();
    _query.addListener(() => setState(() {}));
  }

  void _load() {
    _list = HubStateScope.read(context).api.players(widget.space.id);
  }

  @override
  void didUpdateWidget(PlayersTab old) {
    super.didUpdateWidget(old);
    // nuova HEAD o qualcuno è entrato/uscito: si rilegge
    if (old.space.headDigest != widget.space.headDigest ||
        old.space.lock?.info.players.join() != widget.space.lock?.info.players.join()) {
      setState(_load);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayerList>(
    future: _list,
    builder: (context, snap) {
      if (!snap.hasData) return LoadState(error: snap.error, onRetry: () => setState(_load));
      return _body(context, snap.data!);
    },
  );

  Widget _body(BuildContext context, PlayerList list) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final all = list.players;
    if (all.isEmpty) {
      return MsPanel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(24)),
          child: MsEmptyState(
            title: v.noPlayersTitle,
            text: v.noPlayersText,
            art: const MsIcon(MsIcons.players, size: 32),
          ),
        ),
      );
    }
    final whitelistOn = ServerDataScope.of(context).world.value?.properties?.whitelist ?? false;
    final q = _query.text.trim().toLowerCase();
    final shown = all.where((p) => q.isEmpty || playerName(p).toLowerCase().contains(q)).toList()
      ..sort((a, b) => _metric(b, _sort).compareTo(_metric(a, _sort)));
    final online = all.where((p) => p.online).length;
    final ops = all.where((p) => p.op).length;
    final when = list.ts > 0 ? s.fmt.clock(app.localTime(list.ts)) : null;
    final header = LayoutBuilder(
      builder: (context, c) {
        final head = MsStack(
          gap: 4,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MsText.h2(v.playersCount(all.length)),
            MsText(
              v.playersLead(online, ops, whitelistOn, s.fmt.gen(list.n), when),
              tone: MsTextTone.secondary,
            ),
          ],
        );
        final controls = MsRow(
          gap: 12,
          children: [
            SizedBox(
              width: PixelScope.of(context).d(220),
              child: MsTextInput(
                controller: _query,
                placeholder: v.searchPlayer,
                semanticLabel: v.searchPlayer,
              ),
            ),
            MsScrollX(
              child: MsSegmented<PlayerSort>(
                semanticLabel: v.sortBy,
                value: _sort,
                segments: [
                  for (final k in PlayerSort.values)
                    MsSegment(
                      value: k,
                      label: switch (k) {
                        PlayerSort.time => v.sortTime,
                        PlayerSort.deaths => v.sortDeaths,
                        PlayerSort.mobs => v.sortMobs,
                        PlayerSort.distance => v.sortDistance,
                      },
                    ),
                ],
                onChanged: (k) => setState(() => _sort = k),
              ),
            ),
          ],
        );
        return MsStack(
          gap: 16,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [head, controls],
        );
      },
    );
    final host = widget.space.lock?.stale == false ? widget.space.lock!.name : null;
    return MsStack(
      gap: 24,
      children: [
        header,
        if (shown.isEmpty)
          MsText(v.noMatch, tone: MsTextTone.secondary)
        else
          AutoGrid(
            minWidth: 280,
            gap: 20,
            children: [
              for (final p in shown)
                PlayerCard(player: p, whitelistOn: whitelistOn, host: playerName(p) == host),
            ],
          ),
        _Leaderboards(players: all),
      ],
    );
  }
}

class PlayerCard extends StatelessWidget {
  const PlayerCard({super.key, required this.player, required this.whitelistOn, this.host = false});

  final PlayerInfo player;
  final bool whitelistOn;
  final bool host;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final p = player;
    final name = playerName(p);
    final outside = whitelistOn && !p.whitelisted;
    final status = [
      if (p.online) v.playingNow,
      if (p.online && host) v.hostShort,
      if (!p.online && p.lastSeen != null) s.fmt.when(app.localTime(p.lastSeen!), app.now()),
      if (!p.online && outside) v.notWhitelisted,
    ];
    Widget stat(String label, String value) => MsSlot(
      child: MsStack(
        gap: 2,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsText.small(label, tone: MsTextTone.secondary),
          MsText(value, weight: 700, tabular: true),
        ],
      ),
    );
    final g = PixelScope.of(context);
    return MsPanel(
      semanticLabel: name,
      child: MsStack(
        gap: 16,
        children: [
          Row(
            children: [
              MsAvatar(name, size: MsAvatarSize.large),
              const PixelGap(12, 0),
              Expanded(
                child: MsStack(
                  gap: 4,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h3(name, maxLines: 1),
                    if (status.isNotEmpty) MsMeta(status),
                    MsRow(
                      gap: 6,
                      children: [
                        if (p.online) MsPill(v.online, tone: MsStatusTone.ok),
                        if (p.op) MsChip(v.op, tone: MsChipTone.accent),
                        if (p.whitelisted) MsChip(v.whitelist),
                        if (outside) MsChip(v.outsideWhitelist),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Column(
            spacing: g.d(8),
            children: [
              Row(
                spacing: g.d(8),
                children: [
                  Expanded(child: stat(v.playTime, v.playTimeValue(s.fmt, p.playTicks))),
                  Expanded(child: stat(v.deaths, groupInt(s.lang, p.deaths))),
                ],
              ),
              Row(
                spacing: g.d(8),
                children: [
                  Expanded(child: stat(v.mobKills, groupInt(s.lang, p.mobKills))),
                  Expanded(child: stat(v.distance, v.distanceValue(s.lang, p.distanceCm))),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Leaderboards extends StatelessWidget {
  const _Leaderboards({required this.players});
  final List<PlayerInfo> players;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final v = s.server;
    Widget board(PlayerSort k, String title, String Function(PlayerInfo) value) {
      final top = [...players.where((p) => _metric(p, k) > 0)]
        ..sort((a, b) => _metric(b, k).compareTo(_metric(a, k)));
      final best = top.isEmpty ? 1 : _metric(top.first, k);
      return MsPanel(
        title: title,
        child: top.isEmpty
            ? MsText.small(v.noRanking, tone: MsTextTone.secondary)
            : MsStack(
                gap: 12,
                children: [
                  for (final (i, p) in top.take(5).indexed)
                    RankRow(
                      rank: i + 1,
                      name: playerName(p),
                      value: value(p),
                      fraction: _metric(p, k) / best,
                    ),
                ],
              ),
      );
    }

    return MsStack(
      gap: 16,
      children: [
        MsRow(
          gap: 12,
          children: [
            MsText.h2(v.boardsTitle),
            MsText.small(v.boardsNote, tone: MsTextTone.secondary),
          ],
        ),
        AutoGrid(
          minWidth: 280,
          gap: 20,
          children: [
            board(PlayerSort.time, v.playTime, (p) => v.hoursValue(s.fmt, p.playTicks)),
            board(PlayerSort.mobs, v.mobKills, (p) => groupInt(s.lang, p.mobKills)),
            board(
              PlayerSort.distance,
              v.distanceWalked,
              (p) => v.distanceValue(s.lang, p.distanceCm),
            ),
            board(PlayerSort.deaths, v.deaths, (p) => groupInt(s.lang, p.deaths)),
          ],
        ),
      ],
    );
  }
}
