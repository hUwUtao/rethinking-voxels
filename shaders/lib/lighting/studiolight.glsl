// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║ StudioLight Support for Rethinking Voxels / Complementary Reimagined       ║
// ║ Chunk-atlas ABI decoder for dynamic studio lighting                         ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

uniform sampler2D sl_chunkmeta;
uniform sampler2D sl_lightdata_0;
uniform sampler2D sl_lightdata_1;
uniform sampler2D sl_lightdata_2;
uniform sampler2D sl_lightdata_3;
uniform sampler2D sl_lightdata_4;

const int SL_CELL_SIZE = 16;
const int SL_MAX_LIGHTS_PER_CHUNK = 256;
const float SL_BLOCK_SCALAR_STEP = 4.0;
const float SL_HALF_PI = 1.57079632679;

ivec4 sl_texel255(sampler2D tex, ivec2 coord) {
    return ivec4(round(texelFetch(tex, coord, 0) * 255.0));
}

float sl_decodeBlockScalar(int rawByte) {
    return float(rawByte) / SL_BLOCK_SCALAR_STEP;
}

int sl_chunk_count(ivec2 cell) {
    ivec4 meta = sl_texel255(sl_chunkmeta, cell);
    return meta.r + (meta.g << 8);
}

int sl_count() {
    ivec2 metaSize = textureSize(sl_chunkmeta, 0);
    int total = 0;
    for (int z = 0; z < metaSize.y; z++) {
        for (int x = 0; x < metaSize.x; x++) {
            total += sl_chunk_count(ivec2(x, z));
        }
    }
    return total;
}

int sl_abiVersion() {
    ivec2 metaSize = textureSize(sl_chunkmeta, 0);
    int abi = 0;
    for (int z = 0; z < metaSize.y; z++) {
        for (int x = 0; x < metaSize.x; x++) {
            abi = max(abi, sl_texel255(sl_chunkmeta, ivec2(x, z)).a);
        }
    }
    return abi;
}

vec3 sl_decodeDirection(ivec4 raw4) {
    vec3 dir = vec3(raw4.g, raw4.b, raw4.a) / 255.0 * 2.0 - 1.0;
    float dirLen = length(dir);
    if (dirLen < 0.001) return vec3(0.0, -1.0, 0.0);
    return dir / dirLen;
}

float sl_windowed_atten(float dist, float radius) {
    float ratio  = dist / radius;
    float ratio2 = ratio * ratio;
    float ratio4 = ratio2 * ratio2;
    float window = max(1.0 - ratio4, 0.0);
    return (window * window) / (dist * dist + 1.0);
}

float sl_spot_cone(float cosTheta,
                   float coneAngle, float innerAngle,
                   float sourceRadius, float dist,
                   float sharpness, float shape,
                   vec3 toFrag, vec3 lightDir) {
    if (shape < 0.5) {
        float penumbra  = atan(sourceRadius / max(dist, 0.001));
        float softOuter = cos(coneAngle + penumbra);
        float softInner = cos(coneAngle - penumbra);
        float t = clamp((cosTheta - softOuter) / (softInner - softOuter), 0.0, 1.0);
        float soft = t * t * (3.0 - 2.0 * t);
        float hard = step(cos(coneAngle), cosTheta);
        float cone = mix(soft, hard, sharpness);

        float tInner = clamp((cosTheta - cos(coneAngle)) /
                             (cos(innerAngle) - cos(coneAngle)), 0.0, 1.0);
        float hotspot = tInner * tInner * (3.0 - 2.0 * tInner);
        return mix(cone, 1.0, hotspot * 0.5);
    } else {
        vec3 right = normalize(cross(lightDir, abs(lightDir.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
        vec3 up = cross(right, lightDir);

        float projDist = max(dot(-toFrag, -lightDir), 0.001);
        float u = dot(toFrag, right) / (projDist * tan(coneAngle));
        float v = dot(toFrag, up) / (projDist * tan(coneAngle));

        float penumbra = sourceRadius / max(dist, 0.001);
        float box = 1.0 - smoothstep(1.0 - penumbra, 1.0 + penumbra, max(abs(u), abs(v)));
        float hardBox = step(max(abs(u), abs(v)), 1.0);
        return mix(box, hardBox, sharpness);
    }
}

float sl_area_atten(vec3 fragPos, vec4 geo0, vec4 geo1,
                    vec3 lightPos, vec3 lightDir, vec3 fragNormal) {
    float w = geo0.x;
    float h = geo0.y;

    vec3 toLight = lightPos - fragPos;
    float dist = length(toLight);
    if (dist < 0.001) return 0.0;

    float radius = sqrt(w * w + h * h) * 0.5;
    float att = sl_windowed_atten(dist, radius * 3.0);

    vec3 right = normalize(cross(lightDir, abs(lightDir.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
    vec3 lightUp = cross(right, lightDir);

    vec3 normToFrag = normalize(toLight);
    float pu = dot(normToFrag, right);
    float pv = dot(normToFrag, lightUp);

    float barnTop = step(-cos(geo1.x), pv);
    float barnBottom = step(-cos(geo1.y), -pv);
    float barnLeft = step(-cos(geo1.z), pu);
    float barnRight = step(-cos(geo1.w), -pu);
    float barnClip = barnTop * barnBottom * barnLeft * barnRight;

    float ndl = max(dot(fragNormal, normalize(toLight)), 0.0);
    return att * ndl * barnClip;
}

// StudioLight light evaluation is now handled by the Rethinking Voxels voxel pipeline.
// Sources are injected into occupancyVolume and globalLightHashMap by shadowcomp3.glsl,
// then processed through shadowcomp1.glsl (volumetric) and prepare4_csh.glsl (per-pixel)
// with proper cone-traced visibility, temporal accumulation, and denoising.
