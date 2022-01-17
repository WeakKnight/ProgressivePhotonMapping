import Helper;

struct GeneratePhotonsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;

    RWStructuredBuffer<VisiblePoint> visiblePoints;
    RWStructuredBuffer<PackedBoundingBox> visiblePointsBoundingBoxBuffer;
    RaytracingAccelerationStructure visiblePointsAS;

    void execute(const uint photonIndex)
    {
        if (any(photonIndex >= params.photonCount))
        {
            return;
        }

        // Light Tracing
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
