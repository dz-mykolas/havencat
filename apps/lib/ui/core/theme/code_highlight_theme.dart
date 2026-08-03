import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_highlight/themes/dracula.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/gruvbox-dark.dart';
import 'package:flutter_highlight/themes/gruvbox-light.dart';
import 'package:flutter_highlight/themes/night-owl.dart';
import 'package:flutter_highlight/themes/nord.dart';
import 'package:flutter_highlight/themes/solarized-light.dart';
import 'package:flutter_highlight/themes/xcode.dart';

import '../../../domain/models/code_theme_preferences.dart';

class CodeHighlightTheme extends InheritedWidget {
  const CodeHighlightTheme({
    required this.option,
    required this.definition,
    required super.child,
    super.key,
  });

  final CodeThemeOption option;
  final CodeThemeDefinition definition;

  static CodeThemeDefinition of(BuildContext context) {
    final CodeHighlightTheme? scope = context
        .dependOnInheritedWidgetOfExactType<CodeHighlightTheme>();
    if (scope == null) {
      throw FlutterError('CodeHighlightTheme is missing above this context.');
    }
    return scope.definition;
  }

  @override
  bool updateShouldNotify(CodeHighlightTheme oldWidget) =>
      option != oldWidget.option || definition != oldWidget.definition;
}

class CodeThemeDefinition {
  const CodeThemeDefinition({required this.label, required this.styles});

  final String label;
  final Map<String, TextStyle> styles;

  TextStyle get root => styles['root']!;
  Color get background => root.backgroundColor!;
  Color get foreground => root.color!;

  Color colorFor(String token) => styles[token]?.color ?? foreground;
}

abstract final class CodeThemeCatalog {
  static const List<CodeThemeOption> dark = <CodeThemeOption>[
    CodeThemeOption.atomOneDark,
    CodeThemeOption.nord,
    CodeThemeOption.dracula,
    CodeThemeOption.nightOwl,
    CodeThemeOption.gruvboxDark,
    CodeThemeOption.githubDark,
  ];

  static const List<CodeThemeOption> light = <CodeThemeOption>[
    CodeThemeOption.github,
    CodeThemeOption.atomOneLight,
    CodeThemeOption.gruvboxLight,
    CodeThemeOption.solarizedLight,
    CodeThemeOption.xcode,
  ];

  static CodeThemeDefinition resolve(
    CodeThemeOption option,
    Brightness brightness,
  ) {
    final CodeThemeOption resolved = option == CodeThemeOption.adaptive
        ? brightness == Brightness.dark
              ? CodeThemeOption.atomOneDark
              : CodeThemeOption.github
        : option;
    return definition(resolved);
  }

  static CodeThemeDefinition definition(CodeThemeOption option) =>
      switch (option) {
        CodeThemeOption.adaptive => throw ArgumentError.value(
          option,
          'option',
          'Adaptive must be resolved against a brightness.',
        ),
        CodeThemeOption.atomOneDark => const CodeThemeDefinition(
          label: 'Atom One Dark',
          styles: atomOneDarkTheme,
        ),
        CodeThemeOption.nord => const CodeThemeDefinition(
          label: 'Nord',
          styles: nordTheme,
        ),
        CodeThemeOption.dracula => const CodeThemeDefinition(
          label: 'Dracula',
          styles: draculaTheme,
        ),
        CodeThemeOption.nightOwl => const CodeThemeDefinition(
          label: 'Night Owl',
          styles: nightOwlTheme,
        ),
        CodeThemeOption.gruvboxDark => const CodeThemeDefinition(
          label: 'Gruvbox Dark',
          styles: gruvboxDarkTheme,
        ),
        CodeThemeOption.githubDark => const CodeThemeDefinition(
          label: 'GitHub Dark',
          styles: _githubDarkTheme,
        ),
        CodeThemeOption.github => const CodeThemeDefinition(
          label: 'GitHub',
          styles: githubTheme,
        ),
        CodeThemeOption.atomOneLight => const CodeThemeDefinition(
          label: 'Atom One Light',
          styles: atomOneLightTheme,
        ),
        CodeThemeOption.gruvboxLight => const CodeThemeDefinition(
          label: 'Gruvbox Light',
          styles: gruvboxLightTheme,
        ),
        CodeThemeOption.solarizedLight => const CodeThemeDefinition(
          label: 'Solarized Light',
          styles: solarizedLightTheme,
        ),
        CodeThemeOption.xcode => const CodeThemeDefinition(
          label: 'Xcode',
          styles: xcodeTheme,
        ),
      };
}

const Map<String, TextStyle> _githubDarkTheme = <String, TextStyle>{
  'root': TextStyle(
    color: Color(0xFFC9D1D9),
    backgroundColor: Color(0xFF0D1117),
  ),
  'doctag': TextStyle(color: Color(0xFFFF7B72)),
  'keyword': TextStyle(color: Color(0xFFFF7B72)),
  'template-tag': TextStyle(color: Color(0xFFFF7B72)),
  'template-variable': TextStyle(color: Color(0xFFFF7B72)),
  'type': TextStyle(color: Color(0xFFFF7B72)),
  'title': TextStyle(color: Color(0xFFD2A8FF)),
  'class': TextStyle(color: Color(0xFFD2A8FF)),
  'function': TextStyle(color: Color(0xFFD2A8FF)),
  'attr': TextStyle(color: Color(0xFF79C0FF)),
  'attribute': TextStyle(color: Color(0xFF79C0FF)),
  'literal': TextStyle(color: Color(0xFF79C0FF)),
  'meta': TextStyle(color: Color(0xFF79C0FF)),
  'number': TextStyle(color: Color(0xFF79C0FF)),
  'operator': TextStyle(color: Color(0xFF79C0FF)),
  'variable': TextStyle(color: Color(0xFF79C0FF)),
  'selector-attr': TextStyle(color: Color(0xFF79C0FF)),
  'selector-class': TextStyle(color: Color(0xFF79C0FF)),
  'selector-id': TextStyle(color: Color(0xFF79C0FF)),
  'regexp': TextStyle(color: Color(0xFFA5D6FF)),
  'string': TextStyle(color: Color(0xFFA5D6FF)),
  'built_in': TextStyle(color: Color(0xFFFFA657)),
  'symbol': TextStyle(color: Color(0xFFFFA657)),
  'comment': TextStyle(color: Color(0xFF8B949E)),
  'code': TextStyle(color: Color(0xFF8B949E)),
  'formula': TextStyle(color: Color(0xFF8B949E)),
  'name': TextStyle(color: Color(0xFF7EE787)),
  'quote': TextStyle(color: Color(0xFF7EE787)),
  'selector-tag': TextStyle(color: Color(0xFF7EE787)),
  'selector-pseudo': TextStyle(color: Color(0xFF7EE787)),
  'subst': TextStyle(color: Color(0xFFC9D1D9)),
  'section': TextStyle(color: Color(0xFF1F6FEB), fontWeight: FontWeight.bold),
  'bullet': TextStyle(color: Color(0xFFF2CC60)),
  'emphasis': TextStyle(color: Color(0xFFC9D1D9), fontStyle: FontStyle.italic),
  'strong': TextStyle(color: Color(0xFFC9D1D9), fontWeight: FontWeight.bold),
  'addition': TextStyle(
    color: Color(0xFFAFF5B4),
    backgroundColor: Color(0xFF033A16),
  ),
  'deletion': TextStyle(
    color: Color(0xFFFFDCD7),
    backgroundColor: Color(0xFF67060C),
  ),
};
