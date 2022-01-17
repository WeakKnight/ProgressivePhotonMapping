#include "Scene/SceneDefines.slangh"
import Scene.Scene;
__exported import Scene.HitInfo;
import Scene.Material.ShadingUtils;
import Rendering.Materials.TexLODHelpers;
import Utils.Math.MathHelpers;
import Types;

struct ShadingDataLoader
{
    Texture2D<PackedHitInfo> VBuffer;

    Ray getPrimaryRay(uint2 pixel, uint2 frameDim, const Camera camera)
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(pixel, frameDim);
    }

    HitInfo loadHitInfo(uint2 pixel)
    {
        HitInfo hit = HitInfo(VBuffer[pixel]);
        return hit;
    }

    VertexData loadVertexData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, out uint materialID, out float curveSphereRadius)
    {
        VertexData v = {};
        materialID = {};
        curveSphereRadius = {};
    #if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    #if SCENE_HAS_PROCEDURAL_GEOMETRY()
        if (hit.getType() == HitType::Triangle)
    #endif
        {
            const TriangleHit triangleHit = hit.getTriangleHit();
            StaticVertexData vertices[3];
            v = gScene.getVertexData(triangleHit, vertices);
            materialID = gScene.getMaterialID(triangleHit.instanceID);

            bool isFrontFaceCW = gScene.isObjectFrontFaceCW(triangleHit.instanceID);
            float4x4 worldMat = gScene.getWorldMatrix(triangleHit.instanceID);
            float3x3 worldInvTransposeMat = gScene.getInverseTransposeWorldMatrix(triangleHit.instanceID);
        }
    #endif
    #if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
        if (hit.getType() == HitType::DisplacedTriangle)
        {
            const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
            v = gScene.getVertexData(displacedTriangleHit, -rayDir);
            materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
        }
    #endif
    #if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
        if (hit.getType() == HitType::Curve)
        {
            const CurveHit curveHit = hit.getCurveHit();
            v = gScene.getVertexDataFromCurve(curveHit, curveSphereRadius);
            materialID = gScene.getMaterialID(curveHit.instanceID);
        }
    #endif
    #if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
        if (hit.getType() == HitType::SDFGrid)
        {
            const SDFGridHit sdfGridHit = hit.getSDFGridHit();
            v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
            materialID = gScene.getMaterialID(sdfGridHit.instanceID);
        }
    #endif
        return v;
    }

    void adjustShadingData(inout ShadingData sd, const HitInfo hit, const float curveSphereRadius, const VertexData v, const bool isPrimary)
    {
        // Set sphere radius at the curve intersection point.
        // Reuse the metallic field.
    #if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
        if (hit.getType() == HitType::Curve) sd.curveSphereRadius = curveSphereRadius;
    #endif

        adjustShadingNormal(sd, v);
    }

    ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const bool isPrimary, const ITextureSampler lod)
    {
        uint materialID = {};
        float curveSphereRadius = {};

        VertexData v = loadVertexData(hit, rayOrigin, rayDir, materialID, curveSphereRadius);
        ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
        adjustShadingData(sd, hit, curveSphereRadius, v, isPrimary);
        return sd;
    }

    ShadingData loadShadingData(uint2 pixel, uint2 frameDim, const Camera camera)
    {
        ExplicitLodTextureSampler lod = ExplicitLodTextureSampler(0.f);
        Ray ray = getPrimaryRay(pixel, frameDim, camera);
        HitInfo hit = loadHitInfo(pixel);
        return loadShadingData(hit, ray.origin, ray.dir, true, lod);
    }

    bool isPixelValid(uint2 pixel, uint2 frameDim)
    {
        HitInfo hit = HitInfo(VBuffer[pixel]);
        return hit.isValid();
    }
};
