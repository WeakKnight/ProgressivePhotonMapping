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

struct GeneratePhotonsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    
    void execute(const uint photonIndex)
    {
    }
};

cbuffer CB
{
    GeneratePhotonsPass gGeneratePhotonsPass;
}

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gGeneratePhotonsPass.execute(dispatchThreadId.x);
}
