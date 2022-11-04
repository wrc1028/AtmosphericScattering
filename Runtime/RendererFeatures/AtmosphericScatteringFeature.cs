using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace AtmosphericScattering
{
    [System.Serializable]
    public class AtmosphericScatteringSettings
    {
        [SerializeField] internal Shader singleScatteringShader;
        [SerializeField] internal Material material;
        [Header("Earth Model")]
        [SerializeField] internal float planetRadius = 64000000.0f;
        [SerializeField] internal float atmosphericHeight = 8000000.0f;
        [SerializeField] internal float atmosphericDensity = 1.0f;
    }
    public class AtmosphericScatteringFeature : ScriptableRendererFeature
    {
        [SerializeField] private RenderPassEvent m_Event = RenderPassEvent.AfterRenderingSkybox;
        [SerializeField] private AtmosphericScatteringSettings m_Settings = new AtmosphericScatteringSettings();

        private AtmosphericScatteringPass m_ScriptablePass;

        public override void Create()
        {
            if (m_Settings.singleScatteringShader == null) return;
            m_ScriptablePass = new AtmosphericScatteringPass(m_Event, m_Settings);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (m_Settings.singleScatteringShader == null) return;
            m_ScriptablePass.Setup(renderer.cameraColorTarget);
            renderer.EnqueuePass(m_ScriptablePass);
        }
    }
}
