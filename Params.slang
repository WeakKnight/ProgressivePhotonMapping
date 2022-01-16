#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

#ifndef HOST_CODE
__exported import Utils.Math.BitTricks;
__exported import Scene.HitInfo;
#endif

struct VisiblePoint
{
#ifndef HOST_CODE
    __init()
    {
        hitInfo = 0u;
        wi = 0.0f;
        radius = 0.0f;
        flux = 0.0f;
        n = 0u;
    }
#endif

    uint4 hitInfo;
    float3 wi;
    float radius;
    float3 flux;
    uint n;
};

struct PhotonMappingParams
{
    uint2 frameDim = { 0, 0 };
    uint frameCount = 0;
    uint seed = 0;
};

uint visiblePointPositionToPointer(uint2 pixel, PhotonMappingParams params)
{
    return pixel.x + pixel.y * params.frameDim.x;
}

END_NAMESPACE_FALCOR
