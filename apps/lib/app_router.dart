import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/services/web_retrieval/web_retrieval_provider_registry.dart';
import 'domain/errors/app_failure.dart';
import 'domain/models/model_pricing.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/core/navigation/app_route_observer.dart';
import 'ui/pricing/discover_panel.dart';
import 'ui/pricing/pricing_viewmodel.dart';
import 'ui/pricing/widgets/model_detail_sheet.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/settings/poe_oauth_callback_screen.dart';
import 'ui/settings/widgets/web_search_settings_panel.dart';

const String homeRoute = '/';
const String settingsRoute = '/settings';
const String modelsSettingsRoute = '/settings/models';
const String webSearchSettingsRoute = '/settings/web-search';
const String poeOAuthCallbackRoute = '/oauth/poe/callback';

String chatRouteFor(String conversationId) {
  return '/${Uri(pathSegments: <String>['chat', conversationId])}';
}

String settingsRouteFor(SettingsSection? section) {
  if (section == null) return settingsRoute;
  if (section == SettingsSection.models) {
    return modelsCatalogRouteFor(PricingScope.providers);
  }
  return '$settingsRoute/${section.routeSegment}';
}

String modelsCatalogRouteFor(
  PricingScope scope, {
  String? groupId,
  String? modelId,
}) {
  final List<String> segments = <String>[
    'settings',
    'models',
    pricingScopeRouteSegment(scope),
    ?groupId,
    if (modelId != null) 'model',
  ];
  final String path = '/${Uri(pathSegments: segments)}';
  if (modelId == null) return path;
  final String query = Uri(
    queryParameters: <String, String>{'id': modelId},
  ).query;
  return '$path?$query';
}

String pricingScopeRouteSegment(PricingScope scope) => switch (scope) {
  PricingScope.providers => 'providers',
  PricingScope.models => 'models',
  PricingScope.labs => 'labs',
  PricingScope.accounts => 'accounts',
};

PricingScope? pricingScopeFromRoute(String? segment) {
  return switch (segment) {
    'providers' => PricingScope.providers,
    'models' => PricingScope.models,
    'labs' => PricingScope.labs,
    'accounts' => PricingScope.accounts,
    _ => null,
  };
}

PricingScope _requirePricingScope(GoRouterState state) {
  final String? segment = state.pathParameters['scope'];
  return pricingScopeFromRoute(segment) ??
      (throw GoException('Unknown model catalog scope "$segment".'));
}

