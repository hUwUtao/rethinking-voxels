// StudioLight Volumetric Scattering
// Direct atlas evaluation during fog ray march — gives correct directional beams
// for spots and halos for points, without depending on voxel injection.

#ifndef STUDIOLIGHT_ENABLE
    #define STUDIOLIGHT_ENABLE 1
#endif
#ifndef STUDIOLIGHT_INTENSITY
    #define STUDIOLIGHT_INTENSITY 1.0
#endif

#include "/lib/lighting/studiolight.glsl"

#ifndef SL_MAX_VOL_LIGHTS
    #define SL_MAX_VOL_LIGHTS 16
#endif

// Henyey-Greenstein phase function
// g = 0 → isotropic, g → 1 → strong forward scattering
float sl_hg_phase(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159 * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

vec3 GetStudioLightFog(vec3 nPlayerPos, vec3 translucentMult,
                       float lViewPos, float lViewPos1, float dither) {
    vec3 fractCamPos = cameraPositionInt.y == -98257195
                       ? fract(cameraPosition) : cameraPositionFract;
    ivec2 metaSize = textureSize(sl_chunkmeta, 0);

    // ── Pass 1: collect active lights from atlas ──
    int   slCount = 0;
    vec3  slWorldPos[SL_MAX_VOL_LIGHTS];
    vec3  slColor   [SL_MAX_VOL_LIGHTS];
    float slRange   [SL_MAX_VOL_LIGHTS];
    int   slType    [SL_MAX_VOL_LIGHTS];
    vec3  slDir     [SL_MAX_VOL_LIGHTS];
    float slCone    [SL_MAX_VOL_LIGHTS]; // outer half-angle for spots
    float slW       [SL_MAX_VOL_LIGHTS]; // area width  (blocks)
    float slH       [SL_MAX_VOL_LIGHTS]; // area height (blocks)

    ivec2 cameraChunk = ivec2(floor(cameraPosition.xz / 16.0));
    for (int cz = 0; cz < metaSize.y && slCount < SL_MAX_VOL_LIGHTS; cz++) {
        for (int cx = 0; cx < metaSize.x && slCount < SL_MAX_VOL_LIGHTS; cx++) {
            int count = sl_chunk_count(ivec2(cx, cz));
            if (count == 0) continue;
            ivec2 lightChunk = cameraChunk + ivec2(cx - metaSize.x / 2, cz - metaSize.y / 2);
            for (int s = 0; s < count && slCount < SL_MAX_VOL_LIGHTS; s++) {
                ivec2 atlasCoord = ivec2(cx, cz) * 16 + ivec2(s % 16, s / 16);
                ivec4 r0 = sl_texel255(sl_lightdata_0, atlasCoord);
                ivec4 r1 = sl_texel255(sl_lightdata_1, atlasCoord);
                ivec4 r2 = sl_texel255(sl_lightdata_2, atlasCoord);
                ivec4 r4 = sl_texel255(sl_lightdata_4, atlasCoord);

                int  encY = r0.g + (r1.r << 8) + (r1.g << 16);
                vec3 wp   = vec3(
                    float(lightChunk.x) * 16.0 + float(r0.r) / 16.0,
                    -64.0 + float(encY) / 1024.0,
                    float(lightChunk.y) * 16.0 + float(r0.b) / 16.0
                );

                float intensity = sl_decodeIntensity(r4) * STUDIOLIGHT_INTENSITY;
                vec3  col       = vec3(r1.b, r1.a, r2.r) / 255.0 * intensity;
                int   ltype     = r0.a;

                float range;
                if (ltype == 0) {
                    range = sl_decodeBlockScalar(r2.g);
                } else if (ltype == 1) {
                    range = sl_decodeBlockScalar(r2.a);
                } else {
                    float w = sl_decodeBlockScalar(r2.g);
                    float h = sl_decodeBlockScalar(r2.b);
                    range = sqrt(w * w + h * h) * 0.75;
                }

                slWorldPos[slCount] = wp;
                slColor   [slCount] = col;
                slRange   [slCount] = max(range, 0.5);
                slType    [slCount] = ltype;
                slDir     [slCount] = sl_decodeDirection(r4);
                slCone    [slCount] = sl_decodeConeAngle(r2);
                slW       [slCount] = sl_decodeBlockScalar(r2.g);
                slH       [slCount] = sl_decodeBlockScalar(r2.b);
                slCount++;
            }
        }
    }
    if (slCount == 0) return vec3(0.0);

    // ── Pass 2: ray march toward fragment, accumulate scatter ──
    float stepMult    = 8.0;
    float maxDist     = min(voxelVolumeSize.x * 0.5, far);
    int   sampleCount = int(maxDist / stepMult + 0.001);
    vec3  traceAdd    = nPlayerPos * stepMult;
    vec3  tracePos    = traceAdd * dither;

    vec3  lightFog = vec3(0.0);
    float g = 0.3; // mild forward scattering — visible beams without blinding glare

    for (int i = 0; i < sampleCount; i++) {
        float lTrace = length(tracePos);
        if (lTrace > lViewPos1) break;
        if (any(greaterThan(abs(tracePos * 2.0), vec3(voxelVolumeSize)))) break;

        vec3 stepWorld = tracePos + cameraPosition - fractCamPos;

        for (int li = 0; li < slCount; li++) {
            vec3  toLight = slWorldPos[li] - stepWorld;
            float dist    = length(toLight);
            if (dist > slRange[li] * 1.5) continue;

            float atten;
            if (slType[li] == 2) { // Area: effective radius for fog scatter
                float radius = sqrt(slW[li] * slW[li] + slH[li] * slH[li]) * 0.5;
                atten = sl_windowed_atten(dist, radius * 3.0);
            } else {
                atten = sl_windowed_atten(dist, slRange[li]);
            }

            if (slType[li] == 1) { // Spot: cone mask
                float cosTheta  = dot(-normalize(toLight), slDir[li]);
                float cosEdge   = cos(slCone[li]);
                float softWidth = max(1.0 - cosEdge, 0.05); // ~5° softness
                float t = clamp((cosTheta - cosEdge) / softWidth, 0.0, 1.0);
                atten *= t * t * (3.0 - 2.0 * t);
            }

            // Phase: how much light scatters toward the camera
            float cosTheta = dot(nPlayerPos, normalize(toLight));
            float phase    = sl_hg_phase(cosTheta, g);

            vec3 contrib = slColor[li] * atten * phase;
            if (lTrace > lViewPos) contrib *= translucentMult;
            lightFog += contrib;
        }

        tracePos += traceAdd;
    }

    lightFog *= 1.0 - maxBlindnessDarkness;
    return pow(max(lightFog / float(sampleCount), vec3(0.0)), vec3(0.25));
}
