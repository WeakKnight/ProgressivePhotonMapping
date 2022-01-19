import Helper;

struct GenerateVisiblePointsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;
    RWStructuredBuffer<VisiblePoint> visiblePoints;
    RWStructuredBuffer<PackedBoundingBox> visiblePointsBoundingBoxBuffer;
    RWTexture2D<float4> outputColor;
    
    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        SampleGenerator sg = SampleGenerator(pixel, params.seed);

        VisiblePoint visiblePoint = VisiblePoint();
        PackedBoundingBox visiblePointBoundingBox = PackedBoundingBox();
        float3 color = 0.0f;

        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);
            
            visiblePoint.hitInfo = shadingDataLoader.loadHitInfo(pixel).getData();
            Ray cameraRay = shadingDataLoader.getPrimaryRay(pixel, params.frameDim, gScene.camera);
            visiblePoint.rayOrigin = cameraRay.origin;
            visiblePoint.rayDir = cameraRay.dir;

            for (uint i = 0; i < 5; i++)
            {
                // Update Current Shading Data And BSDF
                ShadingData sd = visiblePoint.constructShadingData(shadingDataLoader, i == 0);
                IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

                BSDFSample bsdfSample;
                if (!bsdf.sample(sd, sg, bsdfSample))
                {
                    break;
                }

                if (bsdfSample.isLobe(LobeType::Diffuse))
                {
                    visiblePoint.valid = 1u;
                    visiblePointBoundingBox = PackedBoundingBox(sd.posW, visiblePoint.radius);
                    break;
                }

                color += (visiblePoint.weight * evalEmissiveLighting(sd, sg, emissiveSampler));

                visiblePoint.weight *= bsdfSample.weight;
                visiblePoint.rayOrigin = sd.computeNewRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
                visiblePoint.rayDir = bsdfSample.wo;

                // Continue Tracing
                HitInfo hit;
                float hitT;
                if (!traceScatterRay(visiblePoint.rayOrigin, visiblePoint.rayDir, hit, hitT))
                {
                    break;
                }
                visiblePoint.hitInfo = hit.getData();
            }
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        visiblePoints[visiblePointPointer] = visiblePoint;
        visiblePointsBoundingBoxBuffer[visiblePointPointer] = visiblePointBoundingBox;
        outputColor[pixel] = float4(color, 1.0f);
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
