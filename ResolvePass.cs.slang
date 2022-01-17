import Helper;

struct ResolvePass
{
    PhotonMappingParams params;
    RWTexture2D<float4> outputColor;

    ShadingDataLoader shadingDataLoader;
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;

    StructuredBuffer<VisiblePoint> visiblePoints;
    RaytracingAccelerationStructure visiblePointsAS;

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        float3 color = outputColor[pixel].xyz;

        SampleGenerator sg = SampleGenerator(pixel, params.seed);
        
        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ShadingData sd = shadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);
            color += bsdf.getProperties(sd).emissive;
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        VisiblePoint visiblePoint = visiblePoints[visiblePointPointer];

        outputColor[pixel] = float4(color, 1.0f);
    }
};

cbuffer CB
{
    ResolvePass gResolvePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gResolvePass.execute(dispatchThreadId.xy);
}
