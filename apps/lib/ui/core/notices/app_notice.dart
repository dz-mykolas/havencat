import 'package:flutter/foundation.dart';

enum NoticeSeverity { info, success, warning, error, critical }

enum NoticePlacement { snackbar, banner, inline, operationCard }

enum NoticeActionKind {
  retry,
  reconnect,
  chooseAccount,
  chooseModel,
  openSettings,
  openBilling,
  configureProvider,
  grantPermission,
  copyDetails,
  dismiss,
}

class NoticeAction {
  const NoticeAction({
    required this.kind,
    required this.label,
    required this.onPressed,
  });

  final NoticeActionKind kind;
  final String label;
  final AsyncCallback onPressed;
}

class AppNotice {
  const AppNotice({
    required this.id,
    required this.severity,
    required this.title,
    required this.message,
    this.placement = NoticePlacement.snackbar,
    this.deduplicationKey,
    this.actions = const <NoticeAction>[],
    this.dismissible = true,
  });

  final String id;
  final NoticeSeverity severity;
  final String title;
  final String message;
  final NoticePlacement placement;
  final String? deduplicationKey;
  final List<NoticeAction> actions;
  final bool dismissible;
}
