// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║ StudioLight Voxel Injection Pass                                            ║
// ║ Integrates StudioLight sources into the voxel occupancy/light hash map       ║
// ║ Runs after shadowcomp.glsl (SDF build) and before prepare4_csh (per-pixel)  ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

#include "/lib/common.glsl"

// ── Inject pass: Write current-frame StudioLight lights into occupancy and hash map ──
#ifdef CSH_A

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

    // Decode color
    vec3 lightColor = vec3(raw1.b, raw1.a, raw2.r) / 255.0;

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
    int newOccupancy = (1 << 16) | (lightLevel << 17) | (1 << 30); // emissive | lightLevel | SL_flag
    imageAtomicOr(occupancyVolume, voxelCoord, newOccupancy);

    // Write to global light hash map
    uint hash = posToHash(voxelCoord - voxelVolumeSize / 2) % uint(1 << 18);
    atomicExchange(globalLightHashMap[4 * hash + 0], packedPos0);
    atomicExchange(globalLightHashMap[4 * hash + 1], packedPos1);
    atomicExchange(globalLightHashMap[4 * hash + 2], packedCol0);
    atomicExchange(globalLightHashMap[4 * hash + 3], packedCol1);
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
