/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "ProgressivePhotonMapping.h"
#include "ShadingDataLoader.h"

const RenderPass::Info ProgressivePhotonMapping::kInfo { "ProgressivePhotonMapping", "Insert pass description here." };

const std::string kGenerateVisiblePointsFile = "RenderPasses/ProgressivePhotonMapping/GenerateVisiblePoints.cs.slang";
const std::string kGeneratePhotonsFile = "RenderPasses/ProgressivePhotonMapping/GeneratePhotons.cs.slang";
const std::string kResolvePassFile = "RenderPasses/ProgressivePhotonMapping/ResolvePass.cs.slang";
const std::string kShaderModel = "6_5";

const ChannelList kInputChannels =
{
    { "vbuffer",    "",     "Visibility buffer in packed format",   false, HitInfo::kDefaultFormat },
};

const ChannelList kOutputChannels =
{
    { "color",      "",     "Output color", false, ResourceFormat::RGBA32Float},
};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(ProgressivePhotonMapping::kInfo, ProgressivePhotonMapping::create);
}

ProgressivePhotonMapping::ProgressivePhotonMapping() : RenderPass(kInfo)
{
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_TINY_UNIFORM);

    Program::DefineList defines;
    defines.add(mpSampleGenerator->getDefines());
    defines.add("_MS_DISABLE_ALPHA_TEST");
    defines.add("_DEFAULT_ALPHA_TEST");

    mpGenerateVisiblePointsPass = ComputePass::create(Program::Desc(kGenerateVisiblePointsFile).setShaderModel(kShaderModel).csEntry("main"), defines, false);
    mpGeneratePhotonsPass = ComputePass::create(Program::Desc(kGeneratePhotonsFile).setShaderModel(kShaderModel).csEntry("main"), defines, false);
    mpResolvePass = ComputePass::create(Program::Desc(kResolvePassFile).setShaderModel(kShaderModel).csEntry("main"), defines, false);
}

void ProgressivePhotonMapping::setParamShaderData(const ShaderVar& var)
{
    var["frameDim"] = mParams.frameDim;
    var["frameCount"] = mParams.frameCount;
    var["seed"] = mParams.frameCount;
}

ProgressivePhotonMapping::SharedPtr ProgressivePhotonMapping::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ProgressivePhotonMapping());
    for (const auto& [key, value] : dict)
    {
        logWarning("Unknown field '" + key + "' in a ProgressivePhotonMapping dictionary");
    }
    return pPass;
}

Dictionary ProgressivePhotonMapping::getScriptingDictionary()
{
    Dictionary dict;
    return dict;
}

RenderPassReflection ProgressivePhotonMapping::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ProgressivePhotonMapping::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mpScene == nullptr)
    {
        return;
    }

    beginFrame(pRenderContext, renderData);

    prepareLighting(pRenderContext);

    if (mRecompile)
    {
        recompile();
    }

    generateHitPoints(pRenderContext, renderData);

    generatePhotons(pRenderContext, renderData);

    resolve(pRenderContext, renderData);

    endFrame(pRenderContext, renderData);
}

void ProgressivePhotonMapping::renderUI(Gui::Widgets& widget)
{
}

void ProgressivePhotonMapping::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;
}

void ProgressivePhotonMapping::beginFrame(RenderContext* pRenderContext, const RenderData& renderData)
{
    const auto& pOutputColor = renderData[kOutputChannels[0].name]->asTexture();
    mParams.frameDim = uint2(pOutputColor->getWidth(), pOutputColor->getHeight());
    mParams.seed = mParams.frameCount;

    if (!mpVisiblePoints)
    {
        mpVisiblePoints = Buffer::createStructured(sizeof(VisiblePoint), mParams.frameDim.x * mParams.frameDim.y);
    }
}

void ProgressivePhotonMapping::recompile()
{
    Shader::DefineList defines = mpScene->getSceneDefines();
    if (mpEmissiveSampler)
    {
        defines.add(mpEmissiveSampler->getDefines());
    }
    Program::TypeConformanceList typeConformances = mpScene->getTypeConformances();

    auto prepareProgram = [&](Program::SharedPtr program)
    {
        program->addDefines(defines);
        program->setTypeConformances(typeConformances);
    };

    prepareProgram(mpGenerateVisiblePointsPass->getProgram());
    mpGenerateVisiblePointsPass->setVars(nullptr);

    prepareProgram(mpGeneratePhotonsPass->getProgram());
    mpGeneratePhotonsPass->setVars(nullptr);

    prepareProgram(mpResolvePass->getProgram());
    mpResolvePass->setVars(nullptr);
}

