#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

#ifndef HOST_CODE
__exported import Utils.Math.BitTricks;
#endif

struct PhotonMappingParams
{
    uint2 frameDim = { 0, 0 };
    uint frameCount = 0;
    uint seed = 0;
};

END_NAMESPACE_FALCOR
