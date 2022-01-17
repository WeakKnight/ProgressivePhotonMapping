#pragma once
#include "Utils/HostDeviceShared.slangh"
#include "Utils/Math/MathConstants.slangh"

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
        wi = 0.0f; // view direction
        radius = 0.001f;
        flux = 0.0f;
        n = 0u;
        weight = 1.0f;
        valid = 0u;
    }

    __init(ByteAddressBuffer dataBuffer， uint pointer)
    {
        uint itemStride = 16u * 4u;
        hitInfo = dataBuffer.Load4(pointer + 0u);
        wi = dataBuffer.Load3(pointer + 16u);
    }
#endif

    bool isValid()
    {
        return (valid == 1u);
    }

    uint4 hitInfo;
    float3 wi;
    float radius;
    float3 flux;
    uint n;
    float3 weight;
    uint valid;
};

struct PhotonMappingParams
{
    uint2 frameDim = { 0, 0 };
    uint frameCount = 0;
    uint seed = 0;
    uint photonCount = 100000u;
};

struct PackedBoundingBox
{
#ifndef HOST_CODE
    __init()
    {
        minPoint = FLT_MAX;
        maxPoint = -FLT_MAX;
        pad0 = 0.0f;
        pad1 = 0.0f;
    }

    __init(float3 position, float radius)
    {
        minPoint = position - float3(radius);
        maxPoint = position + float3(radius);
        pad0 = 0.0f;
        pad1 = 0.0f;
    }
#endif

    float3 minPoint;
    float3 maxPoint;
    float pad0;
    float pad1;
};

END_NAMESPACE_FALCOR
