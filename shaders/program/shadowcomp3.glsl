// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║ StudioLight Voxel Injection Pass                                            ║
// ║ Integrates StudioLight sources into the voxel occupancy/light hash map       ║
// ║ Runs after shadowcomp.glsl (SDF build) and before prepare4_csh (per-pixel)  ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

#include "/lib/common.glsl"

// ── Inject pass: Write current-frame StudioLight lights into occupancy and hash map ──
#ifdef CSH_A

// Dispatch size: covers up to 256x256 atlas with 16x16 slots per chunk
// = 256*256*256 max lights / 64 threads per group = up to 256K work groups
const ivec3 workGroups = ivec3(256, 64, 1);  // 16K total groups, safely covers most atlases

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32i) uniform restrict iimage3D occupancyVolume;

#include "/lib/lighting/studiolight.glsl"
#include "/lib/vx/positionHashing.glsl"
#define WRITE_TO_SSBOS
#include "/lib/vx/SSBOs.glsl"

void main() {
    // Dispatch over all possible light slots in the atlas
    // Total slots = metaSize.x * metaSize.y * 16 * 16
    // With 8x8 local group, we dispatch enough groups to cover all slots
    uint globalSlot = gl_GlobalInvocationID.x + gl_GlobalInvocationID.y * 256u;

    // StudioLight atlas is chunk-spatial: metaSize × metaSize chunks, 16×16 slots per chunk
    ivec2 metaSize = textureSize(sl_chunkmeta, 0);
    uint maxSlots = uint(metaSize.x * metaSize.y * 16 * 16);

    if (globalSlot >= maxSlots) {
        return;
    }

    // Decode which chunk and slot this thread handles
    uint chunksPerRow = uint(metaSize.x);
    uint chunkIdx = globalSlot / (16u * 16u);
    uint slotInChunk = globalSlot % (16u * 16u);

    uint chunkZ = chunkIdx / chunksPerRow;
    uint chunkX = chunkIdx % chunksPerRow;

    uint slotX = slotInChunk % 16u;
    uint slotY = slotInChunk / 16u;

    // Read chunk count
    ivec2 cellCoord = ivec2(chunkX, chunkZ);
    int lightCount = sl_chunk_count(cellCoord);

    if (int(slotInChunk) >= lightCount) {
        return; // This slot is empty
    }

    // Decode the light from the atlas
    ivec2 atlasCoord = cellCoord * 16 + ivec2(slotX, slotY);
    ivec4 raw0 = sl_texel255(sl_lightdata_0, atlasCoord);
    ivec4 raw1 = sl_texel255(sl_lightdata_1, atlasCoord);
    ivec4 raw2 = sl_texel255(sl_lightdata_2, atlasCoord);
    ivec4 raw3 = sl_texel255(sl_lightdata_3, atlasCoord);
    ivec4 raw4 = sl_texel255(sl_lightdata_4, atlasCoord);

    // Decode world position
    int encY = raw0.g + (raw1.r << 8) + (raw1.g << 16);
    ivec2 cameraChunk = ivec2(floor(cameraPosition.xz / 16.0));
    ivec2 lightChunk = cameraChunk + ivec2(int(chunkX) - metaSize.x / 2, int(chunkZ) - metaSize.y / 2);

    vec3 worldPos = vec3(
        float(lightChunk.x) * 16.0 + float(raw0.r) / 16.0,
        -64.0 + float(encY) / 1024.0,
        float(lightChunk.y) * 16.0 + float(raw0.b) / 16.0
    );

    // Decode color and intensity
    float slIntensity = float(raw4.r) / 255.0;
    vec3 lightColor = vec3(raw1.b, raw1.a, raw2.r) / 255.0 * slIntensity;

    // Compute voxel coordinate (matching DoLighting's voxel space transform)
    vec3 voxelPosFloat = worldPos - cameraPosition + cameraPositionFract + 0.5 * vec3(voxelVolumeSize);
    ivec3 voxelCoord = ivec3(voxelPosFloat);

    // Check if within voxel volume bounds
    if (any(lessThan(voxelCoord, ivec3(0))) || any(greaterThanEqual(voxelCoord, voxelVolumeSize))) {
        return; // Light is outside voxel range
    }

    // Compute light level from intensity + light type
    int lightType = raw0.a;
    float effectiveRange = 1.0;

    if (lightType == 0) { // Point light
        effectiveRange = sl_decodeBlockScalar(raw2.g);
    } else if (lightType == 1) { // Spot light
        effectiveRange = sl_decodeBlockScalar(raw2.a);
    } else if (lightType == 2) { // Area light
        float w = sl_decodeBlockScalar(raw2.g);
        float h = sl_decodeBlockScalar(raw2.b);
        effectiveRange = sqrt(w * w + h * h) * 0.75;
    }

    int lightLevel = clamp(int(effectiveRange * 2.0), 1, 31);

    // Pack into hash map format (count = 1 for single dynamic light)
    uint subPosX_32 = 16u; // sub-voxel position (1 block center = 16/32)
    uint subPosY_32 = 16u;
    uint subPosZ_32 = 16u;

    uint packedPos0 = subPosX_32 | (subPosY_32 << 16);
    uint packedPos1 = subPosZ_32 | (1u << 16); // count = 1
    uint packedCol0 = uint(lightColor.r * 32.0 + 0.5) | (uint(lightColor.g * 32.0 + 0.5) << 16);
    uint packedCol1 = uint(lightColor.b * 32.0 + 0.5) | 0xffff0000u; // aggregated sentinel

    // Write to occupancy volume
    // bits 16: emissive flag
    // bits 17-21: light level (0-31 range)
    // bits 22-23: light type (0=point, 1=spot, 2=area)
    // bit 30: SL flag
    int lightTypeBits = (lightType & 0x3) << 22;
    int newOccupancy = (1 << 16) | (lightLevel << 17) | lightTypeBits | (1 << 30);

    // Compute injection geometry — inject a shape-matched cluster so random-ray
    // discovery (voxelTrace hitMask 1|1<<16) can reliably find SL lights
    vec3 lightDir = sl_decodeDirection(raw4);
    vec3 right = normalize(cross(lightDir, abs(lightDir.y) < 0.99 ? vec3(0,1,0) : vec3(1,0,0)));
    vec3 up = cross(right, lightDir);

    int injectRadius;
    float planeHalfW = 0.0, planeHalfH = 0.0;
    if (lightType == 1) { // Spot — disk perpendicular to direction
        float srcRadius = float(raw3.r) / 255.0;
        injectRadius = max(int(srcRadius * 16.0 + 0.5), 1);
    } else if (lightType == 2) { // Area — plane of width × height
        planeHalfW = sl_decodeBlockScalar(raw2.g) * 0.5;
        planeHalfH = sl_decodeBlockScalar(raw2.b) * 0.5;
        injectRadius = max(int(max(planeHalfW, planeHalfH) + 0.5), 1);
    } else { // Point — small sphere bias
        injectRadius = 1;
    }

    // Iterate bounding cube, filter by shape, write each voxel
    for (int dz = -injectRadius; dz <= injectRadius; dz++) {
        for (int dy = -injectRadius; dy <= injectRadius; dy++) {
            for (int dx = -injectRadius; dx <= injectRadius; dx++) {
                vec3 fOff = vec3(dx, dy, dz);

                if (lightType == 0) {
                    // Point: sphere
                    if (length(fOff) > float(injectRadius) + 0.5) continue;
                } else if (lightType == 1) {
                    // Spot: thin disk perpendicular to lightDir
                    float along = abs(dot(fOff, lightDir));
                    float perp  = length(fOff - dot(fOff, lightDir) * lightDir);
                    if (along > 0.7 || perp > float(injectRadius) + 0.5) continue;
                } else {
                    // Area: thin plane slab (width × height)
                    float along = abs(dot(fOff, lightDir));
                    float pu    = abs(dot(fOff, right));
                    float pv    = abs(dot(fOff, up));
                    if (along > 0.7 || pu > planeHalfW + 0.5 || pv > planeHalfH + 0.5) continue;
                }

                ivec3 writeCoord = voxelCoord + ivec3(dx, dy, dz);
                if (any(lessThan(writeCoord, ivec3(0))) || any(greaterThanEqual(writeCoord, voxelVolumeSize)))
                    continue;

                imageAtomicOr(occupancyVolume, writeCoord, newOccupancy);

                uint hash = posToHash(writeCoord - voxelVolumeSize / 2) % uint(1 << 18);
                atomicExchange(globalLightHashMap[4 * hash + 0], packedPos0);
                atomicExchange(globalLightHashMap[4 * hash + 1], packedPos1);
                atomicExchange(globalLightHashMap[4 * hash + 2], packedCol0);
                atomicExchange(globalLightHashMap[4 * hash + 3], packedCol1);
            }
        }
    }
}
#endif

