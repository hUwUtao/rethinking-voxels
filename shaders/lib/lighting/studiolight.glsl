// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║ StudioLight Support for Rethinking Voxels / Complementary Reimagined         ║
// ║ Integration with Iris Shaders DynamicTexture for dynamic studio lighting      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

// ── StudioLight DynamicTexture (written by mod each frame) ─────────────────────
// Texture: RGBA8, 20×257 pixels
// Row 0: header (count at pixel 0, abiVersion at pixel 1)
// Rows 1–256: one light per row, 20 pixels = 5 vec4s
// Each float is packed: Integer.reverseBytes(floatToRawIntBits) → ABGR in RGBA texture

uniform sampler2D sl_lightdata;

uint sl_byte(float c) {
    return uint(clamp(c, 0.0, 1.0) * 255.0 + 0.5);
}

float sl_decodeFloat(int col, int row) {
    vec4 p = texelFetch(sl_lightdata, ivec2(col, row), 0);

    // Texture channels are exact 8-bit normalized bytes.
    // Rebuild original float bits from R,G,B,A = MSB..LSB.
    uint bits =
          (sl_byte(p.r) << 24u)
        | (sl_byte(p.g) << 16u)
        | (sl_byte(p.b) <<  8u)
        |  sl_byte(p.a);

    return uintBitsToFloat(bits);
}

vec4 sl_fetchVec4(int lightRow, int vec4Col) {
    int base = vec4Col * 4;
    return vec4(
        sl_decodeFloat(base + 0, lightRow),
        sl_decodeFloat(base + 1, lightRow),
        sl_decodeFloat(base + 2, lightRow),
        sl_decodeFloat(base + 3, lightRow)
    );
}

int sl_count()      { return int(sl_decodeFloat(0, 0)); }
int sl_abiVersion() { return int(sl_decodeFloat(1, 0)); }

// ── Windowed inverse-square attenuation ─────────────────────────────────────────
// Reaches exactly 0 at dist = radius. Avoids the hard pop of a linear cutoff.
// Based on Unreal Engine 4's attenuation formula.
float sl_windowed_atten(float dist, float radius) {
    float ratio  = dist / radius;
    float ratio2 = ratio * ratio;
    float ratio4 = ratio2 * ratio2;
    float window = max(1.0 - ratio4, 0.0);
    return (window * window) / (dist * dist + 1.0);
}

// ── Spot cone mask with physical slit penumbra ──────────────────────────────────
// cosTheta:    dot(normalize(fragPos - lightPos), lightDir)
//              NOTE: positive = facing light, matching conventions below
// coneAngle:   half-angle of the outer cone (radians)
// innerAngle:  half-angle of the hotspot (radians)
// sourceRadius: physical aperture radius (blocks)
// dist:        distance from light to fragment
// sharpness:   0 = physical slit blur, 1 = laser hard edge
// shape:       0.0 = circle test, 1.0 = pyramid/box test
float sl_spot_cone(float cosTheta,
                   float coneAngle, float innerAngle,
                   float sourceRadius, float dist,
                   float sharpness, float shape,
                   vec3  toFrag, vec3 lightDir) {

    if (shape < 0.5) {
        // ── Circle cone ────────────────────────────────────────────────────
        float penumbra  = atan(sourceRadius / max(dist, 0.001));
        float softOuter = cos(coneAngle + penumbra);
        float softInner = cos(coneAngle - penumbra);
        float t    = clamp((cosTheta - softOuter) / (softInner - softOuter), 0.0, 1.0);
        float soft = t * t * (3.0 - 2.0 * t);
        float hard = step(cos(coneAngle), cosTheta);
        float cone = mix(soft, hard, sharpness);

        // Inner hotspot: boost within innerAngle
        float tInner  = clamp((cosTheta - cos(coneAngle)) /
                               (cos(innerAngle) - cos(coneAngle)), 0.0, 1.0);
        float hotspot = tInner * tInner * (3.0 - 2.0 * tInner);

        return mix(cone, 1.0, hotspot * 0.5);

    } else {
        // ── Pyramid / box cone ──────────────────────────────────────────────
        vec3 right = normalize(cross(lightDir,
                                     abs(lightDir.y) < 0.99 ? vec3(0,1,0) : vec3(1,0,0)));
        vec3 up    = cross(right, lightDir);

        float projDist = max(dot(-toFrag, -lightDir), 0.001);
        float u = dot(toFrag, right) / (projDist * tan(coneAngle));
        float v = dot(toFrag, up)    / (projDist * tan(coneAngle));

        float penumbra = sourceRadius / max(dist, 0.001);
        float box = 1.0 - smoothstep(1.0 - penumbra, 1.0 + penumbra,
                                     max(abs(u), abs(v)));
        float hardBox = step(max(abs(u), abs(v)), 1.0);

        return mix(box, hardBox, sharpness);
    }
}

