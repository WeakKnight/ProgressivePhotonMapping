#include "Utils/Math/MathConstants.slangh"
// #include "Utils/NVAPI.slangh" // We need this for 64-bit atomics.
import Helper;

#define ATOMIC_ADD_FLOAT(Buffer, Address, Increment) \
{ \
	uint NewValue = asuint(Increment); \
	uint CompareValue = 0; \
	uint OldValue; \
	[allow_uav_condition] \
	while (true) \
	{ \
		Buffer.InterlockedCompareExchange(Address, CompareValue, NewValue, OldValue); \
		if (OldValue == CompareValue) \
			break; \
		CompareValue = OldValue; \
		NewValue = asuint(Increment + asfloat(OldValue)); \
	} \
}

struct GeneratePhotonsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    
    RWByteAddressBuffer visiblePoints;
    StructuredBuffer<PackedBoundingBox> visiblePointsBoundingBoxBuffer;
    RaytracingAccelerationStructure visiblePointsAS;
    AliasTable emissiveTable;

    void atomicAddFlux(uint pointer, float3 flux)
    {
        const uint typeSize = 5 * 16;
        const uint base = typeSize * pointer;

        ATOMIC_ADD_FLOAT(visiblePoints, base + 32, flux.r);
        ATOMIC_ADD_FLOAT(visiblePoints, base + 36, flux.g);
        ATOMIC_ADD_FLOAT(visiblePoints, base + 40, flux.b);

        // NvInterlockedAddFp32(visiblePoints, base + 32, flux.r);
        // NvInterlockedAddFp32(visiblePoints, base + 36, flux.g);
        // NvInterlockedAddFp32(visiblePoints, base + 40, flux.b);

        visiblePoints.InterlockedAdd(base + 44, 1);
    }

    void execute(const uint photonIndex)
    {
        if (any(photonIndex >= params.photonCount))
        {
            return;
        }

        ITextureSampler lod = ExplicitLodTextureSampler(0.f);

        // Light Tracing
        SampleGenerator sg = SampleGenerator(uint2(photonIndex, 1), params.seed);
        uint triIndex = emissiveTable.sample(sampleNext2D(sg));
        float triPdf = emissiveTable.getWeight(triIndex) / emissiveTable.weightSum;

        EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(triIndex);
        float samplePdf = triPdf / emissiveTri.area;
        float3 barycentric = sample_triangle(sampleNext2D(sg));
        float3 samplePos = emissiveTri.getPosition(barycentric);
        float2 sampleUV = emissiveTri.getTexCoord(barycentric);
        float3 flux = gScene.materials.evalEmissive(emissiveTri.materialID, sampleUV);
        flux = flux * M_PI / samplePdf;

        Ray ray = Ray(computeRayOrigin(samplePos, emissiveTri.normal), cosineWeightedSampling(sampleNext2D(sg), emissiveTri.normal));

        for (uint i = 0; i < 10; i++)
        {
            HitInfo hit;
            float hitT;
            if (!traceSceneRay<1>(ray, hit, hitT, RAY_FLAG_NONE, 0xff))
            {
                break;
            }

            ShadingData sd = shadingDataLoader.loadShadingData(hit, ray.origin, ray.dir, false, lod);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

            BSDFSample bsdfSample;
            if (!bsdf.sample(sd, sg, bsdfSample))
            {
                break;
            }

//             flux = flux * bsdfSample.weight;

            float3 newFlux = flux * bsdfSample.weight;
            float continuationProb = sqrt(saturate(max(newFlux.x, max(newFlux.y, newFlux.z)) / max(flux.x, max(flux.y, flux.z))));
            if (continuationProb < 1)
            {
                if (sampleNext1D(sg) >= continuationProb)
                {
                    break;
                }
                flux = newFlux / continuationProb;
            }
            else
            {
                flux = newFlux;
            }

            // Process Photon Here
            RayDesc searchRay;
            searchRay.Origin = sd.posW;
            searchRay.Direction = float3(0.0f, 1.0f, 0.0f);
            searchRay.TMin = 0.0f;
            searchRay.TMax = 0.0f;
            RayQuery<RAY_FLAG_NONE> rayQuery;
            rayQuery.TraceRayInline(visiblePointsAS, RAY_FLAG_NONE, 0xff, searchRay);
            while(rayQuery.Proceed())
            {
                if(rayQuery.CandidateType() == CANDIDATE_PROCEDURAL_PRIMITIVE)
                {
                    uint pointer = rayQuery.CandidatePrimitiveIndex();
                    VisiblePoint visiblePoint = VisiblePoint(visiblePoints, pointer);
                    ShadingData sdVisiblePoint = visiblePoint.constructShadingData(shadingDataLoader);
                    float3 visiblePointToPhoton = sd.posW - sdVisiblePoint.posW;
                    
                    // // Inside Radius
                    if (dot(visiblePointToPhoton, visiblePointToPhoton) < (visiblePoint.radius * visiblePoint.radius))
                    {
                        atomicAddFlux(pointer, flux);
                    }
                }
            }
            
            // Update Ray
            ray.origin = sd.computeNewRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            ray.dir = bsdfSample.wo;   
        }
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