// ── Clear pass: Remove stale StudioLight entries from previous frame ──
#ifdef CSH
#if VX_VOL_SIZE == 0
    const ivec3 workGroups = ivec3(12, 8, 12);
#elif VX_VOL_SIZE == 1
    const ivec3 workGroups = ivec3(16, 12, 16);
#elif VX_VOL_SIZE == 2
    const ivec3 workGroups = ivec3(32, 16, 32);
#elif VX_VOL_SIZE == 3
    const ivec3 workGroups = ivec3(64, 16, 64);
#endif

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(r32i) uniform restrict iimage3D occupancyVolume;

#include "/lib/vx/positionHashing.glsl"
#define WRITE_TO_SSBOS
#include "/lib/vx/SSBOs.glsl"

void main() {
    // Dispatch over entire voxelVolumeSize, one thread per voxel
    ivec3 voxelCoord = ivec3(gl_WorkGroupID) * 8 + ivec3(gl_LocalInvocationID);

    // Only process voxels within bounds
    if (any(greaterThanEqual(voxelCoord, voxelVolumeSize))) {
        return;
    }

    // Read current occupancy
    int occupancy = imageLoad(occupancyVolume, voxelCoord).r;

    // If this voxel was marked as a StudioLight source (bit 30), clear it
    if ((occupancy & (1 << 30)) != 0) {
        // Clear bits 16-21 (emissive bit + light level) and bit 30
        int clearedOccupancy = occupancy & ~((0x3F << 16) | (1 << 30));
        imageStore(occupancyVolume, voxelCoord, ivec4(clearedOccupancy));

        // Also clear the corresponding globalLightHashMap entry
        uint hash = posToHash(voxelCoord - voxelVolumeSize / 2) % uint(1 << 18);
        for (int i = 0; i < 4; i++) {
            atomicExchange(globalLightHashMap[4 * hash + i], uint(0));
        }
    }
}
#endif
