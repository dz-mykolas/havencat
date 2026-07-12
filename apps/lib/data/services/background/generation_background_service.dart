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

class GenerationBackgroundService implements GenerationBackgroundController {
  GenerationBackgroundService({FlutterLocalNotificationsPlugin? notifications})
    : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const MethodChannel _backgroundChannel = MethodChannel(
    'com.example.havencat/generation_background',
  );
  static const int _foregroundNotificationId = 8101;
  static const int _resultNotificationId = 8102;
  static const String _payloadPrefix = 'conversation:';

  final FlutterLocalNotificationsPlugin _notifications;

  @override
  Future<void> Function()? onBackgroundTimeExpired;

  @override
  void Function(String conversationId)? onConversationSelected;

  bool _initialized = false;
  bool _permissionRequested = false;
  bool _appVisible = true;
  bool _wasBackgrounded = false;
  String? _conversationId;
  String? _selectedConversationId;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_isMobile) return;

    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
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
    if (!_isMobile) return;

    await _requestPermission();
    await _beginIosBackgroundTime();
    if (defaultTargetPlatform == TargetPlatform.android) {
      const AndroidNotificationDetails details = AndroidNotificationDetails(
        'active_generation',
        'Active generation',
        channelDescription: 'Shown while HavenCat is generating a response.',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        category: AndroidNotificationCategory.progress,
        showProgress: true,
        indeterminate: true,
      );
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.startForegroundService(
            id: _foregroundNotificationId,
            title: 'HavenCat is generating',
            body: 'Generating a response',
            notificationDetails: details,
            payload: '$_payloadPrefix$conversationId',
            startType: AndroidServiceStartType.startNotSticky,
            foregroundServiceTypes: const <AndroidServiceForegroundType>{
              AndroidServiceForegroundType.foregroundServiceTypeDataSync,
            },
          );
    }
  }

  @override
  Future<void> complete() async {
    final String? conversationId = _conversationId;
    final bool notify = _wasBackgrounded && conversationId != null;
    if (notify) {
      await _showResultNotification(
        title: 'Your response is ready',
        body: 'Tap to open the conversation.',
        conversationId: conversationId,
      );
    }
    await _endPlatformWork();
    _clearActive();
  }

  @override
  Future<void> interrupt() async {
    final String? conversationId = _conversationId;
    final bool notify = _wasBackgrounded && conversationId != null;
    if (notify) {
      await _showResultNotification(
        title: 'Generation was interrupted',
        body: 'Your partial response was saved.',
        conversationId: conversationId,
      );
    }
    await _endPlatformWork();
    _clearActive();
  }

  @override
  Future<void> cancel() async {
    await _endPlatformWork();
    _clearActive();
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
    _permissionRequested = true;
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
    try {
      await _backgroundChannel.invokeMethod<void>('begin');
    } on MissingPluginException {
      // Platform support is best-effort; generation still works in foreground.
    }
  }

  Future<void> _endPlatformWork() async {
    if (!_isMobile || !_initialized) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.stopForegroundService();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _backgroundChannel.invokeMethod<void>('end');
      } on MissingPluginException {
        // The expiration path still persists the partial response in Dart.
      }
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
