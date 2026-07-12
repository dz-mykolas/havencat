import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Paints [text] using the brand gradient via a [ShaderMask].
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    this.style,
    this.gradient,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final Gradient? gradient;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) =>
          (gradient ?? context.appColors.brandGradient).createShader(bounds),
      child: Text(
        text,
        textAlign: textAlign,
        style: (style ?? TextStyle()).copyWith(color: Colors.white),
      ),
    );
  }
}