bool ProgressivePhotonMapping::prepareLighting(RenderContext* pRenderContext)
{
    bool lightingChanged = false;

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::RenderSettingsChanged))
    {
        lightingChanged = true;
        mRecompile = true;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::EnvMapChanged))
    {
        mpEnvMapSampler = nullptr;
        lightingChanged = true;
        mRecompile = true;
    }

    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler)
        {
            mpEnvMapSampler = EnvMapSampler::create(pRenderContext, mpScene->getEnvMap());
            lightingChanged = true;
            mRecompile = true;
        }
    }
    else
    {
        if (mpEnvMapSampler)
        {
            mpEnvMapSampler = nullptr;
            lightingChanged = true;
            mRecompile = true;
        }
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    if (mpScene->useEmissiveLights())
    {
        if (!mpEmissiveSampler)
        {
            const auto& pLights = mpScene->getLightCollection(pRenderContext);
            assert(pLights && pLights->getActiveLightCount() > 0);
            assert(!mpEmissiveSampler);

            mpEmissiveSampler = EmissivePowerSampler::create(pRenderContext, mpScene);
            
            lightingChanged = true;
            mRecompile = true;
        }
    }
    else
    {
        if (mpEmissiveSampler)
        {
            mpEmissiveSampler = nullptr;
            lightingChanged = true;
            mRecompile = true;
        }
    }

    if (mpEmissiveSampler)
    {
        lightingChanged |= mpEmissiveSampler->update(pRenderContext);
    }

    return lightingChanged;
}

void ProgressivePhotonMapping::generateHitPoints(RenderContext* pRenderContext, const RenderData& renderData)
{
    PROFILE("Generate Hit Points");

    auto cb = mpGenerateVisiblePointsPass["CB"];
    setParamShaderData(cb["gGenerateVisiblePointsPass"]["params"]);
    ShadingDataLoader::setShaderData(renderData, cb["gGenerateVisiblePointsPass"]["shadingDataLoader"]);
    cb["gGenerateVisiblePointsPass"]["visiblePoints"] = mpVisiblePoints;

    mpSampleGenerator->setShaderData(mpGenerateVisiblePointsPass->getRootVar());
    mpScene->setRaytracingShaderData(pRenderContext, mpGenerateVisiblePointsPass->getRootVar());

    mpGenerateVisiblePointsPass->execute(pRenderContext, mParams.frameDim.x, mParams.frameDim.y);
}

void ProgressivePhotonMapping::generatePhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    PROFILE("Generate Photons");
}

void ProgressivePhotonMapping::resolve(RenderContext* pRenderContext, const RenderData& renderData)
{
    PROFILE("Resolve");

    auto cb = mpResolvePass["CB"];
    setParamShaderData(cb["gResolvePass"]["params"]);
    cb["gResolvePass"]["outputColor"] = renderData[kOutputChannels[0].name]->asTexture();
    if (mpEnvMapSampler)
    {
        mpEnvMapSampler->setShaderData(cb["gResolvePass"]["envMapSampler"]);
    }
    if (mpEmissiveSampler)
    {
        mpEmissiveSampler->setShaderData(cb["gResolvePass"]["emissiveSampler"]);
    }
    ShadingDataLoader::setShaderData(renderData, cb["gResolvePass"]["shadingDataLoader"]);
    cb["gResolvePass"]["visiblePoints"] = mpVisiblePoints;

    mpSampleGenerator->setShaderData(mpResolvePass->getRootVar());
    mpScene->setRaytracingShaderData(pRenderContext, mpResolvePass->getRootVar());

    mpResolvePass->execute(pRenderContext, mParams.frameDim.x, mParams.frameDim.y);
}

void ProgressivePhotonMapping::endFrame(RenderContext* pRenderContext, const RenderData& renderData)
{
    mParams.frameCount++;
}
