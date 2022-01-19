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
        rayDir = 0.0f; // view direction
        radius = 0.005f;
        flux = 0.0f;
        n = 0u;
        weight = 1.0f;
        valid = 0u;
        rayOrigin = 0.0f;
        pad0 = 0u;
    }

    __init(RWByteAddressBuffer dataBuffer, uint pointer)
    {
        const uint typeSize = 5 * 16;
        const uint base = typeSize * pointer;
        hitInfo = dataBuffer.Load4(base); // 16 * 0
        rayDir = asfloat(dataBuffer.Load3(base + 16)); // 16 * 1
        radius = asfloat(dataBuffer.Load(base + 28)); // 16 * 1 + 12
        flux = asfloat(dataBuffer.Load3(base + 32)); // 16 * 2
        n = dataBuffer.Load(base + 44); // 16 * 2 + 12
        weight = asfloat(dataBuffer.Load3(base + 48)); // 16 * 3
        valid = dataBuffer.Load(base + 60); // 16 * 3 + 12
        rayOrigin = asfloat(dataBuffer.Load3(base + 64)); // 16 * 4
        pad0 = 0u;
    }
#endif

    bool isValid()
    {
        return (valid == 1u);
    }

    uint4 hitInfo;
    float3 rayDir;
    float radius;
    float3 flux;
    uint n;
    float3 weight;
    uint valid;
    float3 rayOrigin;
    uint pad0;
};

struct VisiblePointDensityContext
{
#ifndef HOST_CODE
    __init()
    {
        radius = 0.005f;
        flux = 0.0f;
        n = 0u;
        pad0 = 0u;
        pad1 = 1u;
        pad2 = 2u;
    }
#endif

    float3 flux;
    float radius;
    uint n;
    uint pad0;
    uint pad1;
    uint pad2;
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
