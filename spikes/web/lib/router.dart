// Routing con URL veri: / (panoramica), /admin, /server/:id.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin.dart';
import 'overview.dart';
import 'shell.dart';

final router = GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          HubShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (c, s) => NoTransitionPage(
              child: Title(
                  title: 'Hub · Panoramica',
                  color: Colors.black,
                  child: const OverviewPage())),
        ),
        GoRoute(
          path: '/admin',
          pageBuilder: (c, s) => NoTransitionPage(
              child: Title(
                  title: 'Hub · Admin', color: Colors.black, child: const AdminPage())),
        ),
        GoRoute(
          path: '/server/:id',
          pageBuilder: (c, s) {
            final id = s.pathParameters['id']!;
            return NoTransitionPage(
                child: Title(
                    title: 'Hub · Server $id',
                    color: Colors.black,
                    child: ServerPage(id: id)));
          },
        ),
      ],
    ),
  ],
);
