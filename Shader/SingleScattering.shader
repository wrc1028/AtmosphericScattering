Shader "Unlit/SingleScattering"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}

        _PlanetParams ("Planet params", vector) = (0, 0, 0, 0)
        _AtmosphericParams ("Atmospheric params", vector) = (0, 0, 0, 0)

        _RayDirectionStepCount ("Ray Direction Step Count", Range(1, 32)) = 8
        _LightDirectionStepCount ("Light Direction Step Count", Range(1, 32)) = 8
    }
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Filtering.hlsl"

    struct Attributes
    {
        float4 positionOS : POSITION;
        float2 texcoord   : TEXCOORD0;
    };

    struct Varyings
    {
        float4 positionCS   : SV_POSITION;
        float2 uv           : TEXCOORD0;
        float3 positionWS   : TEXCOORD1;
    };

    TEXTURE2D_X(_MainTex);                 SAMPLER(sampler_MainTex);
    TEXTURE2D_X(_CameraDepthTexture);      SAMPLER(sampler_CameraDepthTexture_point_clamp);

    float _RayDirectionStepCount;
    float _LightDirectionStepCount;

    float4 _PlanetParams;            // center position and radius
    float4 _AtmosphericParams;       // atmospheric height and density adjust
    #define PlanetCenter            _PlanetParams.xyz
    #define PlanetRadius            _PlanetParams.w
    #define AtmosphericHeight       _AtmosphericParams.x
    #define AtmosphericDensity      _AtmosphericParams.y
    #define Transmission            _AtmosphericParams.z
    #define RefractRatio            _AtmosphericParams.w
    #define PlanetRadius2           (_PlanetParams.w + _AtmosphericParams.x) * (_PlanetParams.w + _AtmosphericParams.x)
    // #define PI                      3.14159265
    Varyings VertScattering (Attributes input)
    {
        Varyings output = (Varyings)0;
        output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
        output.uv = input.texcoord;
        float4 nearClipPlaneCS = float4(output.uv * 2 - 1, 0, 1);
#if UNITY_UV_STARTS_AT_TOP
        nearClipPlaneCS.y *= -1;
#endif 
        float4 position = mul(UNITY_MATRIX_I_VP, nearClipPlaneCS);
        output.positionWS = position.xyz / position.w;
        return output;
    }

    // x : camera to sphere dst; y : ray in sphere dst
    // 交点算法优化
    // 根据地球模型来优化: 分为三层: 底层(空气密度大, 大分子多); 中间层(空气密度较小, 基本全是小分子); 臭氧层(会吸收部分波长)
    float2 RayHitSphereDistance(float3 rayOrigin, half3 rayDirection)
    {
        float3 cameraToSphereCenter = PlanetCenter - rayOrigin;
        float projectLength = dot(rayDirection, cameraToSphereCenter);
        float height2 = dot(cameraToSphereCenter, cameraToSphereCenter) - projectLength * projectLength;
        if (height2 < PlanetRadius2)
        {
            float bottom = sqrt(PlanetRadius2 - height2);
            float dstToSphere = max(0, projectLength - bottom);
            float dstInsideSphere = dstToSphere == 0 ? projectLength + bottom : bottom * 2;
            return float2(dstToSphere, dstInsideSphere);
        }
        return float2(1.#INF, 0);
    }
    // 计算当前点的大气密度: 获取两点之间靠近中点的密度
    float GetAtmosphericDensity(float3 destination, half3 rayDirection, float stepSize)
    {
        // destination += rayDirection * stepSize * 0.5;
        float currentAltitude = saturate((length(destination - PlanetCenter) - PlanetRadius) / AtmosphericHeight);
        return exp(-currentAltitude * AtmosphericDensity) * (1 - currentAltitude);
    }
    float3 Pow4(float3 value) { return value * value * value * value; }
    // 部分参数可以由脚本传入
    float3 RayleighConstant(float refractRatio)
    {
        float3 waveLenghtFactor = 1.0f / Pow4(float3(700, 530, 440));
        float refractFactor = (8 * PI * PI * PI * (refractRatio * refractRatio - 1) * (refractRatio * refractRatio - 1)) / 3;
        return refractFactor * waveLenghtFactor;
    }
    // 波的吸收
    float3 Scattering(float3 originColor, float opticalDepth)
    {
        float3 rayleighConstant = RayleighConstant(RefractRatio);
        return originColor * exp(-rayleighConstant * opticalDepth * Transmission);
    }
    float3 PhaseFunction(float3 originColor, float cosAlpha)
    {
        float phase = (3 * (1 + cosAlpha * cosAlpha)) / (16 * PI);
        return originColor * phase;
    }

    float CalculateOpticalDepth(float3 originPoint, half3 rayDirection, float marchingLength, float steps)
    {
        float stepSize = marchingLength / (steps - 1);
        float opticalDepth = 0;
        for (int i = 0; i < steps; i++)
        {
            opticalDepth += GetAtmosphericDensity(originPoint, rayDirection, stepSize);
            originPoint += rayDirection * stepSize;
        }
        return opticalDepth * stepSize;
    }
    
    float3 CalculateScattering(float3 rayOrigin, half3 rayDirection, float marchingLength, Light light, float4 sceneColor)
    {
        // ray direction optical depth and light direction optical depth
        float stepSize = marchingLength / (_RayDirectionStepCount - 1);
        float rayDirectionOpticalDepth = 0;
        float3 destination = rayOrigin;
        float3 result = 0;
        // 仅计算空气中光的散射
        for (int i = 0; i < (int)_RayDirectionStepCount; i++)
        {
            // 每步进一步, 计算当前点的大气密度, 并且对密度进行累加
            rayDirectionOpticalDepth += CalculateOpticalDepth(destination, rayDirection, stepSize, _LightDirectionStepCount);
            // 获得当前点光源方向上光被大气吸收后的结果, 判断是否在阴影里
            float lightRayInsideSphereDst = RayHitSphereDistance(destination, light.direction).y;
            float lightAbsorptionResult = CalculateOpticalDepth(destination, light.direction, lightRayInsideSphereDst, _LightDirectionStepCount);
            result += Scattering(light.color, rayDirectionOpticalDepth + lightAbsorptionResult);
            
            destination += rayDirection * stepSize;
        }
        // 计算场景中物体到相机的一个散射结果, 也就是雾效 rayDirectionOpticalDepth
        result += Scattering(sceneColor.rgb, rayDirectionOpticalDepth);
        return result;
    }

    float4 FragScattering(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float2 uv = UnityStereoTransformScreenSpaceTex(input.uv);
        float rayDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture_point_clamp, uv);
        float depth = LinearEyeDepth(rayDepth, _ZBufferParams);
        
        float3 rayOrigin = GetCameraPositionWS();
        half3  rayDirection = normalize(input.positionWS - rayOrigin);
        Light mainLight = GetMainLight();
        // x : camera to sphere dst; y : ray in sphere dst
        float2 rayHitResult = RayHitSphereDistance(rayOrigin, rayDirection);
        float rayInsideSphereDst = depth - rayHitResult.x;
        rayInsideSphereDst = rayInsideSphereDst > (_ProjectionParams.z - 20) ? rayHitResult.y : rayInsideSphereDst;
        
        float4 sceneColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv);
        
        if (rayInsideSphereDst > 0)
        {
            rayOrigin = rayOrigin + rayDirection * rayHitResult.x;
            sceneColor.rgb = CalculateScattering(rayOrigin, rayDirection, rayInsideSphereDst, mainLight, sceneColor);
        }

        return sceneColor;
    }

    ENDHLSL
    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite off
        Pass
        {
            Name "Single Scattering"

            HLSLPROGRAM
            #pragma vertex VertScattering
            #pragma fragment FragScattering
            ENDHLSL
        }
    }
}
