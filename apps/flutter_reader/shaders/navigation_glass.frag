// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
#version 460 core
#include <flutter/runtime_effect.glsl>

// Input texture and its dimensions are assigned by ImageFilter.shader.
uniform vec2 uInputSize;
uniform vec2 uExtent;
uniform float uBend;
uniform float uFrost;
uniform sampler2D uBackdrop;
out vec4 fragColor;

vec4 sampleBackdrop(vec2 uv) {
  // FlutterFragCoord and the filter input share the engine's orientation.
  // A second GLES Y flip mirrors unrelated page content into the glass.
  return texture(uBackdrop, clamp(uv, vec2(0.001), vec2(0.999)));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uInputSize;
  vec2 p = (uv - 0.5) * uExtent;
  float radius = uExtent.y * 0.5;
  float spine = max(0.0, uExtent.x * 0.5 - radius);
  vec2 radial = p - vec2(clamp(p.x, -spine, spine), 0.0);
  float lengthToSpine = length(radial);
  vec2 normal = radial / max(lengthToSpine, 0.01);
  float rim = smoothstep(radius * 0.38, radius, lengthToSpine);
  // Displacement is in input texels: a backdrop texture can be larger than
  // this clipped surface, so surface-relative UV offsets would magnify it.
  vec2 bend = normal * uBend * rim * rim / uInputSize;
  vec2 at = uv - bend;
  vec2 stepSize = vec2(1.6 * uFrost) / uInputSize;
  vec4 center = sampleBackdrop(at);
  vec4 frost = (sampleBackdrop(at + vec2(stepSize.x, 0.0))
              + sampleBackdrop(at - vec2(stepSize.x, 0.0))
              + sampleBackdrop(at + vec2(0.0, stepSize.y))
              + sampleBackdrop(at - vec2(0.0, stepSize.y))) * 0.25;
  vec4 color = mix(center, frost, 0.55);
  // A slight chromatic split at the curved rim, with premultiplied alpha kept.
  color.r = mix(color.r, sampleBackdrop(at - bend * 0.06).r, rim * 0.3);
  color.b = mix(color.b, sampleBackdrop(at + bend * 0.06).b, rim * 0.3);
  color.rgb += vec3(0.035 * pow(rim, 5.0)) * color.a;
  fragColor = color;
}
