import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

abstract class GenerationBackgroundController {
  Future<void> initialize();

  Future<void> begin({
    required String conversationId,
    required String conversationTitle,
  });

  Future<void> complete();

  Future<void> interrupt();

  Future<void> cancel();

  void setAppVisible(bool visible);

  String? takeSelectedConversation();

  Future<void> Function()? onBackgroundTimeExpired;
  void Function(String conversationId)? onConversationSelected;
}

abstract interface class GenerationProgressReporter {
  Future<void> reportProgress();
}

class InlineGenerationBackgroundController
    implements GenerationBackgroundController {
  @override
  Future<void> Function()? onBackgroundTimeExpired;

  @override
  void Function(String conversationId)? onConversationSelected;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> begin({
    required String conversationId,
    required String conversationTitle,
  }) async {}

  @override
  Future<void> complete() async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> cancel() async {}

  @override
  void setAppVisible(bool visible) {}

  @override
  String? takeSelectedConversation() => null;
}

class GenerationBackgroundService
    implements GenerationBackgroundController, GenerationProgressReporter {
  GenerationBackgroundService({FlutterLocalNotificationsPlugin? notifications})
    : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const MethodChannel _backgroundChannel = MethodChannel(
    'com.example.havencat/generation_background',
  );
  static const int _resultNotificationId = 8102;
  static const String _payloadPrefix = 'conversation:';

  final FlutterLocalNotificationsPlugin _notifications;

  @override
  Future<void> Function()? onBackgroundTimeExpired;

  @override
  void Function(String conversationId)? onConversationSelected;

  bool _initialized = false;
  Future<void>? _initialization;
  bool _permissionRequested = false;
  bool _appVisible = true;
  bool _wasBackgrounded = false;
  String? _conversationId;
  String? _selectedConversationId;
  DateTime? _lastProgressReport;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final Future<void>? pending = _initialization;
    if (pending != null) return pending;

    final Future<void> initialization = _initialize();
    _initialization = initialization;
    try {
      await initialization;
      _initialized = true;
    } finally {
      _initialization = null;
    }
  }

  Future<void> _initialize() async {
    if (!_isMobile) return;

    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    final bool? initialized = await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    if (initialized != true) {
      throw StateError('Local notifications could not be initialized.');
    }
    final NotificationAppLaunchDetails? launchDetails = await _notifications
        .getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _selectPayload(launchDetails?.notificationResponse?.payload);
    }
    _backgroundChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'backgroundTimeExpired') {
        await onBackgroundTimeExpired?.call();
      }
    });
  }

  @override
  Future<void> begin({
    required String conversationId,
    required String conversationTitle,
  }) async {
    await initialize();
    _conversationId = conversationId;
    _wasBackgrounded = !_appVisible;
    _lastProgressReport = null;
    if (!_isMobile) return;

    await _requestPermission();
    await _beginIosBackgroundTime();
  }

  @override
  Future<void> reportProgress() async {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_initialized) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastProgressReport;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastProgressReport = now;
    await _backgroundChannel.invokeMethod<void>('progress');
  }

  @override
  Future<void> complete() async {
    final String? conversationId = _conversationId;
    final bool notify = _wasBackgrounded && conversationId != null;
    try {
      if (notify) {
        await _showResultNotification(
          title: 'Your response is ready',
          body: 'Tap to open the conversation.',
          conversationId: conversationId,
        );
      }
    } finally {
      try {
        await _endPlatformWork();
      } finally {
        _clearActive();
      }
    }
  }

  @override
  Future<void> interrupt() async {
    final String? conversationId = _conversationId;
    final bool notify = _wasBackgrounded && conversationId != null;
    try {
      if (notify) {
        final bool iosFinite = defaultTargetPlatform == TargetPlatform.iOS;
        await _showResultNotification(
          title: 'Generation was interrupted',
          body: iosFinite
              ? 'iOS ended background time. Your partial response was saved — open the app to continue.'
              : 'Your partial response was saved.',
          conversationId: conversationId,
        );
      }
    } finally {
      try {
        await _endPlatformWork();
      } finally {
        _clearActive();
      }
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _endPlatformWork();
    } finally {
      _clearActive();
    }
  }

  @override
  void setAppVisible(bool visible) {
    _appVisible = visible;
    if (!visible && _conversationId != null) _wasBackgrounded = true;
  }

  @override
  String? takeSelectedConversation() {
    final String? value = _selectedConversationId;
    _selectedConversationId = null;
    return value;
  }

  Future<void> _requestPermission() async {
    if (_permissionRequested) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true);
    }
    _permissionRequested = true;
  }

  Future<void> _showResultNotification({
    required String title,
    required String body,
    required String conversationId,
  }) {
    const NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'generation_results',
        'Generation results',
        channelDescription: 'Notifies you when a response is ready.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
      ),
      iOS: DarwinNotificationDetails(presentSound: true),
    );
    return _notifications.show(
      id: _resultNotificationId,
      title: title,
      body: body,
      notificationDetails: details,
      payload: '$_payloadPrefix$conversationId',
    );
  }

  Future<void> _beginIosBackgroundTime() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    await _backgroundChannel.invokeMethod<void>('begin');
  }

  Future<void> _endPlatformWork() async {
    if (!_isMobile || !_initialized) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _backgroundChannel.invokeMethod<void>('end');
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    _selectPayload(response.payload);
  }

  void _selectPayload(String? payload) {
    if (payload == null || !payload.startsWith(_payloadPrefix)) return;
    _selectedConversationId = payload.substring(_payloadPrefix.length);
    onConversationSelected?.call(_selectedConversationId!);
  }

  void _clearActive() {
    _conversationId = null;
    _wasBackgrounded = false;
  }
}
