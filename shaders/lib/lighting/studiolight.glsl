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

float sl_voxelVisibility(vec3 fragWorldPos, vec3 fragNormal, vec3 vxPos, vec3 lightWorldPos) {
    return 1.0;
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

vec3 sl_evaluate(vec3 fragWorldPos, vec3 albedo, vec3 fragNormal, vec3 vxPos) {
    if (sl_abiVersion() != 4) return vec3(0.0);

    vec3 result = vec3(0.0);
    ivec2 metaSize = textureSize(sl_chunkmeta, 0);
    ivec2 centerCell = metaSize / 2;
    ivec2 cameraChunk = ivec2(floor(cameraPosition.xz / 16.0));

    for (int cz = 0; cz < metaSize.y; cz++) {
        for (int cx = 0; cx < metaSize.x; cx++) {
            ivec2 cell = ivec2(cx, cz);
            int count = sl_chunk_count(cell);
            if (count <= 0) continue;

            ivec2 lightChunk = cameraChunk + ivec2(cx - centerCell.x, cz - centerCell.y);
            ivec2 atlasBase = cell * SL_CELL_SIZE;

            for (int slot = 0; slot < SL_MAX_LIGHTS_PER_CHUNK; slot++) {
                if (slot >= count) break;

                ivec2 atlasCoord = atlasBase + ivec2(slot & 15, slot >> 4);
                ivec4 raw0 = sl_texel255(sl_lightdata_0, atlasCoord);
                ivec4 raw1 = sl_texel255(sl_lightdata_1, atlasCoord);
                ivec4 raw2 = sl_texel255(sl_lightdata_2, atlasCoord);
                ivec4 raw3 = sl_texel255(sl_lightdata_3, atlasCoord);
                ivec4 raw4 = sl_texel255(sl_lightdata_4, atlasCoord);

                int encY = raw0.g + (raw1.r << 8) + (raw1.g << 16);
                vec3 lpos = vec3(
                    float(lightChunk.x) * 16.0 + float(raw0.r) / 16.0,
                    -64.0 + float(encY) / 1024.0,
                    float(lightChunk.y) * 16.0 + float(raw0.b) / 16.0
                );
                int ltype = raw0.a;
                vec3 lcol = vec3(raw1.b, raw1.a, raw2.r) / 255.0;
                float lintensity = float(raw4.r) / 255.0;

                vec3 toFrag = fragWorldPos - lpos;
                float dist = length(toFrag);
                float contrib = 0.0;

                if (ltype == 0) {
                    float radius = sl_decodeBlockScalar(raw2.g);
                    if (radius <= 0.001 || dist >= radius) continue;
                    float att = sl_windowed_atten(dist, radius);
                    float ndl = max(dot(fragNormal, normalize(-toFrag)), 0.0);
                    contrib = att * ndl;
                } else if (ltype == 1) {
                    float coneAngle = float(raw2.g) / 255.0 * SL_HALF_PI;
                    float innerAngle = float(raw2.b) / 255.0 * SL_HALF_PI;
                    float range = sl_decodeBlockScalar(raw2.a);
                    float sourceRadius = float(raw3.r) / 255.0;
                    float sharpness = float(raw3.g) / 255.0;
                    float shape = float(raw3.b);
                    vec3 ldir = sl_decodeDirection(raw4);

                    if (range <= 0.001 || dist >= range) continue;

                    float cosTheta = dot(normalize(-toFrag), ldir);
                    if (cosTheta <= 0.0) continue;

                    float att = sl_windowed_atten(dist, range);
                    float cone = sl_spot_cone(cosTheta, coneAngle, innerAngle, sourceRadius, dist, sharpness, shape, toFrag, ldir);
                    float ndl = max(dot(fragNormal, normalize(-toFrag)), 0.0);
                    contrib = att * cone * ndl;
                } else if (ltype == 2) {
                    float w = sl_decodeBlockScalar(raw2.g);
                    float h = sl_decodeBlockScalar(raw2.b);
                    vec4 geo0 = vec4(w, h, float(raw2.a) / 255.0, 0.0);
                    vec4 geo1 = vec4(raw3.r, raw3.g, raw3.b, raw3.a) / 255.0 * SL_HALF_PI;
                    float radius = sqrt(w * w + h * h) * 3.0;
                    if (radius <= 0.001 || dist >= radius) continue;

                    contrib = sl_area_atten(fragWorldPos, geo0, geo1, lpos, sl_decodeDirection(raw4), fragNormal);
                }

                if (contrib > 0.0) {
                    float voxelVisibility = sl_voxelVisibility(fragWorldPos, fragNormal, vxPos, lpos);
                    if (voxelVisibility <= 0.0) continue;
                    result += albedo * lcol * (contrib * lintensity * voxelVisibility);
                }
            }
        }
    }

    return result;
}
