import Params;
#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.SampleGenerator;
import Utils.Geometry.GeometryHelpers;
import Scene.Scene;
import Scene.RaytracingInline;
import ShadingDataLoader;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;

struct GenerateVisiblePointsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    
    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }
    }
};

cbuffer CB
{
    GenerateVisiblePointsPass gGenerateVisiblePointsPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gGenerateVisiblePointsPass.execute(dispatchThreadId.xy);
}
