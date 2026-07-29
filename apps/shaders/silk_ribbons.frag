#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uOpacity;
uniform float uAmplitude;
uniform float uPhase;
uniform float uDirection;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
uniform float uAccentCount;
uniform vec3 uAccentA;
uniform vec3 uAccentB;
uniform vec3 uAccentC;
uniform vec3 uAccentD;
uniform vec3 uAccentE;

out vec4 fragColor;

const float tau = 6.28318530718;

void composite(
  inout vec3 premultiplied,
  inout float accumulatedAlpha,
  vec3 color,
  float alpha
) {
  float visibleAlpha = alpha * (1.0 - accumulatedAlpha);
  premultiplied += color * visibleAlpha;
  accumulatedAlpha += visibleAlpha;
}

void ribbon(
  inout vec3 premultiplied,
  inout float accumulatedAlpha,
  vec2 uv,
  float base,
  float amplitude,
  float width,
  float widthVariation,
  float frequency,
  float phase,
  float speed,
  float strength,
  vec3 startColor,
  vec3 middleColor,
  vec3 endColor
) {
  float xPhase =
      uv.x * tau * frequency +
      phase +
      uPhase +
      uTime * speed * uDirection;
  float amplitudeScale = mix(0.65, 1.05, uAmplitude);
  float center =
      base +
      sin(xPhase) * amplitude * amplitudeScale +
      sin(
        uv.x * tau * frequency * 1.73 -
        phase * 0.6 +
        uPhase +
        uTime * speed * 2.0 * uDirection
      ) *
          amplitude *
          amplitudeScale *
          0.12;
  float widthPhase =
      uv.x * tau * (0.42 + frequency * 0.22) -
      phase * 0.45 +
      uTime * speed * uDirection;
  float widthPulse = 0.5 + 0.5 * sin(widthPhase);
  float secondaryWidthPulse = 0.5 + 0.5 * sin(widthPhase * 2.0 + 1.2);
  float variedWidth =
      mix(0.3, 1.75, pow(widthPulse, 0.82)) *
      mix(0.9, 1.1, secondaryWidthPulse);
  float breathingWidth =
      width * mix(1.0, variedWidth, clamp(widthVariation, 0.0, 1.0));
  float distanceFromCenter = uv.y - center;
  float normalizedDistance = distanceFromCenter / max(breathingWidth, 0.001);
  float absoluteDistance = abs(normalizedDistance);

  float antialias = 1.5 / max(uSize.y * breathingWidth, 1.0);
  float body =
      1.0 -
      smoothstep(1.0 - antialias, 1.0 + antialias, absoluteDistance);
  float interior =
      body * (0.035 + 0.085 * pow(clamp(absoluteDistance, 0.0, 1.0), 1.4));
  float innerFilaments =
      (
        exp(-pow((normalizedDistance + 0.62) * 10.0, 2.0)) +
        exp(-pow((normalizedDistance - 0.62) * 10.0, 2.0))
      ) *
      body;
  float edgeFilaments =
      (
        exp(-pow((normalizedDistance + 0.92) * 16.0, 2.0)) +
        exp(-pow((normalizedDistance - 0.92) * 16.0, 2.0))
      ) *
      body;
  float outerDistance = max(absoluteDistance - 1.0, 0.0);
  float bloom = exp(-outerDistance * outerDistance * 22.0) * (1.0 - body);

  float alpha =
      (
        interior +
        innerFilaments * 0.16 +
        edgeFilaments * 0.82 +
        bloom * 0.08
      ) *
      uOpacity *
      strength;
  vec3 color = uv.x < 0.5
      ? mix(startColor, middleColor, smoothstep(-0.06, 0.56, uv.x))
      : mix(middleColor, endColor, smoothstep(0.44, 1.06, uv.x));
  float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = clamp(mix(vec3(luminance), color, 1.42) * 1.12, 0.0, 1.0);
  color = mix(
    color,
    vec3(1.0),
    clamp(edgeFilaments * 0.3 + innerFilaments * 0.08, 0.0, 0.34)
  );

  composite(
    premultiplied,
    accumulatedAlpha,
    color,
    clamp(alpha, 0.0, 0.82)
  );
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec3 premultiplied = vec3(0.0);
  float accumulatedAlpha = 0.0;

  float hazeCenter =
      0.56 +
      sin(uv.x * tau * 0.46 - 0.4 + uPhase + uTime * uDirection) * 0.2;
  float haze = exp(-pow((uv.y - hazeCenter) / 0.46, 2.0)) * uOpacity * 0.13;
  vec3 hazeColor = uv.x < 0.5
      ? mix(uColorA, uColorB, uv.x * 2.0)
      : mix(uColorB, uColorC, (uv.x - 0.5) * 2.0);
  float hazeLuminance = dot(hazeColor, vec3(0.2126, 0.7152, 0.0722));
  hazeColor = clamp(
    mix(vec3(hazeLuminance), hazeColor, 1.5) * 1.15,
    0.0,
    1.0
  );
  composite(premultiplied, accumulatedAlpha, hazeColor, haze);

  ribbon(
    premultiplied,
    accumulatedAlpha,
    uv,
    0.54,
    0.3,
    0.31,
    0.56,
    0.48,
    -0.35,
    1.0,
    0.62,
    uColorA,
    uColorB,
    uColorC
  );

  float accentStrength =
      mix(0.76, 0.46, clamp((uAccentCount - 1.0) / 4.0, 0.0, 1.0));
  if (uAccentCount > 0.5) {
    ribbon(
      premultiplied,
      accumulatedAlpha,
      uv,
      0.4,
      0.2,
      0.105,
      0.82,
      0.58,
      -0.35,
      1.0,
      accentStrength,
      uAccentA,
      uAccentA,
      uAccentA
    );
  }
  if (uAccentCount > 1.5) {
    ribbon(
      premultiplied,
      accumulatedAlpha,
      uv,
      0.63,
      0.18,
      0.09,
      0.48,
      0.67,
      1.2,
      -1.0,
      accentStrength,
      uAccentB,
      uAccentB,
      uAccentB
    );
  }
  if (uAccentCount > 2.5) {
    ribbon(
      premultiplied,
      accumulatedAlpha,
      uv,
      0.52,
      0.17,
      0.075,
      0.7,
      0.74,
      2.6,
      2.0,
      accentStrength,
      uAccentC,
      uAccentC,
      uAccentC
    );
  }
  if (uAccentCount > 3.5) {
    ribbon(
      premultiplied,
      accumulatedAlpha,
      uv,
      0.72,
      0.14,
      0.062,
      0.34,
      0.82,
      4.0,
      -2.0,
      accentStrength,
      uAccentD,
      uAccentD,
      uAccentD
    );
  }
  if (uAccentCount > 4.5) {
    ribbon(
      premultiplied,
      accumulatedAlpha,
      uv,
      0.32,
      0.13,
      0.052,
      0.62,
      0.9,
      5.15,
      1.0,
      accentStrength,
      uAccentE,
      uAccentE,
      uAccentE
    );
  }

  fragColor = vec4(premultiplied, accumulatedAlpha);
}
