import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class CredentialSecurityButton extends StatelessWidget {
  const CredentialSecurityButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: kIsWeb
          ? 'Saved only in this browser'
          : 'Protected by this device',
      onPressed: () => _showCredentialSecurityInfo(context),
      icon: Icon(Icons.lock_outline_rounded, size: 18),
      color: context.appColors.textSecondary,
      visualDensity: VisualDensity.compact,
    );
  }
}

Future<void> _showCredentialSecurityInfo(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text('API key privacy'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SecurityPoint(
            icon: Icons.shield_outlined,
            title: kIsWeb
                ? 'Local to this browser'
                : 'Protected on this device',
            detail: kIsWeb
                ? 'Saved in browser-local storage, not synced by HavenCat.'
                : 'Saved through the operating system’s credential storage.',
          ),
          SizedBox(height: 14),
          _SecurityPoint(
            icon: Icons.north_east_rounded,
            title: 'Used only for requests',
            detail: 'Sent only to this account’s configured API endpoint.',
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Done'),
        ),
      ],
    ),
  );
}

class _SecurityPoint extends StatelessWidget {
  const _SecurityPoint({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: context.appColors.brandViolet),
        SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: context.appColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 2),
              Text(
                detail,
                style: TextStyle(
                  color: context.appColors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
