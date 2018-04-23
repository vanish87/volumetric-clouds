﻿Shader "Hidden/Clouds"
{
	Properties
	{
		_MainTex("Texture", 2D) = "white" {}
	}
		SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Off

		Pass
	{
		CGPROGRAM
#pragma vertex vert
#pragma fragment frag
#pragma target 5.0
#pragma multi_compile __ DEBUG_NO_LOW_FREQ_NOISE
#pragma multi_compile __ DEBUG_NO_HIGH_FREQ_NOISE
#pragma multi_compile __ DEBUG_DENSITY
#pragma multi_compile __ ALLOW_IN_CLOUDS
#pragma multi_compile __ RANDOM_JITTER_WHITE RANDOM_JITTER_BLUE
#pragma multi_compile __ RANDOM_UNIT_SPHERE

#include "UnityCG.cginc"

#define BIG_STEP 2.5

		struct appdata
	{
		float4 vertex : POSITION;
		float2 uv : TEXCOORD0;
	};

	struct v2f
	{
		float2 uv : TEXCOORD0;
		float4 pos : SV_POSITION;
		float4 ray : TEXCOORD1;
	};


	uniform sampler2D_float _CameraDepthTexture;

	uniform float4x4 _CameraInvViewMatrix;
	uniform float4x4 _FrustumCornersES;
	uniform float4 _CameraWS;
	uniform float _FarPlane;

	uniform sampler2D _MainTex;
	uniform float4 _MainTex_TexelSize;

	uniform sampler2D _AltoClouds;
	uniform sampler3D _ShapeTexture;
	uniform sampler3D _ErasionTexture;
	uniform sampler2D _WeatherTexture;
	uniform sampler2D _CurlNoise;
	uniform sampler2D _BlueNoise;
	uniform float4 _BlueNoise_TexelSize;
	uniform float4 _Randomness;
	uniform float _SampleMultiplier;

	uniform float3 _SunDir;
	uniform float3 _PlanetCenter;
	uniform float3 _SunColor;

	uniform float3 _CloudBaseColor;
	uniform float3 _CloudTopColor;

	uniform float3 _ZeroPoint;
	uniform float _SphereSize;
	//uniform float _StartHeight;
	uniform float2 _CloudHeightMinMax;
	uniform float _Thickness;

	uniform float _Coverage;
	uniform float _AmbientLightFactor;
	uniform float _SunLightFactor;
	uniform float _HenyeyGreensteinGForward;
	uniform float _HenyeyGreensteinGBackward;
	uniform float _InverseStep;
	uniform float _LightStepLength;
	uniform float _LightConeRadius;

	uniform float _Density;

	// Temporary test uniforms
	uniform float _TestFloat;
	uniform float _TestFloat2;

	uniform float _Scale;
	uniform float _ErasionScale;
	uniform float _WeatherScale;
	uniform float _CurlDistortScale;
	uniform float _CurlDistortAmount;

	uniform float _WindSpeed;
	uniform float3 _WindDirection;
	uniform float3 _WindOffset;
	uniform float2 _CoverageWindOffset;
	uniform float2 _HighCloudsWindOffset;

	uniform float _CoverageHigh;
	uniform float _CoverageHighScale;
	uniform float _HighCloudsScale;

	uniform float2 _LowFreqMinMax;
	uniform float _HighFreqModifier;

	uniform float4 _Gradient1;
	uniform float4 _Gradient2;
	uniform float4 _Gradient3;

	uniform int _Steps;

	v2f vert(appdata v)
	{
		v2f o;

		half index = v.vertex.z;
		v.vertex.z = 0.1;

		o.pos = UnityObjectToClipPos(v.vertex);
		o.uv = v.uv.xy;

#if UNITY_UV_STARTS_AT_TOP
		if (_MainTex_TexelSize.y < 0)
			o.uv.y = 1 - o.uv.y;
#endif

		// Get the eyespace view ray (normalized)
		o.ray = _FrustumCornersES[(int)index];
		// Dividing by z "normalizes" it in the z axis
		// Therefore multiplying the ray by some number i gives the viewspace position
		// of the point on the ray with [viewspace z]=i
		o.ray /= abs(o.ray.z);

		// Transform the ray from eyespace to worldspace
		o.ray = mul(_CameraInvViewMatrix, o.ray);

		return o;
	}

	// http://byteblacksmith.com/improvements-to-the-canonical-one-liner-glsl-rand-for-opengl-es-2-0/
	float rand(float2 co) {
		float a = 12.9898;
		float b = 78.233;
		float c = 43758.5453;
		float dt = dot(co.xy, float2(a, b));
		float sn = fmod(dt, 3.14);

		return 2.0 * frac(sin(sn) * c) - 1.0;
	}

	float weatherDensity(float3 weatherData)
	{
		return weatherData.b + 1.0;//mad(weatherData.b, 2.0, 1.0);
	}

	// from GPU Pro 7
	float remap(float original_value, float original_min, float original_max, float new_min, float new_max)
	{
		return new_min + (((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
	}

	float getHeightFractionForPoint(float3 inPosition)
	{
		//return (inPosition.y - _CloudHeightMinMax.x) / (_CloudHeightMinMax.y - _CloudHeightMinMax.x);
		return saturate((distance(inPosition,  _PlanetCenter) - (_SphereSize + _CloudHeightMinMax.x)) / _Thickness);
	}

	float improvedGradient(float4 gradient, float height)
	{
		return smoothstep(gradient.x, gradient.y, height) - smoothstep(gradient.z, gradient.w, height);
	}

	float getDensityHeightGradient(float height, float3 weather_data)
	{
		float type = weather_data.g;
		float4 gradient = lerp(lerp(_Gradient1, _Gradient2, type * 2.0), _Gradient3, saturate((type - 0.5) * 2.0));
		return improvedGradient(gradient, height);//improvedGradient(_Gradient3, height);//
	}

	float3 sampleWeather(float3 p) {
		return tex2Dlod(_WeatherTexture, float4((p.xz + _CoverageWindOffset) * _WeatherScale + float2(0.5, 0.5), 0, 0)).rgb;
	}

	float sampleCloudDensity(float3 p, float3 weather_data, float lod, bool sampleDetail)
	{
		float height_fraction = getHeightFractionForPoint(p);

		float3 pos = p + _WindOffset;
		pos += height_fraction * _WindDirection * 500;

#if defined(DEBUG_NO_LOW_FREQ_NOISE)
		float base_cloud = 0.7;
		base_cloud = remap(base_cloud/* * pow(1.20 - height_fraction, 0.5)*/, _LowFreqMinMax.x, _LowFreqMinMax.y, 0.0, 1.0);
#else
		float4 low_frequency_noises = tex3Dlod(_ShapeTexture, float4(pos * _Scale, lod));
		//float low_freq_FBM = low_frequency_noises.g * 0.625 +low_frequency_noises.b * 0.25 + low_frequency_noises.a * 0.125;
		float base_cloud = low_frequency_noises.r;//remap(low_frequency_noises.r, -(1.0 - low_freq_FBM), 1.0, 0.0, 1.0);//
		base_cloud = remap(base_cloud * pow(1.2 - height_fraction, 0.1), _LowFreqMinMax.x, _LowFreqMinMax.y, 0.0, 1.0);
#endif
		base_cloud *= getDensityHeightGradient(height_fraction, weather_data);//improvedGradient(_TestGradient, height_fraction);//

		float cloud_coverage = saturate(weather_data.r - _Coverage);
		float base_cloud_with_coverage = saturate(remap(base_cloud, saturate(height_fraction / cloud_coverage), 1.0, 0.0, 1.0)); // saturate ?

		float final_cloud = base_cloud_with_coverage * cloud_coverage;

#if defined(DEBUG_NO_HIGH_FREQ_NOISE)
		final_cloud = remap(final_cloud, 0.2, 1.0, 0.0, 1.0);
#else
		if (final_cloud > 0.0 && sampleDetail)
		{
			float3 curl_noise = mad(tex2Dlod(_CurlNoise, float4(p.xz * _Scale * _CurlDistortScale, 0, 0)).rgb, 2.0, -1.0);

			pos += curl_noise * height_fraction * _CurlDistortAmount;

			float3 high_frequency_noises = tex3Dlod(_ErasionTexture, float4(pos * _Scale * _ErasionScale, lod)).rgb;
			float high_freq_FBM = high_frequency_noises.r;//high_frequency_noises.r * 0.625 + high_frequency_noises.g * 0.25 + high_frequency_noises.b * 0.125;

			float high_freq_noise_modifier = lerp(1.0 - high_freq_FBM, high_freq_FBM, saturate(height_fraction * 10.0));

			final_cloud = remap(final_cloud, high_freq_noise_modifier * _HighFreqModifier, 1.0, 0.0, 1.0);
		}
		else
		{
			final_cloud = remap(final_cloud, 0.2, 1.0, 0.0, 1.0);
		}
#endif

		return max(final_cloud *_InverseStep * _SampleMultiplier, 0.0);
	}

	// GPU Pro 7
	float beerLaw(float density)
	{
		float d = -density * _Density;
		return max(exp(d), exp(d * 0.5)*0.7);//exp(d);//
	}

	// GPU Pro 7
	float HenyeyGreensteinPhase(float cosAngle, float g)
	{
		float g2 = g * g;
		return ((1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cosAngle, 1.5)) / 4.0 * 3.1415;
	}

	// GPU Pro 7
	float powderEffect(float density, float cosAngle)
	{
		float powder = 1.0 - exp(-density * 2.0);
		return lerp(1.0f, powder, saturate((-cosAngle * 0.5f) + 0.5f));
	}

	float calculateLightEnergy(float density, float cosAngle, float powderDensity) {
		//return beerLaw(density, 1.0 + weather * 0.25);
		float beerPowder = 2.0 * beerLaw(density) * powderEffect(powderDensity, cosAngle);
		float HG = max(HenyeyGreensteinPhase(cosAngle, _HenyeyGreensteinGForward), HenyeyGreensteinPhase(cosAngle, _HenyeyGreensteinGBackward)) * 0.07 + 0.8;
		return beerPowder * HG;
	}

	float randSimple(float n)
	{
		return mad(frac(sin(n) * 43758.5453123), 2.0, -1.0);
	}

	float rand3(float3 n)
	{
		return normalize(float3(randSimple(n.x), randSimple(n.y), randSimple(n.z)));
	}

	float3 sampleConeToLight(float3 pos, float3 lightDir, float cosAngle, float density, float3 initialWeather, float lod)
	{
		float height_fraction = getHeightFractionForPoint(pos);
#if defined(RANDOM_UNIT_SPHERE)
#else
		const float3 RandomUnitSphere[5] =
		{
			{ -0.6, -0.8, -0.2 },
		{ 1.0, -0.3, 0.0 },
		{ -0.7, 0.0, 0.7 },
		{ -0.2, 0.6, -0.8 },
		{ 0.4, 0.3, 0.9 }
		};
#endif
		float densityAlongCone = 0.0;
		const int steps = 5;
		float3 weather_data;
		for (int i = 0; i < steps; i++) {
			pos += lightDir * _LightStepLength;
#if defined(RANDOM_UNIT_SPHERE)
			float3 randomOffset = rand3(pos) * _LightStepLength * _LightConeRadius * ((float)(i + 1));
#else
			float3 randomOffset = RandomUnitSphere[i] * _LightStepLength * _LightConeRadius * ((float)(i + 1));
#endif
			float3 p = pos +randomOffset;
			weather_data = sampleWeather(p);
			densityAlongCone += sampleCloudDensity(p, weather_data, lod + ((float)i) * 0.5, true) * weatherDensity(weather_data);
		}

		pos += 32.0 * _LightStepLength * lightDir;
		weather_data = sampleWeather(pos);
		densityAlongCone += sampleCloudDensity(pos, weather_data, lod + 2, false) * weatherDensity(weather_data) * 3.0;
		/*
		pos += 5.0 * _LightStepLength * lightDir;
		weather_data = sampleWeather(pos);
		densityAlongCone += sampleCloudDensity(pos, weather_data, lod, true) * 3.0;
		int j = 0;
		while (1) {
		if (j > 22) {
		break;
		}
		pos += 4.0 * _LightStepLength * lightDir;
		weather_data = sampleWeather(pos);
		if (weather_data.r - _Coverage > 0.05) {
		densityAlongCone += sampleCloudDensity(pos, weather_data, lod, true);
		}

		j++;
		}
		*/
		return calculateLightEnergy(densityAlongCone, cosAngle, density) * _SunColor;
	}

	fixed4 raymarch(float3 ro, float3 rd, float steps, float stepSize, float depth, float cosAngle)
	{
		float3 pos = ro;
		fixed4 res = 0.0;
		float transmittance = 1.0;
		float lod = 0.0;

		float zeroCount = 0.0;
		float stepLength = 3.0;


		for (float i = 0.0; i < steps; i += stepLength)
		{
			if (distance(_CameraWS, pos) >= depth || res.a >= 0.99) {
				return res;
				break;
			}
#if defined(ALLOW_IN_CLOUDS)
			float height_fraction = getHeightFractionForPoint(pos);
			if (pos.y < 0.0 || height_fraction < 0.0 || height_fraction > 1.0) {
				break;
			}
#endif
			float3 weather_data = sampleWeather(pos);
			if (weather_data.r - _Coverage <= 0.0)
			{
				pos += stepSize * rd *stepLength;
				zeroCount += 1.0;
				stepLength = zeroCount > 10.0 ? BIG_STEP : 1.0;
				continue;
			}

			float cloudDensity = saturate(sampleCloudDensity(pos, weather_data, lod, true));

			float4 particle = float4(cloudDensity, cloudDensity, cloudDensity, cloudDensity);
			if (cloudDensity > 0.0)
			{

				zeroCount = 0.0;

				if (stepLength > 1.0)
				{
					i -= stepLength - 0.1;
					pos -= stepSize * rd * (stepLength - 0.1);
					weather_data = sampleWeather(pos);
					cloudDensity = saturate(sampleCloudDensity(pos, weather_data, lod, true));
					particle = float4(cloudDensity, cloudDensity, cloudDensity, cloudDensity);
				}

				 // TEST VARIABLES
				 //float testVariable = sampleCloudDensity(pos, weather_data);
				 //return fixed4(testVariable, testVariable, testVariable, 1.0);

				float T = 1.0 - particle.a;
				transmittance *= T;
#if defined(DEBUG_DENSITY)
#else
				float3 lightEnergy = sampleConeToLight(pos, _SunDir, cosAngle, cloudDensity, weather_data, lod);
				float3 ambientLight = lerp(_CloudBaseColor, _CloudTopColor, getHeightFractionForPoint(pos));

				lightEnergy *= _SunLightFactor;
				ambientLight *= _AmbientLightFactor;

				particle.rgb = lightEnergy + ambientLight;
#endif
				particle.a = 1.0 - T;
				particle.rgb *= particle.a;
				res = (1.0 - res.a) * particle + res;
			}
			else
			{
				zeroCount += 1.0;
			}
			stepLength = zeroCount > 10.0 ? BIG_STEP : 1.0;

			pos += stepSize * rd * stepLength;
		}

		return res;
	}

	// https://www.scratchapixel.com/lessons/3d-basic-rendering/minimal-ray-tracer-rendering-simple-shapes/ray-sphere-intersection
	float3 findRayStartPos(float3 rayOrigin, float3 rayDirection, float3 sphereCenter, float radius)
	{
		float3 l = rayOrigin - sphereCenter;
		float a = 1.0;
		float b = 2.0 * dot(rayDirection, l);
		float c = dot(l, l) - pow(radius, 2);
		float D = pow(b, 2) - 4.0 * a * c;
		if (D < 0.0)
		{
			return rayOrigin;
		}
		else if (abs(D) - 0.00005 <= 0.0)
		{
			return rayOrigin + rayDirection * (-0.5 * b / a);
		}
		else
		{
			float q = 0.0;
			if (b > 0.0)
			{
				q = -0.5 * (b + sqrt(D));
			}
			else
			{
				q = -0.5 * (b - sqrt(D));
			}
			float h1 = q / a;
			float h2 = c / q;
			float2 t = float2(min(h1, h2), max(h1, h2));
			if (t.x < 0.0) {
				t.x = t.y;
				if (t.x < 0.0) {
					return rayOrigin;
				}
			}
			return rayOrigin + t.x * rayDirection;
		}
	}

	float getRandomRayOffset(float2 uv)
	{
		float noise = tex2D(_BlueNoise, uv).x;
		noise = mad(noise, 2.0, -1.0);
		return noise;
	}

	fixed4 altoClouds(float3 ro, float3 rd, float depth, float cosAngle) {
		fixed4 res = 0.0;
		float3 pos = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.y + 3000.0);
		float dist = distance(ro, pos);
		if (dist < depth && pos.y > _ZeroPoint.y && dist > 0.0) {

			//float coverage = sampleWeather(pos + float3(1500.0, 0.0, 300.0) - float3(_CoverageWindOffset.x, 0.0, _CoverageWindOffset.y)).r;
			float alto = tex2D(_AltoClouds, (pos.xz + _HighCloudsWindOffset) * _HighCloudsScale).r * 2.0;

			float coverage = tex2Dlod(_WeatherTexture, float4((pos.xz + _HighCloudsWindOffset) * _CoverageHighScale, 0, 0)).r;
			coverage = saturate(coverage - _CoverageHigh);

			alto = remap(alto, 1.0 - coverage, 1.0, 0.0, 1.0);

			alto *= coverage;
			float3 directLight = max(HenyeyGreensteinPhase(cosAngle, _HenyeyGreensteinGForward), HenyeyGreensteinPhase(cosAngle, _HenyeyGreensteinGBackward)) * _SunColor;
			directLight *= _SunLightFactor * 0.2;
			float3 ambientLight = _CloudTopColor * _AmbientLightFactor * 1.5;
			float4 aLparticle = float4(min(ambientLight + directLight, 0.7), alto);

			float T = 1.0 - aLparticle.a;
			aLparticle.a = 1.0 - T;
			aLparticle.rgb *= aLparticle.a;

			res = (1.0 - res.a) * aLparticle + res;
		}

		return saturate(res);
	}

	fixed4 frag(v2f i) : SV_Target
	{
		// ray origin (camera position)
		float3 ro = _CameraWS;
		// ray direction
		float3 rd = normalize(i.ray.xyz);

		//float3 planetCenter = float3(ro.x, ro.y - _SphereSize, ro.z);

		float2 duv = i.uv;
#if UNITY_UV_STARTS_AT_TOP
		if (_MainTex_TexelSize.y < 0)
			duv.y = 1 - duv.y;
#endif
		float3 rs;
		float3 re;

		float steps;
		float stepSize;
		// Ray start pos
#if defined(ALLOW_IN_CLOUDS)
		bool aboveClouds = false;
		float distanceCameraPlanet = distance(_CameraWS, _PlanetCenter);
		if (distanceCameraPlanet < _SphereSize + _CloudHeightMinMax.x) // Below clouds
		{
			rs = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.x);
			if (rs.y < _ZeroPoint.y) // If ray starting position is below horizon
			{
				return 0.0;
			}
			re = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.y);
			steps = lerp(_Steps, _Steps * 0.5, rd.y);
			stepSize = (distance(re, rs)) / steps;
		}
		else if (distanceCameraPlanet > _SphereSize + _CloudHeightMinMax.y) // Above clouds
		{
			rs = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.y);
			re = rs + rd * _FarPlane;
			steps = lerp(_Steps, _Steps * 0.5, rd.y);
			stepSize = (distance(re, rs)) / steps;
			aboveClouds = true;
		}
		else // In clouds
		{
			rs = ro;
			re = rs + rd * _FarPlane;

			steps = lerp(_Steps, _Steps * 0.5, rd.y);
			stepSize = (distance(re, rs)) / steps;
		}

#else
		rs = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.x);
		if (rs.y < _ZeroPoint.y) // If ray starting position is below horizon
		{
			return 0.0;
		}
		re = findRayStartPos(ro, rd, _PlanetCenter, _SphereSize + _CloudHeightMinMax.y);
		steps = lerp(_Steps, _Steps * 0.5, rd.y);
		stepSize = (distance(re, rs)) / steps;
#endif
		// TEXTURE TESTING
		//float3 high_frequency_noises = tex3Dlod(_ErasionTexture, float4(rs * 7.0 * _Scale * _ErasionScale, 0)).rgb;
		//float high_freq_FBM = high_frequency_noises.r * 0.625 + high_frequency_noises.g * 0.25 + high_frequency_noises.b * 0.125;
		//fixed4 test = tex3Dlod(_ErasionTexture, float4(rs * _ErasionScale * _Scale, 0));
		//fixed4 test = tex3Dlod(_ShapeTexture, float4(rs * _Scale, 0));
		//fixed4 test = tex2Dlod(_CurlNoise, float4(rs.xz * _Scale * _CurlDistortScale, 0, 0));
		//return test;

		//fixed c = test.r;//high_freq_FBM;
		//return fixed4(c, c, c, 1.0);

		// Ray end pos


#if defined(RANDOM_JITTER_WHITE)
		rs += rd * stepSize * rand(_Time.zw + duv) * BIG_STEP * 0.75;
#endif
#if defined(RANDOM_JITTER_BLUE)
		rs += rd * stepSize * BIG_STEP * 0.75 * getRandomRayOffset((duv + _Randomness.xy) * _ScreenParams.xy * _BlueNoise_TexelSize.xy);
#endif
		//float2 ruv = (duv + _Randomness.xy) * _ScreenParams.xy / 512.0;
		//return tex2D(_BlueNoise, ruv);

		// Convert from depth buffer (eye space) to true distance from camera
		// This is done by multiplying the eyespace depth by the length of the "z-normalized"
		// ray (see vert()).  Think of similar triangles: the view-space z-distance between a point
		// and the camera is proportional to the absolute distance.
		float depth = Linear01Depth(tex2D(_CameraDepthTexture, duv).r);
		if (depth == 1.0) {
			depth = 100.0;
		}
		depth *= _FarPlane;
		//if (length(rs - ro) < depth) {
		//	return tex2Dlod(_WeatherTexture, float4(rs.xz * _WeatherScale + float2(0.5, 0.5), 0, 0));
		//	return tex3Dlod(_ShapeTexture, float4(rs * _Scale, 0));
		//}

		//fixed a = tex3Dlod(_ShapeTexture, float4(rs * _Scale * 2.0, 0)).r;
		//return fixed4(a, a, a, 1.0);
		//float3 r = mad(rand3(rs), 0.5, 0.5);
		//return fixed4(r.x, r.y, r.z, 1.0);

		float cosAngle = dot(rd, _SunDir);
		fixed4 clouds2D = altoClouds(ro, rd, depth, cosAngle);
		fixed4 clouds3D = raymarch(rs, rd, steps, stepSize, depth, cosAngle);
#if defined(ALLOW_IN_CLOUDS)
		if (aboveClouds)
		{
			return clouds3D * (1.0 - clouds2D.a) + clouds2D;
		}
		else
		{
			return clouds2D * (1.0 - clouds3D.a) + clouds3D;
		}

#else
		return clouds2D * (1.0 - clouds3D.a) + clouds3D;
#endif
	}
		ENDCG
	}
	}
}