import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:havencat/app.dart';
import 'package:havencat/ui/settings/settings_screen.dart';
import 'package:havencat/ui/settings/widgets/account_tile.dart';
import 'package:havencat/ui/settings/widgets/add_account_dialog.dart';

/// Settings screen tests.
///
/// The app seeds a mock account on startup, so the accounts list is never
/// empty in these tests. The mock account has no API key (it doesn't need
/// one), so it serves as the "active by default" account we can deactivate
/// by adding + activating an API-key account.
void main() {
  testWidgets('renders the seeded mock account and an Add button', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Mock'), findsOneWidget);
    expect(find.byTooltip('Add account'), findsOneWidget);
  });

  testWidgets('opening Add Account and submitting adds a new account', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('Add account'));
    await tester.pumpAndSettle();

    // The provider picker bottom sheet shows all providers grouped into
    // subscription + API-key sections. Tap the OpenAI-compatible tile to
    // dismiss the sheet and open the AddAccountDialog with that provider
    // pre-selected.
    await tester.tap(find.text('OpenAI-compatible').first);
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountDialog), findsOneWidget);

    // Display name is prefilled from the provider; just enter the API key.
    await tester.enterText(
      find.widgetWithText(TextField, 'API key'),
      'sk-test',
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // The dialog closed and the new account appears in the list.
    expect(find.text('OpenAI-compatible'), findsWidgets);
    expect(find.byType(AddAccountDialog), findsNothing);
  });

  testWidgets('tapping an inactive account activates it', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    // Add an account so there are two to switch between.
    await _addOpenAiAccount(tester, name: 'Second');

    // The mock account is active initially (seeded). Tap the new account's
    // row to activate it. The new account's display name is "Second".
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();

    // The active account shows a check_circle icon; the inactive one shows a
    // delete button. Verify the mock account now has a delete button (i.e.
    // it is no longer active).
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Mock'),
          matching: find.byType(AccountTile),
        ),
        matching: find.byTooltip('Remove account'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('removing an account asks for confirmation then deletes', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await _addOpenAiAccount(tester, name: 'To Delete');

    // Activate the mock account so the new one shows a delete button.
    await tester.tap(find.text('Mock'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('To Delete'),
          matching: find.byType(AccountTile),
        ),
        matching: find.byTooltip('Remove account'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove account?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('To Delete'), findsNothing);
  });
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const ProviderScope(child: HavenChatApp()));
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

/// Adds an OpenAI-compatible account via the provider picker + Add Account
/// dialog with the given [name], entering a dummy API key.
Future<void> _addOpenAiAccount(
  WidgetTester tester, {
  required String name,
}) async {
  await tester.tap(find.byTooltip('Add account'));
  await tester.pumpAndSettle();
  // Tap the OpenAI-compatible tile in the picker sheet; this dismisses the
  // sheet and opens AddAccountDialog with the provider pre-selected.
  await tester.tap(find.text('OpenAI-compatible').first);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Display name'), name);
  await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-test');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}