// ── Area light (Drobot sphere proxy) ────────────────────────────────────────────
float sl_area_atten(vec3 fragPos, vec4 geo0, vec4 geo1,
                    vec3 lightPos, vec3 lightDir, vec3 fragNormal) {
    float w      = geo0.x;
    float h      = geo0.y;
    float srcR   = geo0.z;

    vec3 toLight = lightPos - fragPos;
    float dist   = length(toLight);
    if (dist < 0.001) return 0.0;

    float radius = sqrt(w * w + h * h) * 0.5;
    float att    = sl_windowed_atten(dist, radius * 3.0);

    // Barn-door clipping: each flap is a half-plane in the light's local frame.
    vec3 right = normalize(cross(lightDir,
                                 abs(lightDir.y) < 0.99 ? vec3(0,1,0) : vec3(1,0,0)));
    vec3 lightUp = cross(right, lightDir);

    vec3 normToFrag = normalize(toLight);
    float pu = dot(normToFrag, right);
    float pv = dot(normToFrag, lightUp);

    float barnTop    = step(-cos(geo1.x), pv);
    float barnBottom = step(-cos(geo1.y), -pv);
    float barnLeft   = step(-cos(geo1.z), pu);
    float barnRight  = step(-cos(geo1.w), -pu);
    float barnClip   = barnTop * barnBottom * barnLeft * barnRight;

    float ndl = max(dot(fragNormal, normalize(toLight)), 0.0);
    return att * ndl * barnClip;
}

// ── Main evaluation loop ────────────────────────────────────────────────────────
vec3 sl_evaluate(vec3 fragWorldPos, vec3 albedo, vec3 fragNormal) {
    vec3 result = vec3(0.0);

    int count = sl_count();
    int abiVersion = sl_abiVersion();
    if (abiVersion != 1) return vec3(0.0);   // reject unknown ABI version

    for (int i = 0; i < min(count, 256); i++) {
        int row = i + 1;

        vec4 positionAndType        = sl_fetchVec4(row, 0);
        vec4 colorAndIntensity      = sl_fetchVec4(row, 1);
        vec4 geometry0              = sl_fetchVec4(row, 2);
        vec4 geometry1              = sl_fetchVec4(row, 3);
        vec4 direction              = sl_fetchVec4(row, 4);

        vec3  lpos  = positionAndType.xyz;
        float ltype = positionAndType.w;
        vec3  lcol  = colorAndIntensity.rgb * colorAndIntensity.a;

        vec3  toFrag = fragWorldPos - lpos;
        float dist   = length(toFrag);
        float contrib = 0.0;

        if (ltype < 0.5) {
            // ── Point ──────────────────────────────────────────────────────
            float radius = geometry0.x;
            if (dist >= radius) continue;
            float att  = sl_windowed_atten(dist, radius);
            float ndl  = max(dot(fragNormal, normalize(-toFrag)), 0.0);
            contrib    = att * ndl;

        } else if (ltype < 1.5) {
            // ── Spot ───────────────────────────────────────────────────────
            float coneAngle  = geometry0.x;
            float innerAngle = geometry0.y;
            float range      = geometry0.z;
            float srcRadius  = geometry0.w;
            float sharpness  = geometry1.x;
            float shape      = geometry1.y;
            vec3  ldir       = direction.xyz;

            if (dist >= range) continue;

            float cosTheta = dot(normalize(-toFrag), ldir);
            if (cosTheta <= 0.0) continue;

            float att  = sl_windowed_atten(dist, range);
            float cone = sl_spot_cone(cosTheta, coneAngle, innerAngle,
                                      srcRadius, dist, sharpness, shape,
                                      toFrag, ldir);
            float ndl  = max(dot(fragNormal, normalize(-toFrag)), 0.0);
            contrib    = att * cone * ndl;

        } else if (ltype < 2.5) {
            // ── Area ───────────────────────────────────────────────────────
            float w = geometry0.x;
            float h = geometry0.y;
            float radius = sqrt(w * w + h * h) * 3.0;
            if (dist >= radius) continue;

            contrib = sl_area_atten(fragWorldPos, geometry0, geometry1,
                                    lpos, direction.xyz, fragNormal);
        }

        if (contrib > 0.0) {
            result += albedo * lcol * contrib;
        }
    }

    return result;
}
