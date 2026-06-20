import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/pricing/models_dev_service.dart';
import 'data/services/storage/account_store.dart';
import 'data/services/storage/app_settings.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize real, platform-backed storage and restore the saved session
  // (accounts + active id) before the first frame, so a restart / browser
  // refresh keeps the user signed in. Secrets stay in secure storage; only
  // non-secret metadata lives in SharedPreferences.
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final AccountStore accountStore = AccountStore(prefs: prefs);
  final SecretStore secretStore = SecretStore.secure();

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      accountStoreProvider.overrideWithValue(accountStore),
      secretStoreProvider.overrideWithValue(secretStore),
      appSettingsProvider.overrideWith((_) => AppSettings(prefs: prefs)),
      modelsDevServiceProvider.overrideWithValue(
        ModelsDevService(prefs: prefs),
      ),
    ],
  );
  await container.read(providerAccountRepositoryProvider).load();

  // Pre-warm the models.dev catalog in the background so the pricing browser
  // (Settings -> Discover) opens to ready data instead of a spinner. This is
  // fire-and-forget: it never blocks first-frame, and failures (e.g. offline)
  // are swallowed here and surfaced lazily inside the pricing screen instead.
  unawaited(container.read(modelsDevServiceProvider).load());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const HavenChatApp(),
    ),
  );
}
