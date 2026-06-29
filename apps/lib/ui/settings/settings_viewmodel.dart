import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/provider_account_repository.dart';
import '../../data/services/auth/chatgpt_oauth_flow.dart';
import '../../data/services/auth/chatgpt_token_service.dart';
import '../../domain/models/adapter_kind.dart';
import '../../domain/models/oauth_tokens.dart';
import '../../domain/models/provider_account.dart';
import '../../domain/models/provider_definition.dart';
import '../../providers.dart';

/// UI-layer state for the settings screen.
///
/// Mirrors [ChatViewModel]: holds only UI state and forwards user actions to
/// the [ProviderAccountRepository]. It listens to the repository and
/// re-notifies so the view can rebuild with a single `ListenableBuilder`.
///
/// Unlike [ChatViewModel] (which maps [Conversation]s into [ConversationView]s
/// to hide the domain layer's mutable message list), this view model exposes
/// [ProviderAccount]s directly: [ProviderAccount] has no mutable collections,
/// so there is nothing to protect the view from.
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._providers, this._chatGptOAuth, this._chatGptTokens) {
    _providers.addListener(_relay);
  }

  final ProviderAccountRepository _providers;
  final ChatGptOAuthFlow _chatGptOAuth;
  final ChatGptTokenService _chatGptTokens;

  /// All configured accounts (read-only view of the repository's list).
  List<ProviderAccount> get accounts => _providers.accounts;

  /// The id of the currently-active account, or null if none configured.
  String? get activeAccountId => _providers.activeAccountId;

  /// The active account, or null if none configured.
  ProviderAccount? get activeAccount => _providers.activeAccount;

  /// Provider definitions the user can add an API-key account for.
  List<ProviderDefinition> get apiKeyCatalog => ProviderCatalog.apiKey;

  /// Provider definitions the user can add a subscription (OAuth) account for.
  List<ProviderDefinition> get subscriptionCatalog =>
      ProviderCatalog.subscription;

  /// All addable providers, subscription section first (matches the UI layout).
  List<ProviderDefinition> get catalog => ProviderCatalog.all;

  /// Whether the user already has an account for [definitionId]. Backs the
  /// "grey out duplicate subscriptions" UX in the provider picker — a
  /// subscription provider (ChatGPT, Poe) can only be connected once.
  bool hasAccountForDefinition(String definitionId) =>
      _providers.hasAccountForDefinition(definitionId);

  /// API-key definitions keyed by their [ProviderDefinition.modelsDevId],
  /// for quick lookup from the Discover panel's Quick-Add flow. Definitions
  /// with a null `modelsDevId` (e.g. `openai_compatible`) are absent — the
  /// resolver falls back to them separately.
  Map<String, ProviderDefinition> get apiKeyCatalogByModelsDevId {
    final Map<String, ProviderDefinition> out = <String, ProviderDefinition>{};
    for (final ProviderDefinition d in ProviderCatalog.apiKey) {
      if (d.modelsDevId != null) out[d.modelsDevId!] = d;
    }
    return out;
  }

  Future<ProviderAccount> addApiKeyAccount({
    required String definitionId,
    required String displayName,
    required String apiKey,
    Map<String, Object?>? config,
    List<String>? enabledModels,
  }) {
    final Map<String, Object?>? merged = enabledModels == null
        ? config
        : <String, Object?>{
            ...?config,
            'enabledModels': <String>[...enabledModels],
            if (enabledModels.isNotEmpty) 'model': enabledModels.first,
          };
    return _providers.addApiKeyAccount(
      definitionId: definitionId,
      displayName: displayName,
      apiKey: apiKey,
      config: merged,
    );
  }

  /// Updates the set of enabled model ids for an existing account — backs the
  /// Quick-Add "edit models" flow and the chat picker grey-out toggle. An
  /// empty list disables the account in the chat picker.
  Future<void> setAllowedModels(String accountId, List<String> modelIds) {
    return _providers.setAllowedModels(accountId, modelIds);
  }

  /// Starts the ChatGPT device-code OAuth flow. Returns the device code
  /// response so the UI can show the verification URL + user code and poll
  /// for completion via [completeChatGptLogin].
  Future<DeviceCodeResponse> startChatGptLogin() {
    return _chatGptOAuth.requestDeviceCode();
  }

  /// Polls for token completion after [startChatGptLogin]. On success, stores
  /// the account + token and returns the new account.
  ///
  /// [onPolling] is called on each poll attempt while the user hasn't
  /// completed sign-in yet, so the UI can show progress.
  /// [shouldCancel] cancels the in-progress login if it returns true.
  Future<ProviderAccount> completeChatGptLogin({
    required DeviceCodeResponse deviceCode,
    void Function()? onPolling,
    Future<bool> Function()? shouldCancel,
  }) async {
    final ChatGptAuthResult result = await _chatGptOAuth.completeLogin(
      deviceCode: deviceCode,
      onPolling: onPolling,
      shouldCancel: shouldCancel,
    );
    final String displayName = result.planType != null
        ? 'ChatGPT (${result.planType})'
        : 'ChatGPT';
    return _providers.addSubscriptionAccount(
      definitionId: 'chatgpt_subscription',
      displayName: displayName,
      tokens: OAuthTokens(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.expiresAt,
      ),
      config: <String, Object?>{
        if (result.accountId != null) 'accountId': result.accountId,
        if (result.planType != null) 'planType': result.planType,
      },
    );
  }

  void setActive(String accountId) => _providers.setActive(accountId);

  /// Removes an account. For subscription accounts we best-effort revoke the
  /// OAuth tokens server-side before deleting them locally.
  Future<void> remove(String accountId) async {
    ProviderAccount? account;
    for (final ProviderAccount a in _providers.accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    if (account != null && account.kind == AdapterKind.subscription) {
      await _chatGptTokens.revoke(accountId);
    }
    await _providers.remove(accountId);
  }

  void _relay() => notifyListeners();

  @override
  void dispose() {
    _providers.removeListener(_relay);
    super.dispose();
  }
}

final settingsViewModelProvider = ChangeNotifierProvider<SettingsViewModel>((
  ref,
) {
  // ref.read (not ref.watch): SettingsViewModel listens to the repository via
  // addListener. ref.watch would recreate the VM on every notifyListeners(),
  // losing listener subscriptions mid-flight.
  return SettingsViewModel(
    ref.read(providerAccountRepositoryProvider),
    ref.read(chatGptOAuthFlowProvider),
    ref.read(chatGptTokenServiceProvider),
  );
});
