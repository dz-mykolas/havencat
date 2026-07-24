import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'data/services/web_retrieval/web_retrieval_provider_registry.dart';
import 'domain/errors/app_failure.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/settings/widgets/web_search_settings_panel.dart';

const String homeRoute = '/';
const String settingsRoute = '/settings';
const String webSearchSettingsRoute = '/settings/web-search';

String chatRouteFor(String conversationId) {
  return '/${Uri(pathSegments: <String>['chat', conversationId])}';
}

String settingsRouteFor(SettingsSection? section) {
  if (section == null) return settingsRoute;
  return '$settingsRoute/${section.routeSegment}';
}

String webSearchProviderRouteFor(
  String providerKind, {
  bool enableOnSave = false,
}) {
  final String canonicalKind =
      WebRetrievalProviderRegistry.searchProviderFor(providerKind)?.kind ??
      providerKind.trim().toLowerCase();
  return Uri(
    path: '$webSearchSettingsRoute/$canonicalKind',
    queryParameters: enableOnSave
        ? const <String, String>{'enable': '1'}
        : null,
  ).toString();
}

String settingsRouteForFailure(AppFailure failure) {
  final bool webFailure =
      failure.source.subsystem == AppSubsystem.webSearch ||
      failure.source.subsystem == AppSubsystem.webFetch;
  if (!webFailure) return settingsRoute;
  final WebSearchProviderDefinition? provider =
      WebRetrievalProviderRegistry.searchProviderFor(
        failure.source.providerId ?? '',
      );
  return provider == null
      ? webSearchSettingsRoute
      : webSearchProviderRouteFor(provider.kind);
}

Future<void> openSettingsForFailure(BuildContext context, AppFailure failure) {
  final WebSearchProviderDefinition? provider =
      WebRetrievalProviderRegistry.searchProviderFor(
        failure.source.providerId ?? '',
      );
  final bool webFailure =
      failure.source.subsystem == AppSubsystem.webSearch ||
      failure.source.subsystem == AppSubsystem.webFetch;
  if (!webFailure || provider == null) {
    unawaited(context.push<void>(settingsRouteForFailure(failure)));
    return Future<void>.value();
  }

  unawaited(context.push<void>(webSearchSettingsRoute));
  unawaited(context.push<void>(webSearchProviderRouteFor(provider.kind)));
  return Future<void>.value();
}

SettingsSection? settingsSectionFromRoute(String? segment) {
  if (segment == null) return null;
  for (final SettingsSection section in SettingsSection.values) {
    if (section.routeSegment == segment) return section;
  }
  return null;
}

GoRouter createAppRouter({String? initialLocation}) {
  GoRouter.optionURLReflectsImperativeAPIs = true;
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: homeRoute,
        builder: (BuildContext context, GoRouterState state) =>
            const ChatScreen(),
      ),
      GoRoute(
        path: '/chat/:conversationId',
        builder: (BuildContext context, GoRouterState state) =>
            ChatScreen(conversationId: state.pathParameters['conversationId']),
      ),
      GoRoute(
        path: settingsRoute,
        builder: (BuildContext context, GoRouterState state) =>
            _buildSettingsScreen(context, null),
      ),
      GoRoute(
        path: webSearchSettingsRoute,
        builder: (BuildContext context, GoRouterState state) =>
            _buildSettingsScreen(context, SettingsSection.webSearch),
        routes: <RouteBase>[
          GoRoute(
            path: ':provider',
            redirect: (BuildContext context, GoRouterState state) {
              return WebRetrievalProviderRegistry.searchProviderFor(
                        state.pathParameters['provider'] ?? '',
                      ) ==
                      null
                  ? webSearchSettingsRoute
                  : null;
            },
            pageBuilder: (BuildContext context, GoRouterState state) {
              final String providerKind =
                  WebRetrievalProviderRegistry.searchProviderFor(
                    state.pathParameters['provider']!,
                  )!.kind;
              return CustomTransitionPage<void>(
                key: state.pageKey,
                opaque: false,
                barrierDismissible: true,
                barrierColor: Colors.black.withValues(alpha: 0.48),
                barrierLabel: 'Close provider settings',
                transitionDuration: const Duration(milliseconds: 180),
                reverseTransitionDuration: const Duration(milliseconds: 140),
                child: WebSearchProviderConfigurationRoute(
                  providerKind: providerKind,
                  enableOnSave: state.uri.queryParameters['enable'] == '1',
                ),
                transitionsBuilder:
                    (
                      BuildContext context,
                      Animation<double> animation,
                      Animation<double> secondaryAnimation,
                      Widget child,
                    ) {
                      final Animation<double> curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      );
                      return FadeTransition(
                        opacity: curved,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.96,
                            end: 1,
                          ).animate(curved),
                          child: child,
                        ),
                      );
                    },
              );
            },
          ),
        ],
      ),
      GoRoute(
        path: '$settingsRoute/:section',
        redirect: (BuildContext context, GoRouterState state) {
          return settingsSectionFromRoute(state.pathParameters['section']) ==
                  null
              ? settingsRoute
              : null;
        },
        builder: (BuildContext context, GoRouterState state) {
          final SettingsSection section = settingsSectionFromRoute(
            state.pathParameters['section'],
          )!;
          return _buildSettingsScreen(context, section);
        },
      ),
    ],
  );
}

SettingsScreen _buildSettingsScreen(
  BuildContext context,
  SettingsSection? section,
) {
  return SettingsScreen(
    initialSection: section,
    onSectionChanged: (SettingsSection? next) =>
        _changeSettingsSection(context, current: section, next: next),
    onConfigureWebSearchProvider:
        (String providerKind, {bool enableOnSave = false}) {
          context.push(
            webSearchProviderRouteFor(providerKind, enableOnSave: enableOnSave),
          );
        },
  );
}

void _changeSettingsSection(
  BuildContext context, {
  required SettingsSection? current,
  required SettingsSection? next,
}) {
  if (next == null) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.replace(settingsRoute);
    }
    return;
  }
  final String route = settingsRouteFor(next);
  if (current == null) {
    context.push(route);
  } else {
    context.replace(route);
  }
}