String _requireModelId(GoRouterState state) {
  final String? modelId = state.uri.queryParameters['id'];
  if (modelId == null || modelId.isEmpty) {
    throw GoException('Model route "${state.uri}" is missing an id.');
  }
  return modelId;
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
    observers: <NavigatorObserver>[appRouteObserver],
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
        path: poeOAuthCallbackRoute,
        builder: (BuildContext context, GoRouterState state) =>
            PoeOAuthCallbackScreen(
              callbackUri: state.uri,
              accountsRoute: modelsCatalogRouteFor(PricingScope.accounts),
            ),
      ),
      GoRoute(
        path: settingsRoute,
        builder: (BuildContext context, GoRouterState state) =>
            _buildSettingsScreen(
              context,
              null,
              pricingScope: PricingScope.providers,
            ),
      ),
      GoRoute(
        path: modelsSettingsRoute,
        redirect: (BuildContext context, GoRouterState state) =>
            modelsCatalogRouteFor(PricingScope.providers),
      ),
      GoRoute(
        path: '$modelsSettingsRoute/:scope',
        redirect: (BuildContext context, GoRouterState state) {
          _requirePricingScope(state);
          return null;
        },
        builder: (BuildContext context, GoRouterState state) {
          final PricingScope scope = _requirePricingScope(state);
          return _buildSettingsScreen(
            context,
            SettingsSection.models,
            pricingScope: scope,
          );
        },
        routes: <RouteBase>[
          GoRoute(
            path: 'model',
            redirect: (BuildContext context, GoRouterState state) {
              final PricingScope scope = _requirePricingScope(state);
              if (scope != PricingScope.models) {
                throw GoException(
                  'Ungrouped model routes are not valid for '
                  '"${pricingScopeRouteSegment(scope)}".',
                );
              }
              _requireModelId(state);
              return null;
            },
            pageBuilder: (BuildContext context, GoRouterState state) =>
                _modelDetailPage(context, state, scope: PricingScope.models),
          ),
          GoRoute(
            path: ':groupId',
            redirect: (BuildContext context, GoRouterState state) {
              final PricingScope scope = _requirePricingScope(state);
              if (scope != PricingScope.providers &&
                  scope != PricingScope.labs) {
                throw GoException(
                  'Grouped model routes are not valid for '
                  '"${pricingScopeRouteSegment(scope)}".',
                );
              }
              return null;
            },
            pageBuilder: (BuildContext context, GoRouterState state) {
              final PricingScope scope = _requirePricingScope(state);
              return NoTransitionPage<void>(
                key: state.pageKey,
                child: _buildSettingsScreen(
                  context,
                  SettingsSection.models,
                  pricingScope: scope,
                  pricingGroupId: state.pathParameters['groupId'],
                ),
              );
            },
            routes: <RouteBase>[
              GoRoute(
                path: 'model',
                redirect: (BuildContext context, GoRouterState state) {
                  _requireModelId(state);
                  return null;
                },
                pageBuilder: (BuildContext context, GoRouterState state) {
                  final PricingScope scope = _requirePricingScope(state);
                  return _modelDetailPage(
                    context,
                    state,
                    scope: scope,
                    groupId: state.pathParameters['groupId'],
                  );
                },
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: webSearchSettingsRoute,
        builder: (BuildContext context, GoRouterState state) =>
            _buildSettingsScreen(context, SettingsSection.webSearch),
        routes: <RouteBase>[
          GoRoute(
            path: ':provider',
            redirect: (BuildContext context, GoRouterState state) {
              final String? provider = state.pathParameters['provider'];
              if (WebRetrievalProviderRegistry.searchProviderFor(
                    provider ?? '',
                  ) ==
                  null) {
                throw GoException('Unknown web-search provider "$provider".');
              }
              return null;
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
          final String? section = state.pathParameters['section'];
          if (settingsSectionFromRoute(section) == null) {
            throw GoException('Unknown settings section "$section".');
          }
          return null;
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
  SettingsSection? section, {
  PricingScope? pricingScope,
  String? pricingGroupId,
}) {
  return SettingsScreen(
    initialSection: section,
    discoverRouting: pricingScope == null
        ? null
        : DiscoverRouting(
            scope: pricingScope,
            groupId: pricingGroupId,
            onSelectScope: (PricingScope scope) =>
                context.replace(modelsCatalogRouteFor(scope)),
            onOpenGroup: (PricingScope scope, String groupId) =>
                context.push(modelsCatalogRouteFor(scope, groupId: groupId)),
            onCloseGroup: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(modelsCatalogRouteFor(pricingScope));
              }
            },
            onOpenModel:
                (PricingScope scope, String? groupId, PricedModel model) =>
                    context.push(
                      modelsCatalogRouteFor(
                        scope,
                        groupId: groupId,
                        modelId: model.id,
                      ),
                    ),
          ),
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

Page<void> _modelDetailPage(
  BuildContext context,
  GoRouterState state, {
  required PricingScope scope,
  String? groupId,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.48),
    barrierLabel: 'Close model details',
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 150),
    child: _CatalogModelDetailRoute(
      scope: scope,
      groupId: groupId,
      modelId: _requireModelId(state),
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
          if (MediaQuery.sizeOf(context).width < 680) {
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          }
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
              child: child,
            ),
          );
        },
  );
}

class _CatalogModelDetailRoute extends ConsumerWidget {
  const _CatalogModelDetailRoute({
    required this.scope,
    required this.modelId,
    this.groupId,
  });

  final PricingScope scope;
  final String? groupId;
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PricingViewModel vm = ref.watch(pricingViewModelProvider);
    final PricedModel? model = vm.modelAt(
      scope: scope,
      groupId: groupId,
      modelId: modelId,
    );
    if (model != null) return ModelDetailRoute(model: model);
    return _ModelRouteStatus(
      loading: vm.loading,
      failed: vm.error != null,
      onRetry: vm.load,
    );
  }
}

class _ModelRouteStatus extends StatelessWidget {
  const _ModelRouteStatus({
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: const EdgeInsets.all(24),
      child: loading
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(failed ? 'Could not load this model' : 'Model not found'),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                    if (failed) ...<Widget>[
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
    if (MediaQuery.sizeOf(context).width >= 680) {
      return Dialog(child: content);
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: SafeArea(top: false, child: content),
      ),
    );
  }
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
