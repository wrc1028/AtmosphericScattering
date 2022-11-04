using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace AtmosphericScattering
{
    public class AtmosphericScatteringPass : ScriptableRenderPass
    {
        private const string k_ProfilerTag = "Atmospheric Scattering";
        private ProfilingSampler m_ProfilerSampler = new ProfilingSampler(k_ProfilerTag);
        private AtmosphericScatteringSettings m_Settings;
        private Material m_ScatteringMat;
        private RenderTargetIdentifier m_CurrentTarget;
        private RenderTargetHandle m_TempTargetHandle;
        private RenderTextureDescriptor m_TempTargetDescriptor;
        public AtmosphericScatteringPass(RenderPassEvent passEvent, AtmosphericScatteringSettings settings)
        {
            renderPassEvent = passEvent;
            m_Settings = settings;
            m_ScatteringMat = new Material(m_Settings.singleScatteringShader);
        }
        public void Setup(RenderTargetIdentifier currentTarget)
        {
            m_CurrentTarget = currentTarget;
        }
        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            m_TempTargetDescriptor = cameraTextureDescriptor;
            m_TempTargetDescriptor.msaaSamples = 1;
            m_TempTargetHandle.Init("_ATTempTexture");
            cmd.GetTemporaryRT(m_TempTargetHandle.id, m_TempTargetDescriptor);
        }
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (m_Settings.material == null) return;
            CommandBuffer cmd = CommandBufferPool.Get(k_ProfilerTag);
            using (new ProfilingScope(cmd, m_ProfilerSampler))
            {
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                cmd.Blit(m_CurrentTarget, m_TempTargetHandle.Identifier());
                cmd.Blit(m_TempTargetHandle.Identifier(), m_CurrentTarget, m_Settings.material, 0);
            }
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
        
        public override void FrameCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(m_TempTargetHandle.id);
        }
    }
}