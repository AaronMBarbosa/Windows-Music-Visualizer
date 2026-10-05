Texture2D PreviousFrame : register(t0);
Texture2D TransitionFrame : register(t1);
SamplerState LinearMirror : register(s0);

cbuffer VisualizerConstants : register(b0)
{
    float4 ResolutionTime;
    float4 AudioA;
    float4 AudioB;
    float4 AudioC;
    float4 Motion;
    float4 Modes;
    float4 Presets;
    float4 Feedback;
    float4 Dynamics;
    float4 Stage;
    float4 Camera;
    float4 Filter;
    float4 Stereo; // Left/right energy, balance, stereo width.
    float4 StereoBands[4];
    float4 History[64];
    float4 Palette0;
    float4 Palette1;
    float4 Palette2;
    float4 Palette3;
    float4 Bands[16];
    float4 Waves[16];
};

static const float PI = 3.14159265359;
static const float TAU = 6.28318530718;

struct VertexOutput
{
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

struct SceneResult
{
    float3 color;
    float2 warp;
    float persistence;
};

VertexOutput VSMain(uint vertexId : SV_VertexID)
{
    VertexOutput output;
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    output.uv = uv;
    output.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return output;
}

float hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash21(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p)
{
    float n = hash21(p);
    return frac(float2(n, n * 1.2154 + 0.137)) - 0.5;
}

float noise21(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float fbm(float2 p)
{
    float value = 0.0;
    float amplitude = 0.52;
    [unroll]
    for (int i = 0; i < 5; i++)
    {
        value += noise21(p) * amplitude;
        p = mul(float2x2(1.62, 1.18, -1.18, 1.62), p) + 0.17;
        amplitude *= 0.48;
    }
    return value;
}

float2 rotate2(float2 p, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float stereoPan(float frequencyPosition)
{
    int index = (int)round(saturate(frequencyPosition) * 15.0);
    return StereoBands[index / 4][index % 4];
}

float getBand(int index)
{
    index = clamp(index, 0, 63);
    return Bands[index / 4][index & 3];
}

float getWave(int index)
{
    index = clamp(index, 0, 63);
    return Waves[index / 4][index & 3];
}

float sampleWave(float position)
{
    float samplePosition = saturate(position) * 63.0;
    int first = (int)floor(samplePosition);
    int second = min(63, first + 1);
    return lerp(getWave(first), getWave(second), frac(samplePosition));
}

float reactiveWave(float position, float response)
{
    float wave = sampleWave(position);
    float shaped = pow(abs(wave), lerp(0.92, 0.58, saturate(response)));
    return wave < 0.0 ? -shaped : shaped;
}

float loopReactiveWave(float position, float response)
{
    // A scrolling capture is not naturally periodic. Interpolate across its
    // last/first samples too, with matching tangents on both sides of the join.
    float cursor = frac(position) * 64.0;
    int index = (int)floor(cursor);
    float t = frac(cursor);
    float a = getWave((index + 63) & 63);
    float b = getWave(index & 63);
    float c = getWave((index + 1) & 63);
    float d = getWave((index + 2) & 63);
    float value = 0.5 * ((2.0 * b) + (-a + c) * t +
        (2.0 * a - 5.0 * b + 4.0 * c - d) * t * t +
        (-a + 3.0 * b - 3.0 * c + d) * t * t * t);
    value = clamp(value, -1.0, 1.0);
    return sign(value) * pow(abs(value), lerp(0.92, 0.58, saturate(response)));
}

float smoothReactiveWave(float position, float response)
{
    float spacing = 1.0 / 63.0;
    float wave = sampleWave(saturate(position - spacing * 2.0)) * 0.10;
    wave += sampleWave(saturate(position - spacing)) * 0.22;
    wave += sampleWave(position) * 0.36;
    wave += sampleWave(saturate(position + spacing)) * 0.22;
    wave += sampleWave(saturate(position + spacing * 2.0)) * 0.10;
    float shaped = pow(abs(wave), lerp(0.96, 0.68, saturate(response)));
    return wave < 0.0 ? -shaped : shaped;
}

float audioCurve(float value, float gain)
{
    return 1.0 - exp(-max(0.0, value) * gain);
}

// Motion bands retain quiet notes around 0.04-0.12, not the old 0-1 energy range.
float noteMotion(float value)
{
    value = max(0.0, value);
    return value / (0.14 + value);
}

float3 palette(float value)
{
    float t = frac(value + Modes.w);
    float section = t * 4.0;
    float local = smoothstep(0.0, 1.0, frac(section));
    if (section < 1.0) return lerp(Palette0.rgb, Palette1.rgb, local);
    if (section < 2.0) return lerp(Palette1.rgb, Palette2.rgb, local);
    if (section < 3.0) return lerp(Palette2.rgb, Palette3.rgb, local);
    return lerp(Palette3.rgb, Palette0.rgb, local);
}

float lineGlow(float distanceToLine, float width)
{
    float core = exp(-distanceToLine * distanceToLine / max(0.00002, width * width));
    float halo = exp(-abs(distanceToLine) / max(0.0001, width * 4.5));
    return core + halo * 0.32;
}

float roundedBoxSdf(float2 position, float2 halfSize, float radius)
{
    float2 q = abs(position) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float segmentDistance(float2 samplePosition, float2 segmentStart, float2 segmentEnd)
{
    float2 edgeVector = segmentEnd - segmentStart;
    float edgeLengthSquared = max(0.000001, dot(edgeVector, edgeVector));
    float edgeAmount = saturate(dot(samplePosition - segmentStart, edgeVector) / edgeLengthSquared);
    return length(samplePosition - lerp(segmentStart, segmentEnd, edgeAmount));
}

float3 rotateX3(float3 position3, float angle)
{
    float sineAngle = sin(angle);
    float cosineAngle = cos(angle);
    return float3(
        position3.x,
        cosineAngle * position3.y - sineAngle * position3.z,
        sineAngle * position3.y + cosineAngle * position3.z);
}

float3 rotateY3(float3 position3, float angle)
{
    float sineAngle = sin(angle);
    float cosineAngle = cos(angle);
    return float3(
        cosineAngle * position3.x + sineAngle * position3.z,
        position3.y,
        -sineAngle * position3.x + cosineAngle * position3.z);
}

float2 projectPerspective(float3 position3, float focalLength)
{
    return position3.xy * focalLength / max(0.16, position3.z);
}

float reactiveTorusDistance(float3 position3, float bassDrive, float voiceDrive, float sparkleDrive, float timeValue)
{
    float azimuth = atan2(position3.z, position3.x);
    float majorRadius = 0.62 + bassDrive * 0.20;
    majorRadius += sin(azimuth * 5.0 - timeValue * 0.72) * voiceDrive * 0.090;
    float minorRadius = 0.145 + bassDrive * 0.070;
    minorRadius += sin(azimuth * 11.0 + timeValue * 1.15) * sparkleDrive * 0.036;
    float radialDistance = length(position3.xz) - majorRadius;
    return length(float2(radialDistance, position3.y)) - minorRadius;
}

float3 reactiveTorusNormal(float3 position3, float bassDrive, float voiceDrive, float sparkleDrive, float timeValue)
{
    const float normalStep = 0.004;
    float centerDistance = reactiveTorusDistance(position3, bassDrive, voiceDrive, sparkleDrive, timeValue);
    float3 normalVector = float3(
        reactiveTorusDistance(position3 + float3(normalStep, 0.0, 0.0), bassDrive, voiceDrive, sparkleDrive, timeValue) - centerDistance,
        reactiveTorusDistance(position3 + float3(0.0, normalStep, 0.0), bassDrive, voiceDrive, sparkleDrive, timeValue) - centerDistance,
        reactiveTorusDistance(position3 + float3(0.0, 0.0, normalStep), bassDrive, voiceDrive, sparkleDrive, timeValue) - centerDistance);
    return normalize(normalVector + 0.0001);
}

float2 kaleidoscope(float2 p, float sectors)
{
    float radius = length(p);
    float angle = atan2(p.y, p.x);
    float slice = TAU / max(3.0, sectors);
    angle = abs(fmod(angle + slice * 0.5, slice) - slice * 0.5);
    return float2(cos(angle), sin(angle)) * radius;
}

SceneResult makeScene(float3 color, float2 warp, float persistence)
{
    SceneResult result;
    result.color = color;
    result.warp = warp;
    result.persistence = persistence;
    return result;
}

SceneResult liquidGlass(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float bass = AudioA.y;
    float vocal = AudioB.x;
    float2 q = rotate2(p, sin(t * 0.09 + seed) * 0.35);
    float n1 = fbm(q * (1.45 + Feedback.z * 0.18) + float2(t * 0.055, -t * 0.041));
    float n2 = fbm(q * 2.2 + float2(n1 * 2.1, -n1 * 1.7) - t * 0.035);
    float field = n1 * 0.62 + n2 * 0.48 + length(q) * 0.21;
    float folds = pow(saturate(1.0 - abs(frac(field * (4.0 + vocal * 2.0)) - 0.5) * 2.0), 5.5);
    float edge = pow(saturate(1.0 - abs(frac(field * 9.0 + n2) - 0.5) * 2.0), 16.0);
    float glass = 0.12 + folds * (0.65 + AudioC.y * 0.8) + edge * (0.45 + AudioA.w);
    float3 color = palette(field + n2 * 0.35) * glass;
    color += palette(field + 0.48) * edge * AudioC.z * 0.9;
    float2 warp = float2(n2 - 0.5, n1 - 0.5) * (0.006 + bass * 0.009);
    warp += normalize(q + 0.001).yx * float2(1.0, -1.0) * AudioA.y * 0.0025;
    return makeScene(color, warp, 0.93);
}

SceneResult filamentKaleidoscope(float2 p, float seed)
{
    float low = getBand(2) / (0.12 + getBand(2));
    float middle = getBand(12) / (0.12 + getBand(12));
    float high = getBand(24) / (0.10 + getBand(24));
    float presence = saturate(AudioA.x * 1.5 + max(low, max(middle, high)) * 0.5);
    float t = Stage.x;
    float petals = 5.0 + floor(fmod(seed, 3.0));
    float2 center = float2(sin(t * 0.23), cos(t * 0.19)) * (0.05 + middle * 0.12);
    float2 q = rotate2(p - center, t * 0.16);
    float r = length(q);
    float a = atan2(q.y, q.x);
    // Smooth periodic sampling avoids hard spectrum boundaries and the atan seam.
    float position = (cos(a) * 0.5 + 0.5) * 30.0;
    int index = (int)floor(position);
    float band = lerp(getBand(index), getBand(min(31, index + 1)), smoothstep(0.0, 1.0, frac(position)));
    float local = band / (0.12 + band);
    float twist = a + sin(r * 2.4 - t * 0.7) * (0.12 + middle * 0.42);
    float lobes = cos(twist * petals + sin(r * 3.0 - t) * (0.18 + middle * 0.8));
    float breathingRadius = r / (1.0 + low * 0.32);
    float field = breathingRadius * 3.0 - t * 0.42;
    field += lobes * (0.18 + local * 0.46) * smoothstep(0.0, 0.45, r);
    field += sin(a * 3.0 - t * 0.55 + r * 2.0) * middle * 0.28;
    field += sin(r * 7.0 - t * 1.4 + cos(a * petals)) * high * 0.10;
    float phase = frac(field);
    float aa = max(fwidth(field), 0.001);
    float ribbon = smoothstep(0.13 - aa, 0.23 + aa, phase) *
        (1.0 - smoothstep(0.65 - aa, 0.77 + aa, phase));
    float edgeDistance = min(abs(phase - 0.23), abs(phase - 0.65));
    float contour = 1.0 - smoothstep(0.010, 0.022 + aa, edgeDistance);
    float hue = field * 0.13 + cos(a * 2.0) * 0.12 + Stage.y * 0.06;
    float3 vivid = 0.5 + 0.5 * cos(TAU * (hue + float3(0.0, 0.34, 0.67)));
    vivid = pow(saturate(vivid), 1.35);
    float3 alternate = 0.5 + 0.5 * cos(TAU * (hue + float3(0.44, 0.78, 0.11)));
    float relief = 0.45 + 0.55 * sin(phase * PI);
    float3 color = vivid * ribbon * relief * (0.035 + presence * 0.90);
    color += lerp(vivid, float3(0.9, 1.0, 0.94), 0.30) * contour * (0.025 + presence * 0.65);
    float undercurrent = pow(0.5 + 0.5 * sin(field * PI + lobes), 3.0);
    color += alternate * undercurrent * (0.008 + presence * 0.12) * (1.0 - ribbon);
    color *= smoothstep(0.025, 0.17, r);
    return makeScene(color, 0.0, 0.35);
}

SceneResult volumetricTunnel(float2 p, float seed)
{
    float t = Stage.x;
    float low = noteMotion(AudioA.y);
    float mid = noteMotion(AudioB.x);
    float high = noteMotion(AudioA.w);
    float presence = max(low, max(mid, high));
    float2 center = float2(sin(t * 0.24) * 0.16, cos(t * 0.19) * 0.10) * mid;
    p = rotate2(p - center, sin(t * 0.35) * 0.12 + mid * 0.18);
    p *= 1.12 - low * 0.38;
    float3 rayOrigin = float3(sin(t * 0.17) * 0.08, cos(t * 0.13) * 0.08, t * 1.2);
    float3 rayDirection = normalize(float3(p, 1.38));
    float travel = 0.05;
    float3 glow = 0.0;
    [loop]
    for (int i = 0; i < 26; i++)
    {
        float3 position = rayOrigin + rayDirection * travel;
        float angle = atan2(position.y, position.x);
        float band = noteMotion(getBand((i * 5 + (int)seed) & 31));
        float radius = 0.60 + low * 0.16 + sin(position.z * 1.8 + angle * (4.0 + floor(fmod(seed, 4.0))) + mid * 1.1) * (0.04 + band * 0.22);
        float wall = abs(length(position.xy) - radius);
        float filament = exp(-wall * (23.0 + AudioB.x * 15.0));
        filament *= 0.5 + 0.5 * pow(abs(sin(angle * Presets.z + position.z * 2.2)), 7.0);
        glow += palette(angle / TAU + position.z * 0.075) * filament * (0.014 + presence * 0.065 + band * 0.025);
        travel += 0.075 + wall * 0.24;
    }
    glow *= 2.2 + low * 2.0 + high * 0.7;
    float screenRadius = max(0.045, length(p));
    float screenAngle = atan2(p.y, p.x);
    float depthRings = pow(saturate(1.0 - abs(sin((3.4 + low * 0.9) / (screenRadius + 0.11) - t * 2.0)) * 1.22), 7.0);
    float spokes = pow(saturate(1.0 - abs(sin(screenAngle * Presets.z + 2.1 / (screenRadius + 0.16) + mid * 1.6)) * 1.35), 9.0);
    float tunnelMask = smoothstep(1.72, 0.05, screenRadius);
    glow += palette(screenAngle / TAU + 1.0 / (screenRadius + 0.2) * 0.12) *
        (depthRings * (0.012 + low * 0.60) + spokes * (0.005 + high * 0.46)) * tunnelMask;
    float2 warp = normalize(p + 0.001).yx * float2(-1.0, 1.0) * (0.002 + AudioA.y * 0.004);
    warp -= normalize(p + 0.001) * (0.0015 + AudioC.x * 0.006);
    return makeScene(glow, warp, 0.94);
}

SceneResult plasmaNebula(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float v = saturate(p.y * 0.5 + 0.5);
    float energy = audioCurve(AudioA.x + AudioC.w * 0.45, 1.58);
    float bassDrive = audioCurve(AudioA.y + AudioC.x * 0.78 + AudioB.w * 0.26, 1.72);
    float vocalDrive = audioCurve(AudioB.x + AudioC.y * 0.58, 1.55);
    float trebleDrive = audioCurve(AudioA.w + AudioC.z * 0.64, 1.52);

    float horizontalWave = smoothReactiveWave(u, AudioB.x + AudioC.y);
    float verticalWave = smoothReactiveWave(v, AudioA.y + AudioC.x);
    float breathingScale = 1.25 * (1.0 - bassDrive * 0.075 - AudioB.w * 0.018);
    float2 q = rotate2(p * breathingScale, sin(t * 0.045 + seed * 0.19) * (0.045 + vocalDrive * 0.035));
    q += float2(verticalWave, horizontalWave) * (0.018 + vocalDrive * 0.060 + AudioC.y * 0.018);

    float slowBandPressure = (getBand(5) - getBand(21)) * 0.055;
    float2 pressureCenter = float2(
        sin(t * 0.055 + seed) * aspect * 0.34,
        cos(t * 0.043 + seed * 0.71) * 0.30);
    float2 pressureDelta = q - pressureCenter;
    float pressureInfluence = exp(-dot(pressureDelta, pressureDelta) * 1.65);
    q = pressureCenter + rotate2(pressureDelta, pressureInfluence * vocalDrive * (0.08 + AudioC.y * 0.08));
    q += normalize(pressureDelta + 0.001) * pressureInfluence * slowBandPressure * (0.38 + bassDrive * 0.32);

    float n1 = fbm(q * (1.76 + vocalDrive * 0.08) + float2(t * 0.042, -t * 0.032));
    float flowNoise = fbm(q * 1.68 + float2(-t * 0.026, t * 0.019));
    float2 foldedQ = q + float2(n1 - 0.5, flowNoise - 0.5) *
        (0.76 + bassDrive * 0.30 + vocalDrive * 0.16);
    float n2 = fbm(foldedQ * (2.24 + trebleDrive * 0.10) + seed * 0.013);
    float n3 = fbm(float2(foldedQ.y, -foldedQ.x) * 1.66 + float2(-t * 0.021, t * 0.017));
    float pressure = horizontalWave * vocalDrive * 0.022 + slowBandPressure * 0.18;
    float ridgeCenter = 0.50 + pressure;
    float ridge = pow(saturate(1.0 - abs(n2 - ridgeCenter) * (3.55 - bassDrive * 0.34)), 3.35 - energy * 0.24);
    float innerFold = pow(saturate(1.0 - abs(n3 - n1 * 0.72) * (4.5 - vocalDrive * 0.38)), 4.8);
    float lightning = pow(saturate(1.0 - abs(n2 - n1) * (5.9 - trebleDrive * 0.62)), 15.5 - trebleDrive * 1.5);
    float membrane = pow(saturate(1.0 - abs(n2 + n3 * 0.38 - 0.70 - pressure) * 4.3), 3.8);

    float3 color = palette(n1 * 0.64 + n2 * 0.48 + t * 0.014) * ridge * (0.20 + energy * 0.46 + AudioA.z * 0.34);
    color += palette(n3 * 0.72 + n1 * 0.25 + 0.41) * innerFold * (0.055 + vocalDrive * 0.33 + AudioC.y * 0.21);
    color += palette(n2 + Motion.x * 0.18 + 0.68) * lightning * (0.16 + trebleDrive * 0.72 + AudioC.z * 0.54);
    color += palette(n1 - n3 * 0.24 + 0.12) * membrane * (0.055 + bassDrive * 0.19);

    float bassFront = frac(Motion.w * 0.125 + seed * 0.013) * 1.65;
    float deformationFront = lineGlow(abs(q.x) + abs(q.y) - bassFront, 0.014 + bassDrive * 0.014);
    color += palette(bassFront * 0.24 + t * 0.018) * deformationFront * AudioC.x * (0.035 + bassDrive * 0.10);
    color *= 1.02 + energy * 0.28;

    float2 warp = float2(n2 - 0.5, n1 - 0.5) * (0.0045 + AudioC.w * 0.007 + vocalDrive * 0.002);
    warp += normalize(q + 0.001).yx * float2(-1.0, 1.0) * bassDrive * 0.0008;
    return makeScene(color, warp, 0.944);
}

SceneResult crystalMirror(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float bassDrive = audioCurve(AudioA.y + AudioC.x * 0.9, 1.8);
    float vocalDrive = audioCurve(AudioB.x + AudioC.y * 0.7, 1.65);
    float horizon = -0.12 + sin(t * 0.19 + seed) * 0.05;
    float3 color = 0.0;

    float sky = fbm(float2(p.x * 0.42 + t * 0.052, p.y * 0.78 - t * 0.026) + seed * 0.02);
    float skyBand = pow(saturate(1.0 - abs(sky - 0.53) * 3.7), 3.0);
    float skyMask = smoothstep(horizon - 0.08, 0.92, p.y);
    color += palette(sky * 0.38 + u * 0.16) * skyBand * skyMask * (0.050 + AudioA.x * 0.13);

    float canopyWave = loopReactiveWave(u + t * 0.024, AudioA.x + AudioB.x);
    float canopyY = 0.46 + canopyWave * (0.10 + vocalDrive * 0.15) + sin(p.x * 1.45 - t * 0.36) * 0.10;
    float canopy = exp(-abs(p.y - canopyY) * (3.8 - bassDrive * 0.8)) * skyMask;
    float canopyEdge = lineGlow(p.y - canopyY, 0.026 + AudioA.w * 0.012);
    color += palette(u * 0.38 + t * 0.025 + 0.54) *
        (canopy * (0.028 + AudioA.x * 0.085) + canopyEdge * (0.035 + AudioC.z * 0.14));

    [unroll]
    for (int i = 0; i < 16; i++)
    {
        float fi = i / 15.0;
        float band = getBand(i * 4);
        float barActivation = smoothstep(0.045, 0.15, band);
        float x = -aspect + fi * aspect * 2.0 + stereoPan(fi) * band * 0.09;
        float height = barActivation * (0.07 + band * (0.86 + vocalDrive * 0.52) + bassDrive * 0.12);
        height = min(height, 1.18);
        float width = aspect / 20.5;
        float column = smoothstep(width, width * 0.28, abs(p.x - x));
        float body = barActivation * column * smoothstep(horizon - 0.025, horizon + 0.035, p.y) *
            smoothstep(horizon + height + 0.04, horizon + height - 0.015, p.y);
        float cap = barActivation * lineGlow(p.y - horizon - height, 0.006 + band * 0.006) * column;
        float reflection = barActivation * lineGlow(p.y - horizon + height * 0.55, 0.012 + band * 0.012) * column;
        float pulse = 0.58 + 0.42 * sin(t * (1.35 + Motion.y * 2.3) - fi * 8.0 + Motion.x * TAU);
        color += palette(fi * 0.72 + t * 0.018) * (body * (0.10 + band * 0.20) + cap * (0.34 + band * 1.04) * pulse);
        color += palette(fi * 0.72 + 0.42) * reflection * (0.055 + bassDrive * 0.13);
    }

    float floorDepth = 1.0 / max(0.08, horizon - p.y + 0.16);
    float floorGrid = lineGlow(abs(frac(floorDepth * 0.35 - t * 0.22) - 0.5) - 0.47, 0.018);
    floorGrid *= smoothstep(horizon + 0.02, -1.0, p.y);
    color += palette(floorDepth * 0.08 + u * 0.12) * floorGrid * (0.035 + bassDrive * 0.12);

    [unroll]
    for (int waveIndex = 0; waveIndex < 3; waveIndex++)
    {
        float waveDepth = waveIndex / 2.0;
        float movingWave = loopReactiveWave(u + t * (0.015 + waveIndex * 0.005) + waveDepth * 0.08, AudioB.x + AudioC.y);
        float sideEnergy = lerp(Stereo.x, Stereo.y, u);
        float waveY = horizon + 0.34 + waveDepth * (0.28 + Stereo.w * 0.13) + movingWave * (0.18 + vocalDrive * 0.34 + sideEnergy * 0.20);
        float waveWidth = max(0.008 + waveDepth * 0.008 + AudioA.w * 0.003, fwidth(p.y - waveY) * 0.65);
        float waveGlow = lineGlow(p.y - waveY, waveWidth);
        color += palette(u * 0.34 + waveDepth * 0.18 + t * 0.028 + 0.17) * waveGlow *
            (0.13 - waveDepth * 0.014 + AudioB.x * 0.38 + AudioC.z * 0.22);
    }

    color *= 2.15 + AudioA.x * 0.55;
    float2 warp = float2(-0.0009 - AudioA.y * 0.0014, reactiveWave(u, AudioA.x + AudioB.x) * (0.0005 + AudioC.w * 0.0012));
    return makeScene(color, warp, 0.932);
}

SceneResult ribbonCanyon(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float energy = audioCurve(AudioA.x + AudioC.w * 0.52, 1.76);
    float kick = audioCurve(AudioA.y + AudioC.x * 1.25 + AudioB.w * 0.52, 2.05);
    float voice = audioCurve(AudioB.x + AudioC.y * 0.82, 1.72);
    float sparkle = audioCurve(AudioA.w + AudioC.z * 0.95, 1.72);
    float2 vanishing = float2(
        sin(t * 0.31 + seed) * aspect * (0.055 + voice * 0.035),
        cos(t * 0.23 + seed * 0.61) * (0.045 + voice * 0.030));
    float roll = sin(t * 0.27 + seed * 0.31) * (0.10 + voice * 0.10) + AudioC.x * 0.055;
    float2 q = rotate2(p - vanishing, roll);
    float3 color = 0.0;

    float backdrop = fbm(float2(q.x * 0.52 + t * 0.070, q.y * 1.05 - t * 0.046) + seed * 0.018);
    float veil = pow(saturate(1.0 - abs(backdrop - 0.52) * 3.7), 2.6);
    color += palette(backdrop * 0.48 + length(q) * 0.09 + t * 0.012) * veil * (0.050 + energy * 0.115);

    float radius = max(0.025, length(q * float2(1.0 / aspect, 1.0)));
    float angle = atan2(q.y, q.x) / TAU + 0.5;
    float2 starCoordinate = float2(angle * 132.0, log(radius + 0.09) * 34.0 - t * (2.8 + Motion.y * 3.4 + energy * 1.6));
    float2 starCell = floor(starCoordinate);
    float2 starLocal = frac(starCoordinate) - 0.5;
    float starSeed = hash21(starCell + seed);
    float stars = pow(starSeed, 56.0) * exp(-dot(starLocal * float2(5.0, 0.82), starLocal * float2(5.0, 0.82)) * 38.0);
    color += palette(starSeed + angle + t * 0.028) * stars * (0.14 + sparkle * 0.90 + AudioB.w * 0.32);

    [unroll]
    for (int prismIndex = 0; prismIndex < 12; prismIndex++)
    {
        float layer = prismIndex / 11.0;
        float travel = frac(t * (0.125 + Motion.y * 0.105 + energy * 0.030) + layer + seed * 0.004);
        float depth = pow(travel, 1.48);
        float scale = 0.065 + depth * 1.42;
        float band = getBand((prismIndex * 5 + 2) & 31);
        float laneAngle = seed * 0.017 + prismIndex * 2.399 + sin(t * (0.34 + layer * 0.11) + prismIndex) * (0.22 + voice * 0.34);
        float laneRadius = 0.22 + hash11(prismIndex * 7.1 + seed) * 0.34 + smoothReactiveWave(layer, voice + band) * 0.055;
        float2 lane = float2(cos(laneAngle), sin(laneAngle)) * float2(aspect * laneRadius, laneRadius * 0.82);
        float2 projectedCenter = vanishing + lane * depth;
        float objectRotation = laneAngle + t * (0.42 + Motion.y * 0.58) * (prismIndex & 1 ? 1.0 : -1.0);
        objectRotation += band * 0.72 + Motion.x * kick * 0.42;
        float2 local = rotate2((p - projectedCenter) / scale, objectRotation);

        float2 halfSize = float2(0.13 + band * 0.13 + kick * 0.025, 0.037 + voice * 0.035 + band * 0.018);
        float prismDistance = roundedBoxSdf(local, halfSize, 0.012 + voice * 0.010);
        float rim = lineGlow(prismDistance, 0.009 + band * 0.006);
        float fill = smoothstep(0.018, -0.018, prismDistance);
        float diagonal = lineGlow(local.y - local.x * (0.18 + band * 0.22), 0.010) * fill;
        float layerFade = smoothstep(0.02, 0.11, travel) * smoothstep(0.995, 0.80, travel);
        float shimmer = 0.68 + 0.32 * sin(t * (2.1 + Motion.y * 2.2) + prismIndex * 1.4 + Motion.x * TAU);
        float3 prismColor = palette(layer * 0.72 + band * 0.20 + t * 0.030);
        color += prismColor * rim * layerFade * shimmer * (0.12 + band * 0.64 + energy * 0.22);
        color += prismColor * fill * layerFade * (0.018 + band * 0.060 + kick * 0.042);
        color += lerp(prismColor, Palette3.rgb, 0.68) * diagonal * layerFade * (0.035 + sparkle * 0.24);

        float2 ray = projectedCenter - vanishing;
        float rayLength = max(0.001, length(ray));
        float2 rayDirection = ray / rayLength;
        float2 fromOrigin = p - vanishing;
        float alongRay = dot(fromOrigin, rayDirection);
        float acrossRay = abs(fromOrigin.x * rayDirection.y - fromOrigin.y * rayDirection.x);
        float trail = lineGlow(acrossRay, 0.0025 + band * 0.0030) * step(0.0, alongRay) * step(alongRay, rayLength) * layerFade;
        trail *= pow(saturate(alongRay / rayLength), 2.6);
        color += prismColor * trail * (0.025 + sparkle * 0.13 + AudioC.z * 0.12);
    }

    float shockDistance = abs(q.x) + abs(q.y) - frac(Motion.w * 0.25 + seed * 0.011) * 1.85;
    float shock = lineGlow(shockDistance, 0.014 + kick * 0.024);
    color += palette(t * 0.052 + 0.62) * shock * AudioC.x * (0.12 + kick * 0.32);
    color *= 1.35 + energy * 0.38 + sparkle * 0.12;
    float2 warp = normalize(q + 0.001) * (-0.0022 - kick * 0.0045);
    warp += float2(backdrop - 0.5, smoothReactiveWave(saturate(angle), voice)) * (0.0010 + AudioC.w * 0.0028);
    return makeScene(color, warp, 0.882);
}

SceneResult electricLattice(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float v = saturate(p.y * 0.5 + 0.5);
    float drive = audioCurve(AudioA.x + AudioC.x * 1.35 + AudioB.w * 0.55, 1.55);
    float waveX = reactiveWave(v, AudioB.x + AudioC.y);
    float waveY = reactiveWave(u, AudioA.y + AudioC.x);
    float2 q = rotate2(p, sin(t * 0.24 + seed) * (0.17 + AudioB.x * 0.12));
    q += float2(
        sin(q.y * 3.2 + t * (1.05 + Motion.y)) + waveX * 0.75,
        cos(q.x * 2.8 - t * (0.92 + Motion.y * 0.8)) + waveY * 0.72) * (0.045 + drive * 0.115);
    q *= 5.2 + Motion.y * 1.8;
    float2 grid = abs(frac(q) - 0.5);
    float gx = lineGlow(grid.x - 0.49, 0.010 + AudioB.x * 0.010);
    float gy = lineGlow(grid.y - 0.49, 0.010 + AudioA.w * 0.010);
    float node = exp(-dot(grid, grid) * (75.0 - drive * 30.0));
    float cellPhase = floor(q.x) * 0.63 + floor(q.y) * 1.17;
    float pulse = pow(saturate(0.5 + 0.5 * sin(cellPhase - t * (4.2 + Motion.y * 3.6) + Motion.x * TAU)), 5.0);
    float3 color = palette((q.x + q.y) * 0.045 + t * 0.025) * ((gx + gy) * (0.12 + AudioA.z * 0.50 + drive * 0.14));
    color += palette(cellPhase * 0.06 + t * 0.04) * node * pulse * (0.24 + AudioC.y * 0.85 + AudioC.z * 0.65);

    float field = fbm(float2(p.x * 0.56 + t * 0.075, p.y * 1.2 - t * 0.038) + seed * 0.012);
    float current = pow(saturate(1.0 - abs(field - 0.52) * 5.2), 3.0);
    color += palette(field * 0.46 + u * 0.16) * current * (0.022 + AudioA.x * 0.075);
    float shockRadius = frac(t * (0.28 + Motion.y * 0.24) + seed * 0.01) * 1.65;
    float shock = lineGlow(length(p - float2(sin(seed) * 0.23, cos(seed) * 0.14)) - shockRadius, 0.013 + AudioC.x * 0.018);
    color += palette(t * 0.055 + shockRadius) * shock * AudioC.x * 0.42;

    float2 warp = sin(q.yx * 0.7 + t * 1.5) * (0.0016 + AudioC.w * 0.0055 + AudioC.x * 0.002);
    return makeScene(color, warp, 0.902);
}

struct PrismHit
{
    float distance;
    float3 color;
};

float concertoHeight(float value)
{
    value = saturate(value);
    float note = value / (0.14 + value);
    // Preserve the existing low-level response, then open up space for stronger peaks.
    return 0.075 + pow(note, 0.9) * 4.6 + 2.4 * pow(value, 1.6);
}

PrismHit traceConcerto(float3 origin, float3 ray, float limit, float travel)
{
    PrismHit result;
    result.distance = limit;
    result.color = 0.0;
    float3 hitPosition = 0.0;
    float3 hitSize = 1.0;
    float hitYaw = 0.0;
    float hitNote = 0.0;
    float hitHue = 0.0;
    bool hitPlate = false;
    bool found = false;
    // Analytic intersections: real depth/occlusion without an expensive ray march.
    [loop]
    for (int objectIndex = 0; objectIndex < 48; objectIndex++)
    {
        int i = objectIndex / 2;
        bool plate = (objectIndex & 1) != 0;
        float u = i / 23.0;
        float note = noteMotion(getBand((int)round(u * 31.0)));
        float height = concertoHeight(getBand((int)round(u * 31.0)));
        float x = (u - 0.5) * 9.2;
        float z = 0.8 * cos(x * 0.55) + sin(x * 0.65 + travel * 0.24) * note * 0.42 + stereoPan(u) * note * 0.65;
        float yaw = sin(x * 0.43 + travel * 0.19) * (0.06 + note * 0.55);
        float3 halfSize = float3(0.126 + note * 0.018, height * 0.5, 0.28 + note * 0.13);
        float3 center = float3(x, halfSize.y + 0.025, z);
        float peakHeight = max(height + 0.025, getBand(32 + i));
        if (plate)
        {
            halfSize = float3(halfSize.x + 0.018, 0.032, halfSize.z + 0.018);
            center.y = peakHeight + 0.042;
        }
        float3 localOrigin = rotateY3(origin - center, -yaw);
        float3 localRay = rotateY3(ray, -yaw);
        float3 inverseRay = (step(0.0, localRay) * 2.0 - 1.0) / max(abs(localRay), 0.00001);
        float3 a = (-halfSize - localOrigin) * inverseRay;
        float3 b = (halfSize - localOrigin) * inverseRay;
        float3 nearPlane = min(a, b);
        float3 farPlane = max(a, b);
        float enter = max(nearPlane.x, max(nearPlane.y, nearPlane.z));
        float leave = min(farPlane.x, min(farPlane.y, farPlane.z));
        if (enter > 0.0 && enter < leave && enter < result.distance)
        {
            found = true;
            result.distance = enter;
            hitPosition = localOrigin + localRay * enter;
            hitSize = halfSize;
            hitYaw = yaw;
            hitNote = plate ? saturate((peakHeight - 0.1) / 6.5) : note;
            hitHue = u * 0.76;
            hitPlate = plate;
        }
    }
    if (found)
    {
        float3 inset = max(0.0, hitSize - abs(hitPosition));
        float3 normal;
        float edge;
        if (inset.x < inset.y && inset.x < inset.z)
        {
            normal = float3(sign(hitPosition.x), 0, 0);
            edge = min(inset.y, inset.z);
        }
        else if (inset.y < inset.z)
        {
            normal = float3(0, sign(hitPosition.y), 0);
            edge = min(inset.x, inset.z);
        }
        else
        {
            normal = float3(0, 0, sign(hitPosition.z));
            edge = min(inset.x, inset.y);
        }
        normal = rotateY3(normal, hitYaw);
        float3 light = normalize(float3(-0.5, 0.85, -0.6));
        float diffuse = max(0.0, dot(normal, light));
        float gloss = pow(max(0.0, dot(reflect(-light, normal), -ray)), 42.0);
        float fresnel = pow(1.0 - abs(dot(normal, -ray)), 3.0);
        float edgeLight = exp(-edge / 0.016);
        float v = saturate(hitPosition.y / (hitSize.y * 2.0) + 0.5);
        float3 tint = palette(hitHue + v * 0.12);
        tint = max(0.0, lerp(dot(tint, float3(0.2126, 0.7152, 0.0722)).xxx, tint, 1.45));
        float3 capTint = lerp(tint, float3(0.85, 0.95, 1.0), 0.18);
        float horizontalEtch = pow(0.5 + 0.5 * cos(v * hitSize.y * 48.0), 16.0);
        float core = exp(-abs(hitPosition.x) * 36.0) * (1.0 - abs(normal.y));
        result.color = tint * (0.055 + hitNote * 0.68) * (0.35 + diffuse * 0.9 + fresnel * 0.5);
        result.color += tint * horizontalEtch * hitNote * 0.20;
        result.color += tint * core * hitNote * (0.35 + v * 0.7);
        result.color += capTint * (edgeLight * (0.055 + hitNote * 1.7) + gloss * hitNote * 0.65);
        result.color += capTint * max(0.0, normal.y) * hitNote * 0.45;
        if (hitPlate)
        {
            // A luminous solid plate, not a broad bloom that obscures its silhouette.
            result.color = tint * (0.065 + hitNote * 0.85) * (0.55 + diffuse * 0.6);
            result.color += capTint * (0.04 + hitNote * 0.85) * edgeLight;
            result.color += capTint * gloss * hitNote * 0.3;
        }
    }
    return result;
}

SceneResult prismConcerto(float2 p, float seed)
{
    float travel = Stage.x;
    float low = noteMotion(AudioA.y);
    float mid = noteMotion(AudioB.x);
    float high = noteMotion(AudioA.w);
    float active = max(low, max(mid, high));
    float yaw = sin(travel * 0.13 + seed * 0.01) * 0.22;
    float tallest = 0.0;
    [unroll]
    for (int cap = 0; cap < 24; cap++) tallest = max(tallest, getBand(32 + cap));
    // Falling peak markers provide a stable framing envelope instead of zoom jitter.
    float headroom = smoothstep(4.0, 6.6, tallest);
    float distance = lerp(8.6, 10.0, headroom);
    float3 origin = float3(sin(yaw) * distance, 3.4 + headroom * 0.6 + low * 0.5, -cos(yaw) * distance);
    float3 forward = normalize(float3(0.0, 1.05 + headroom * 1.35 + low * 0.25, 0.5) - origin);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float3 ray = normalize(forward * lerp(1.8, 1.55, headroom) + right * p.x - up * p.y);
    float floorDistance = ray.y < -0.0001 ? -origin.y / ray.y : 1000.0;
    PrismHit hit = traceConcerto(origin, ray, min(1000.0, floorDistance), travel);
    float3 color = palette(0.56 + p.x * 0.025) * (0.004 + active * 0.014);
    if (hit.distance < min(1000.0, floorDistance))
        color = hit.color;
    else if (floorDistance < 40.0)
    {
        float3 floorPosition = origin + ray * floorDistance;
        float3 reflectionRay = reflect(ray, float3(0, 1, 0));
        PrismHit reflection = traceConcerto(floorPosition + float3(0, 0.002, 0), reflectionRay, 24.0, travel);
        float reflectionFade = exp(-reflection.distance * 0.095) * (0.2 + active * 0.24);
        color += reflection.color * reflectionFade;
        float2 cell = abs(frac(floorPosition.xz * 0.5 + 0.5) - 0.5);
        float gridDistance = min(cell.x, cell.y);
        float grid = 1.0 - smoothstep(0.003, 0.014, gridDistance);
        float fade = exp(-length(floorPosition.xz) * 0.20);
        color += palette(0.4 + floorPosition.x * 0.04) * grid * fade * (0.006 + active * 0.035);
        // Narrow pools of matching light anchor each independently moving prism.
        float nearest = clamp(round((floorPosition.x / 9.2 + 0.5) * 23.0), 0.0, 23.0);
        float u = nearest / 23.0;
        float note = noteMotion(getBand((int)round(u * 31.0)));
        float x = (u - 0.5) * 9.2;
        float z = 0.8 * cos(x * 0.55) + sin(x * 0.65 + travel * 0.24) * note * 0.42;
        float2 footprint = (floorPosition.xz - float2(x, z)) * float2(3.8, 1.3);
        color += palette(u * 0.76) * exp(-dot(footprint, footprint) * 2.5) * note * 0.30;
    }
    float vignette = 1.0 - smoothstep(1.25, 2.65, length(p)) * 0.28;
    return makeScene(color * vignette, float2(0, 0), 0.0);
}

SceneResult fibonacciShell(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float bassDrive = audioCurve(AudioA.y + AudioC.x * 0.95, 1.75);
    float vocalDrive = audioCurve(AudioB.x + AudioC.y * 0.72, 1.65);
    float trebleDrive = audioCurve(AudioA.w + AudioC.z * 0.90, 1.55);
    float levelDrive = audioCurve(AudioA.x + AudioC.w * 0.55, 1.45);

    float2 center = float2(
        sin(t * 0.16 + seed) * (0.18 + vocalDrive * 0.07),
        cos(t * 0.12 + seed * 0.7) * (0.11 + bassDrive * 0.05));
    float2 q = rotate2(p - center, sin(t * 0.075 + seed * 0.31) * 0.24);
    float rawRadius = max(0.025, length(q));
    float angle = atan2(q.y, q.x);
    float anglePosition = frac(angle / TAU + 0.5);
    float circularAudioPosition = 1.0 - abs(anglePosition * 2.0 - 1.0);
    int bandIndex = (int)clamp(floor(circularAudioPosition * 31.0), 0.0, 31.0);
    float band = getBand(bandIndex);
    float oppositeBand = getBand(31 - bandIndex);
    float waveform = reactiveWave(circularAudioPosition, AudioA.x + AudioB.x + AudioC.y);

    float beatExpansion = 1.0 + bassDrive * 0.18 + AudioB.w * 0.11;
    float radius = rawRadius / beatExpansion;
    radius += waveform * (0.022 + vocalDrive * 0.070) * smoothstep(0.05, 1.35, rawRadius);

    float rotation = t * (0.52 + Motion.y * 0.40) + Motion.w * 0.055;
    float spiralPhase = angle * 3.0 - log(radius + 0.055) * 7.1 + rotation;
    spiralPhase += waveform * (0.72 + vocalDrive * 2.45);
    spiralPhase += (band - 0.35) * (0.42 + AudioC.y * 1.15);

    float spiralDistance = abs(sin(spiralPhase));
    float shellBody = pow(saturate(1.0 - spiralDistance), 3.2 - bassDrive * 0.75);
    float shellCore = pow(saturate(1.0 - spiralDistance), 12.0 - vocalDrive * 3.0);
    float shellRim = exp(-abs(spiralDistance - 0.20) * (17.0 - bassDrive * 3.0));
    float tubeLight = 0.58 + 0.42 * cos(spiralPhase + log(radius + 0.08) * 1.6 - t * 0.45);

    float rearPhase = angle * 3.0 - log(radius + 0.13) * 7.1 + rotation * 0.82 + 1.15;
    rearPhase -= waveform * (0.38 + vocalDrive * 1.10);
    float rearDistance = abs(sin(rearPhase));
    float rearRibbon = pow(saturate(1.0 - rearDistance), 4.8);

    float chamberPhase = log(radius + 0.065) * 13.5 + angle * 2.0 - t * (0.88 + Motion.y * 0.72);
    chamberPhase += oppositeBand * 1.15 + waveform * vocalDrive * 1.6;
    float chamberDistance = abs(sin(chamberPhase));
    float chamberBody = pow(saturate(1.0 - chamberDistance), 5.5);
    float nodes = pow(saturate(shellCore * chamberBody), 0.58);

    float swirlNoise = fbm(rotate2(q * (0.78 + levelDrive * 0.16), sin(angle * 2.0) * 0.22) +
        float2(t * 0.048, -t * 0.036) + seed * 0.017);
    float fogRibbon = pow(saturate(1.0 - abs(swirlNoise - 0.52) * 3.2), 2.5);
    float vignette = smoothstep(2.12, 0.08, rawRadius);
    float3 color = palette(swirlNoise * 0.46 + anglePosition * 0.22 + t * 0.014) *
        fogRibbon * vignette * (0.032 + levelDrive * 0.105 + bassDrive * 0.045);

    float3 shellColor = palette(anglePosition * 0.72 - log(radius + 0.08) * 0.12 + t * 0.026);
    float shellEnergy = shellBody * (0.19 + band * 0.54 + levelDrive * 0.24);
    shellEnergy += shellRim * (0.12 + vocalDrive * 0.30);
    shellEnergy += shellCore * (0.48 + band * 1.18 + AudioB.w * 0.92) * tubeLight;
    color += shellColor * shellEnergy * vignette;
    color += palette(anglePosition + 0.43) * rearRibbon * vignette * (0.10 + oppositeBand * 0.38);
    color += palette(radius * 0.46 + anglePosition + 0.18) * chamberBody * vignette *
        (0.065 + vocalDrive * 0.28 + AudioC.y * 0.20);
    color += palette(anglePosition + t * 0.04 + 0.65) * nodes *
        (0.16 + trebleDrive * 0.62 + AudioC.z * 0.70);

    float waveformRadius = 0.60 + bassDrive * 0.19 + waveform * (0.15 + vocalDrive * 0.27);
    waveformRadius += sin(angle * 2.0 - t * 0.68) * AudioA.z * 0.055;
    float waveformGlow = lineGlow(rawRadius - waveformRadius, 0.012 + levelDrive * 0.014);
    color += palette(anglePosition + t * 0.045 + 0.28) * waveformGlow *
        (0.20 + levelDrive * 0.42 + vocalDrive * 0.68 + AudioC.y * 0.48);

    float shockRadius = frac(Motion.w * 0.25 + seed * 0.013) * 1.70;
    float shockWave = lineGlow(rawRadius - shockRadius, 0.012 + AudioC.x * 0.025);
    color += palette(anglePosition + shockRadius * 0.30 + t * 0.025) * shockWave *
        AudioC.x * (0.45 + bassDrive * 0.82);

    float sparkCells = hash21(floor(float2(anglePosition * 144.0 - t * (4.0 + trebleDrive * 8.0),
        log(rawRadius + 0.07) * 34.0)) + seed);
    float sparks = pow(sparkCells, 48.0) * (shellBody * 0.65 + chamberBody * 0.35);
    color += palette(anglePosition + 0.82) * sparks * (0.28 + trebleDrive * 1.65 + AudioC.z * 1.25);

    color *= 1.34 + levelDrive * 0.48;
    float2 tangent = normalize(q + 0.001).yx * float2(-1.0, 1.0);
    float2 warp = tangent * (0.0018 + bassDrive * 0.0048);
    warp -= normalize(q + 0.001) * (0.0012 + AudioC.x * 0.0042);
    return makeScene(color, warp, 0.928);
}

SceneResult risingFlame(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float drive = audioCurve(AudioA.x + AudioA.y * 0.7 + AudioC.x, 1.45);
    float3 color = 0.0;
    float skyNoise = fbm(float2(p.x * 0.55 + t * 0.055, p.y * 0.9 - t * 0.075) + seed * 0.016);
    float sky = pow(saturate(1.0 - abs(skyNoise - 0.50) * 3.8), 2.5);
    color += palette(skyNoise * 0.45 + p.y * 0.09) * sky * (0.060 + AudioA.x * 0.135);

    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float fi = i / 8.0;
        float band = getBand(2 + i * 3);
        float wave = reactiveWave(frac(u + fi * 0.11 + t * 0.018), band + AudioB.x);
        float flowNoise = noise21(float2(p.y * 1.8 - t * (0.42 + Motion.y * 0.34), i * 2.7 + seed));
        float center = (-0.96 + fi * 1.92) * aspect;
        center += sin(p.y * (1.5 + fi) + t * (0.62 + fi * 0.25) + seed) * (0.10 + band * 0.13);
        center += (flowNoise - 0.5) * (0.20 + drive * 0.18) + wave * (0.06 + band * 0.08);
        float distanceToCurtain = abs(p.x - center);
        float spine = lineGlow(distanceToCurtain, 0.012 + band * 0.018);
        float curtain = exp(-distanceToCurtain * (4.2 - drive * 1.1));
        float ghost = lineGlow(distanceToCurtain - (0.075 + band * 0.045), 0.028 + band * 0.012);
        float verticalFade = 0.38 + 0.62 * smoothstep(1.15, -0.75, p.y);
        float flicker = 0.72 + 0.28 * sin(t * (2.2 + Motion.y * 2.0) + p.y * 5.0 + i);
        color += palette(fi * 0.68 + p.y * 0.10 + t * 0.020) *
            (spine * (0.28 + band * 0.82 + AudioB.x * 0.32) + curtain * (0.042 + drive * 0.082) + ghost * (0.026 + AudioB.x * 0.055)) * verticalFade * flicker;
    }

    float backgroundWave = reactiveWave(frac(u + t * 0.021), AudioB.x + AudioC.y);
    float backgroundY = sin(t * 0.26 + seed) * 0.30 + backgroundWave * (0.15 + AudioB.x * 0.17);
    color += palette(u * 0.31 + t * 0.018 + 0.48) * lineGlow(p.y - backgroundY, 0.024) * (0.035 + AudioB.x * 0.085);

    float2 emberGrid = float2((p.x / aspect + 1.0) * 86.0, (p.y + t * (0.42 + drive * 0.48)) * 68.0);
    float2 emberCell = floor(emberGrid);
    float2 emberLocal = frac(emberGrid) - 0.5;
    float emberPoint = exp(-dot(emberLocal, emberLocal) * 58.0);
    float embers = pow(hash21(emberCell + seed), 78.0) * emberPoint * (0.20 + AudioC.z * 1.35 + AudioB.w * 0.8);
    color += palette(hash21(emberCell) + t * 0.03) * embers * (0.15 + drive * 0.30);
    float horizonGlow = exp(-abs(p.y + 0.66) * 4.0) * (0.025 + AudioC.x * 0.12);
    color += palette(u * 0.28 + 0.55) * horizonGlow;
    color *= 1.85 + AudioA.x * 0.62;
    float2 warp = float2((skyNoise - 0.5) * (0.003 + AudioC.w * 0.005), -0.0035 - drive * 0.0065);
    return makeScene(color, warp, 0.925);
}

SceneResult glassMosaic(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float3 color = 0.0;
    float columnPosition = u * 31.0;
    int bandIndex = (int)clamp(floor(columnPosition), 0.0, 31.0);
    float band = getBand(bandIndex);
    float localX = abs(frac(columnPosition) - 0.5);
    float column = smoothstep(0.48, 0.31, localX);
    float speed = 0.30 + Motion.y * 0.44 + band * 0.34;
    float stream = frac((p.y + 1.0) * 0.5 - t * speed - hash11(bandIndex + seed));
    float dash = pow(saturate(1.0 - abs(stream - 0.5) * 2.0), 5.0);
    float head = pow(saturate(1.0 - stream), 13.0);
    float intensity = audioCurve(band + AudioC.z * 0.35 + AudioB.w * 0.25, 2.1);
    float secondStream = frac(stream + 0.43 + hash11(bandIndex * 2.3) * 0.18);
    float secondDash = pow(saturate(1.0 - abs(secondStream - 0.5) * 2.0), 7.0);
    color += palette(bandIndex / 31.0 + t * 0.026) * column *
        (0.018 + dash * (0.11 + intensity * 0.48) + secondDash * (0.055 + intensity * 0.22) + head * (0.18 + AudioC.z * 0.78));

    float wave = reactiveWave(u, AudioA.x + AudioB.x);
    float waveY = wave * (0.21 + AudioA.x * 0.25) + sin(t * 0.31 + seed) * 0.12;
    float waveGlow = lineGlow(p.y - waveY, 0.006 + AudioA.w * 0.004);
    color += palette(u * 0.48 + 0.28 + t * 0.018) * waveGlow * (0.31 + AudioB.x * 0.82 + AudioC.y * 0.52);

    float mist = fbm(float2(p.x * 0.62 - t * 0.03, p.y * 1.35 + t * 0.07) + seed * 0.014);
    float mistBand = pow(saturate(1.0 - abs(mist - 0.54) * 5.0), 3.0);
    color += palette(mist * 0.44 + u * 0.12) * mistBand * (0.018 + AudioA.x * 0.055);
    float bassSweep = lineGlow(p.y - (frac(t * 0.19 + seed * 0.01) * 2.3 - 1.15), 0.025 + AudioC.x * 0.025);
    color += palette(t * 0.04 + 0.62) * bassSweep * AudioC.x * 0.26;

    color *= 2.25 + AudioA.x * 0.62;
    float2 warp = float2((wave + band - 0.5) * 0.0007, -0.0020 - AudioA.y * 0.0035);
    return makeScene(color, warp, 0.922);
}

SceneResult cometTrace(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float levelDrive = audioCurve(AudioA.x + AudioC.w * 0.45, 1.55);
    float bassDrive = audioCurve(AudioA.y + AudioC.x * 1.05, 1.75);
    float vocalDrive = audioCurve(AudioB.x + AudioC.y * 0.72, 1.65);
    float trebleDrive = audioCurve(AudioA.w + AudioC.z * 0.95, 1.55);
    float liveWave = reactiveWave(u, AudioA.x + AudioB.x + AudioC.y);

    float2 backgroundPosition = rotate2(
        p + float2(t * 0.025, -t * 0.018),
        sin(t * 0.075 + seed) * 0.13);
    float cloudA = fbm(backgroundPosition * float2(0.72, 1.18) + seed * 0.014);
    float cloudB = fbm(backgroundPosition.yx * float2(1.36, 0.62) - float2(t * 0.018, t * 0.034));
    float plasmaCurrent = pow(saturate(1.0 - abs(cloudA - cloudB) * 3.6), 2.4);
    float cloudBand = pow(saturate(1.0 - abs(cloudA - 0.53) * 3.7), 2.2);
    float vignette = smoothstep(2.20, 0.15, length(p));
    float3 color = palette(cloudA * 0.46 + cloudB * 0.28 + u * 0.12 + t * 0.010) *
        vignette * (0.060 + cloudBand * (0.090 + levelDrive * 0.11) + plasmaCurrent * (0.055 + bassDrive * 0.08));

    float2 starGrid = float2(
        (p.x / aspect + 1.0) * 104.0 - t * (1.1 + Motion.y * 1.5),
        (p.y + 1.0) * 62.0 + sin(t * 0.13) * 2.0);
    float2 starCell = floor(starGrid);
    float2 starOffset = hash22(starCell + seed * 2.3) * 0.68;
    float2 starLocal = frac(starGrid) - 0.5 - starOffset;
    float starPoint = exp(-dot(starLocal, starLocal) * (78.0 - trebleDrive * 22.0));
    float starSeed = hash21(starCell + seed * 1.7);
    float stars = pow(starSeed, 68.0) * starPoint;
    color += palette(starSeed + u * 0.18 + t * 0.025) * stars *
        (0.18 + trebleDrive * 0.92 + AudioC.z * 0.88);

    [unroll]
    for (int currentIndex = 0; currentIndex < 5; currentIndex++)
    {
        float depth = currentIndex / 4.0;
        float laneOffset = currentIndex - 2.0;
        float sampledU = saturate(u + laneOffset * 0.018);
        float currentBand = getBand(2 + currentIndex * 6);
        float currentWave = reactiveWave(sampledU, AudioA.x + currentBand + AudioB.x * 0.6);
        float currentY = laneOffset * 0.36;
        currentY += sin(sampledU * TAU * (0.72 + depth * 0.46) - t * (0.28 + depth * 0.34) + seed + depth * 2.7) *
            (0.055 + currentBand * 0.075);
        currentY += currentWave * (0.075 + levelDrive * 0.105 + currentBand * 0.135);
        currentY += sin(t * 0.31 + sampledU * TAU * 2.0 + depth) * vocalDrive * 0.040;
        float currentDistance = p.y - currentY;
        float currentGlow = lineGlow(currentDistance, 0.009 + currentBand * 0.008 + levelDrive * 0.004);
        float currentBody = exp(-abs(currentDistance) * (5.8 - levelDrive * 1.25));
        color += palette(depth * 0.72 + u * 0.22 + t * 0.018) *
            (currentBody * (0.028 + currentBand * 0.050) +
            currentGlow * (0.075 + currentBand * 0.36 + vocalDrive * 0.12));
    }

    float carrierFrequency = 1.08 + fmod(seed, 4.0) * 0.11;
    float carrier = sin(u * TAU * carrierFrequency + t * 0.48 + seed) * 0.105;
    carrier += sin(u * TAU * 3.1 - t * 0.72 + seed * 0.37) * (0.026 + AudioA.z * 0.044);
    float amplitude = 0.24 + levelDrive * 0.30 + vocalDrive * 0.34;
    float pathY = carrier + liveWave * amplitude;

    float headU = frac(Motion.w * (0.068 + Motion.y * 0.032) + seed * 0.017);
    float headDistance = abs(u - headU);
    headDistance = min(headDistance, 1.0 - headDistance);
    float bassJump = exp(-headDistance * headDistance * 34.0) * AudioC.x * (0.20 + bassDrive * 0.34);
    pathY -= bassJump * (0.76 + 0.24 * sin(u * TAU * 3.0 + t));
    float distanceBehind = frac(headU - u);
    float trail = exp(-distanceBehind * (2.55 - bassDrive * 0.62));
    float pathDistance = p.y - pathY;
    float pathGlow = lineGlow(pathDistance, 0.010 + levelDrive * 0.009 + trebleDrive * 0.004);
    float pathBody = exp(-abs(pathDistance) * (6.4 - levelDrive * 1.65));
    color += palette(u * 0.48 + t * 0.033) *
        (pathBody * (0.055 + trail * 0.12) + pathGlow * (0.20 + trail * 0.95)) *
        (0.62 + AudioA.z * 0.72 + vocalDrive * 0.92 + AudioB.w * 0.35);

    [unroll]
    for (int echoIndex = 1; echoIndex < 8; echoIndex++)
    {
        float age = echoIndex / 8.0;
        float shiftedU = saturate(u - age * (0.024 + bassDrive * 0.026));
        float echoWaveform = reactiveWave(shiftedU, AudioA.x + AudioB.x + age * 0.4);
        float echoY = sin(shiftedU * TAU * carrierFrequency + t * 0.48 + seed) * 0.105;
        echoY += sin(shiftedU * TAU * 3.1 - t * 0.72 + seed * 0.37) * (0.026 + AudioA.z * 0.044);
        echoY += echoWaveform * amplitude;
        echoY += (echoIndex - 4.0) * (0.048 + vocalDrive * 0.020);
        echoY -= exp(-headDistance * headDistance * 34.0) * AudioC.x * (0.08 + bassDrive * 0.14) * (1.0 - age);
        float echoDistance = p.y - echoY;
        float echoGlow = lineGlow(echoDistance, 0.006 + levelDrive * 0.005 + age * 0.003);
        float echoBody = exp(-abs(echoDistance) * (8.0 - levelDrive * 1.5));
        float echoFade = (1.0 - age) * (0.10 + trail * 0.66);
        color += palette(u * 0.46 - age * 0.18 + t * 0.030) *
            (echoGlow * (0.16 + vocalDrive * 0.25) + echoBody * 0.025) * echoFade;
    }

    float headX = (headU * 2.0 - 1.0) * aspect;
    float headWaveform = reactiveWave(headU, AudioA.x + AudioB.x + AudioC.y);
    float headY = sin(headU * TAU * carrierFrequency + t * 0.48 + seed) * 0.105;
    headY += sin(headU * TAU * 3.1 - t * 0.72 + seed * 0.37) * (0.026 + AudioA.z * 0.044);
    headY += headWaveform * amplitude;
    headY -= AudioC.x * (0.20 + bassDrive * 0.34);
    float2 toHead = p - float2(headX, headY);
    float headRadius = length(toHead * float2(0.82, 1.0));
    float headCore = exp(-dot(toHead, toHead) * (190.0 - AudioC.x * 75.0));
    float headHalo = lineGlow(headRadius - (0.075 + AudioC.x * 0.15), 0.017 + AudioC.x * 0.018);
    float headAngle = atan2(toHead.y, toHead.x);
    float headRays = pow(saturate(1.0 - abs(sin(headAngle * 10.0 + t * 2.2))), 10.0) *
        exp(-headRadius * (7.5 - AudioC.x * 2.2));
    float horizontalFlare = exp(-abs(toHead.y) * 7.0) * exp(-abs(toHead.x) * 1.9);
    float verticalFlare = exp(-abs(toHead.x) * 9.0) * exp(-abs(toHead.y) * 1.5);
    float3 headColor = palette(headU * 0.52 + t * 0.035 + 0.24);
    color += headColor * headCore * (0.85 + AudioC.x * 1.65 + trebleDrive * 0.55);
    color += palette(headU * 0.52 + 0.58) * headHalo * (0.16 + AudioC.x * 0.84 + AudioB.w * 0.32);
    color += headColor * headRays * (0.045 + trebleDrive * 0.28 + AudioC.z * 0.45);
    color += headColor * (horizontalFlare + verticalFlare) * (0.018 + AudioC.x * 0.095 + AudioC.z * 0.070);

    float shockRadius = frac(Motion.w * 0.25 + seed * 0.021) * 1.45;
    float shock = lineGlow(length(p - float2(headX, headY)) - shockRadius, 0.016 + AudioC.x * 0.020);
    color += palette(headU + shockRadius * 0.28 + 0.44) * shock * AudioC.x * (0.18 + bassDrive * 0.48);

    color *= 1.52 + levelDrive * 0.46;
    float2 warp = float2(-0.0012 - bassDrive * 0.0026, liveWave * (0.0008 + vocalDrive * 0.0021));
    warp += float2(cloudB - 0.5, cloudA - 0.5) * (0.0012 + AudioC.w * 0.0032);
    return makeScene(color, warp, 0.938);
}

SceneResult fractalWings(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float low = noteMotion(AudioA.y);
    float mid = noteMotion(AudioB.x);
    float high = noteMotion(AudioA.w);
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float2 q = p - float2(sin(t * 0.17 + seed) * 0.08, cos(t * 0.13 + seed) * 0.04);
    float wingX = abs(q.x) / max(1.0, aspect);
    float wingY = abs(q.y);
    float drive = audioCurve(AudioA.x + AudioC.x + AudioC.y * 0.55, 1.7);
    float3 color = 0.0;
    float cloud = fbm(float2(q.x * 0.54 + t * 0.042, q.y * 1.25 - t * 0.027) + seed * 0.019);
    float cloudBand = pow(saturate(1.0 - abs(cloud - 0.52) * 4.5), 3.0);
    color += palette(cloud * 0.43 + wingX * 0.17) * cloudBand * (0.022 + AudioA.x * 0.070);

    [unroll]
    for (int i = 0; i < 7; i++)
    {
        float fi = i / 6.0;
        float band = getBand(4 + i * 4);
        float articulation = noteMotion(band);
        float wave = reactiveWave(0.5 + wingX * 0.5, band + AudioB.x);
        float arch = 0.08 + fi * 0.073;
        arch += low * (0.12 + sin(wingX * PI) * 0.23);
        arch += articulation * (0.04 + 0.17 * sin(wingX * 3.2 + fi * 1.8));
        arch += sin(wingX * (2.8 + fi * 2.0) - t * (0.75 + Motion.y * 0.75) + i + seed) * (0.02 + mid * 0.10);
        arch += wave * (0.025 + mid * 0.18 + articulation * 0.12);
        arch += wingX * (0.18 + fi * 0.10) - wingX * wingX * (0.10 + fi * 0.04);
        float feather = lineGlow(wingY - arch, 0.006 + band * 0.008 + drive * 0.003);
        float fade = smoothstep(1.12, 0.08, wingX) * smoothstep(1.08, 0.82, wingY);
        float shimmer = 0.72 + 0.28 * sin(t * (1.8 + Motion.y * 2.0) - wingX * 9.0 + i * 0.8);
        color += palette(fi * 0.64 + wingX * 0.22 + t * 0.018) * feather * fade *
            (0.08 + articulation * 0.92 + mid * 0.34 + high * 0.18) * shimmer;
    }

    float wingSurface = 0.19 + low * 0.22 + wingX * 0.35 - wingX * wingX * 0.16;
    wingSurface += sin(wingX * 4.0 - t * (0.44 + Motion.y * 0.38)) * (0.055 + drive * 0.045);
    float wingFill = exp(-abs(wingY - wingSurface) * (3.8 - drive * 0.7)) * smoothstep(1.12, 0.08, wingX);
    color += palette(wingX * 0.36 + cloud * 0.22 + 0.28) * wingFill * (0.050 + AudioA.x * 0.090);

    float distantWing = exp(-abs(wingY - (0.72 + sin(wingX * 2.4 - t * 0.26) * 0.12)) * 4.2);
    color += palette(wingX * 0.24 + t * 0.012 + 0.61) * distantWing * smoothstep(1.15, 0.05, wingX) * (0.030 + drive * 0.045);

    float veinPhase = frac(wingX * 4.0 - t * (0.34 + Motion.y * 0.30) + seed * 0.01);
    float veinY = 0.06 + wingX * 0.74 + sin(wingX * 7.0 + t) * (0.035 + AudioB.x * 0.04);
    float vein = lineGlow(wingY - veinY, 0.008) * pow(saturate(1.0 - veinPhase), 7.0);
    color += palette(wingX * 0.52 + t * 0.04 + 0.36) * vein * (0.14 + AudioC.z * 0.85);
    float core = exp(-dot(q * float2(3.4, 5.6), q * float2(3.4, 5.6)) * (1.8 - drive * 0.45));
    color += palette(q.y * 0.18 + t * 0.04) * core * (0.050 + drive * 0.18);
    float beatHalo = lineGlow(length(q * float2(0.72, 1.0)) - (0.18 + drive * 0.16), 0.022);
    color += palette(t * 0.05 + 0.72) * beatHalo * AudioC.x * 0.28;
    color *= 1.32 + AudioA.x * 0.38;
    float smoothSide = q.x / (abs(q.x) + 0.24);
    float2 warp = float2(smoothSide * (0.0012 + AudioC.w * 0.003), reactiveWave(u, AudioB.x) * 0.0013);
    return makeScene(color, warp, 0.926);
}

SceneResult spectralCathedral(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float energy = audioCurve(AudioA.x + AudioA.y * 0.88 + AudioB.x * 0.42, 1.78);
    float kick = audioCurve(AudioC.x * 1.75 + AudioB.w * 0.70, 2.20);
    float voice = audioCurve(AudioB.x + AudioC.y * 0.72, 1.72);
    float sparkle = audioCurve(AudioC.z + AudioB.z * 0.72 + AudioC.w * 0.42, 1.80);

    float2 vanishing = float2(
        sin(t * 0.23 + seed) * (0.16 + voice * 0.08),
        -0.23 + cos(t * 0.17 + seed * 0.61) * (0.055 + AudioA.z * 0.04));
    float cameraRoll = sin(t * 0.19 + seed * 0.37) * (0.055 + voice * 0.055);
    float2 q = rotate2(p - vanishing, cameraRoll);

    float cloud = fbm(float2(q.x * 0.48 + t * 0.050, q.y * 0.94 - t * 0.036) + seed * 0.014);
    float cloudBand = pow(saturate(1.0 - abs(cloud - 0.52) * 4.1), 2.7);
    float3 color = palette(cloud * 0.50 + q.x * 0.055 + t * 0.008) *
        (0.028 + cloudBand * (0.070 + energy * 0.095));

    float rayAngle = atan2(q.y, q.x);
    float rayRadius = max(0.025, length(q));
    float lightRays = pow(saturate(0.5 + 0.5 * sin(rayAngle * 15.0 + cloud * 3.2 - t * (0.54 + Motion.y * 0.55))), 13.0);
    lightRays *= smoothstep(0.02, 1.18, rayRadius) * (1.0 - smoothstep(1.10, 2.15, rayRadius));
    color += palette(rayAngle / TAU + t * 0.015 + 0.35) * lightRays * (0.018 + sparkle * 0.080 + kick * 0.045);

    float floorHorizon = 0.055;
    float floorDistance = max(0.045, q.y - floorHorizon);
    float floorMask = smoothstep(floorHorizon, floorHorizon + 0.18, q.y);
    float laneCoordinate = q.x / floorDistance;
    float laneCells = abs(frac(laneCoordinate * (1.22 + voice * 0.22)) - 0.5);
    float laneLines = lineGlow(laneCells - 0.485, 0.009 + AudioA.y * 0.006);
    float depthCoordinate = 0.38 / floorDistance - t * (0.88 + Motion.y * 0.72 + energy * 0.32);
    float depthCells = abs(frac(depthCoordinate) - 0.5);
    float depthLines = lineGlow(depthCells - 0.485, 0.010 + kick * 0.008);
    float floorGlow = (laneLines * (0.72 + AudioA.y * 0.55) + depthLines * (0.58 + kick * 1.15)) * floorMask;
    color += palette(laneCoordinate * 0.05 + depthCoordinate * 0.025 + t * 0.018 + 0.58) * floorGlow * 0.16;

    [unroll]
    for (int i = 0; i < 10; i++)
    {
        float layer = i / 9.0;
        float travel = frac(t * (0.115 + Motion.y * 0.080 + energy * 0.025) + layer + seed * 0.004);
        float scale = 0.14 + pow(travel, 1.32) * (1.78 + kick * 0.12);
        float2 local = q / scale;
        float band = getBand(min(31, 1 + i * 3));
        float roofSample = saturate(local.x * 0.66 + 0.5);
        float roofWave = reactiveWave(roofSample, band + voice + energy * 0.45);
        float absoluteX = abs(local.x);
        float roofY = -0.74 + absoluteX * (0.78 + voice * 0.08);
        roofY -= sin(absoluteX * PI * 1.45 - t * (0.82 + Motion.y * 0.72) + i) * (0.045 + band * 0.09);
        roofY += roofWave * (0.035 + band * 0.12 + voice * 0.07);
        float pillarX = 0.73 + reactiveWave(saturate((local.y + 0.12) * 0.58), band + AudioA.y) * (0.018 + energy * 0.045);

        float roof = lineGlow(local.y - roofY, (0.0052 + band * 0.0055) / scale) * smoothstep(0.79, 0.69, absoluteX);
        float pillars = lineGlow(absoluteX - pillarX, (0.0055 + band * 0.0060) / scale) *
            smoothstep(-0.20, -0.05, local.y) * smoothstep(1.08, 0.93, local.y);
        float arch = roof + pillars;
        float layerFade = smoothstep(0.015, 0.11, travel) * smoothstep(0.995, 0.82, travel);
        float pulse = 0.72 + 0.28 * sin(t * (1.35 + Motion.y * 1.7) - i * 0.82 + Motion.x * TAU);
        float3 archColor = palette(layer * 0.74 + travel * 0.23 + t * 0.021);
        color += archColor * arch * layerFade * pulse * (0.15 + band * 0.74 + energy * 0.30 + kick * travel * 0.26);

        float innerDistance = max(abs(local.x) - 0.70, local.y - 0.96);
        float windowGlow = exp(-abs(innerDistance) * (3.2 + travel * 2.0)) * smoothstep(-0.72, -0.38, local.y) * layerFade;
        color += archColor * windowGlow * (0.009 + band * 0.025 + voice * 0.018);

        float runnerPhase = frac(t * (0.34 + Motion.y * 0.24) + layer * 1.73);
        float runnerX = lerp(-pillarX, pillarX, runnerPhase);
        float runnerY = runnerPhase < 0.5 ? lerp(0.88, roofY, runnerPhase * 2.0) : lerp(roofY, 0.88, (runnerPhase - 0.5) * 2.0);
        float2 runnerDelta = local - float2(runnerX, runnerY);
        float runner = exp(-dot(runnerDelta, runnerDelta) * (95.0 - sparkle * 24.0)) * layerFade;
        color += lerp(archColor, Palette3.rgb, 0.64) * runner * (0.06 + sparkle * 0.35 + kick * 0.22);
    }

    float portalRadius = length(q * float2(1.0, 1.18));
    float portal = exp(-portalRadius * (4.2 - energy * 1.1));
    float portalPulse = 0.72 + AudioB.w * 0.72 + AudioC.x * 0.54;
    color += palette(t * 0.035 + cloud * 0.22 + 0.18) * portal * (0.035 + energy * 0.13) * portalPulse;
    color *= 1.02 + AudioA.x * 0.30 + kick * 0.16;

    float2 warpDirection = normalize(q + 0.001);
    float2 warp = -warpDirection * (0.0015 + AudioA.y * 0.0038 + kick * 0.0042);
    warp += float2(sin(q.y * 3.0 + t), cos(q.x * 2.4 - t)) * AudioC.w * 0.0018;
    return makeScene(color, warp, 0.91);
}

SceneResult auroraCurrent(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float3 color = 0.0;
    float2 warp = 0.0;
    [unroll]
    for (int i = 0; i < 6; i++)
    {
        float fi = i / 5.0;
        float band = getBand(10 + i * 3);
        float n = fbm(float2(p.x * 1.4 + t * 0.035 + i, p.y * 0.8 + seed));
        float curtain = p.x - (-0.9 + fi * 1.8 + (n - 0.5) * (0.34 + band * 0.32));
        float glow = lineGlow(curtain, 0.018 + band * 0.024);
        float verticalFade = smoothstep(1.1, -0.2, p.y) * smoothstep(-1.1, -0.35, p.y);
        color += palette(fi + p.y * 0.09) * glow * verticalFade * (0.14 + band * 0.58 + AudioB.x * 0.24);
        warp += float2((n - 0.5) * 0.0008, -glow * 0.0005);
    }
    color += palette(fbm(p * 1.1)) * fbm(p * 2.0 - t * 0.02) * 0.025;
    warp += float2(sin(p.y * 2.0 + t) * 0.002, -0.001 - AudioA.y * 0.002);
    return makeScene(color, warp, 0.957);
}

SceneResult oscilloscopeRibbon(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float screenX = p.x / aspect;
    float u = saturate(screenX * 0.5 + 0.5);
    float energy = audioCurve(AudioA.x + AudioA.y * 0.78 + AudioB.x * 0.46, 1.82);
    float kick = audioCurve(AudioC.x * 1.85 + AudioB.z * 0.72, 2.18);
    float voice = audioCurve(AudioB.x + AudioC.y * 0.76, 1.68);
    float sparkle = audioCurve(AudioC.z + AudioB.z * 0.78 + AudioC.w * 0.48, 1.72);

    float skyNoise = fbm(float2(screenX * 0.62 + t * 0.032, p.y * 0.76 - t * 0.020) + seed * 0.016);
    float skyVein = pow(saturate(1.0 - abs(skyNoise - 0.53) * 4.1), 2.7);
    float skyGlow = saturate(0.70 - p.y * 0.24);
    float3 color = palette(skyNoise * 0.48 + u * 0.19 + t * 0.010) *
        (0.020 + skyGlow * 0.012 + skyVein * (0.035 + energy * 0.042));

    float2 starGrid = float2(
        (screenX + 1.0) * 98.0 - t * (1.4 + Motion.y * 1.8),
        (p.y + 1.0) * 56.0 + t * 0.32);
    float2 starCell = floor(starGrid);
    float2 starOffset = hash22(starCell + seed * 2.1) * 0.66;
    float2 starLocal = frac(starGrid) - 0.5 - starOffset;
    float starSeed = hash21(starCell + seed);
    float stars = pow(starSeed, 72.0) * exp(-dot(starLocal, starLocal) * (86.0 - sparkle * 24.0));
    color += palette(starSeed + t * 0.027) * stars * (0.045 + sparkle * 0.32);

    float floorHorizon = 0.22;
    float floorDistance = max(0.045, p.y - floorHorizon);
    float floorMask = smoothstep(floorHorizon, floorHorizon + 0.16, p.y);
    float laneCoordinate = screenX / floorDistance;
    float laneCells = abs(frac(laneCoordinate * 0.62) - 0.5);
    float laneLines = lineGlow(laneCells - 0.485, 0.010 + kick * 0.006);
    float depthCoordinate = 0.36 / floorDistance - Motion.w * (0.14 + Motion.y * 0.08);
    float depthCells = abs(frac(depthCoordinate) - 0.5);
    float depthLines = lineGlow(depthCells - 0.485, 0.011 + AudioB.w * 0.006);
    float floorGrid = (laneLines * 0.72 + depthLines * (0.58 + kick * 0.92)) * floorMask;
    color += palette(laneCoordinate * 0.045 + depthCoordinate * 0.030 + t * 0.012 + 0.58) *
        floorGrid * (0.034 + energy * 0.060 + kick * 0.045);

    float beatSweep = frac(Motion.w * 0.25 + seed * 0.013);
    float sweepCenter = lerp(-1.08, 1.08, beatSweep);
    float sweepBeam = exp(-abs(screenX - sweepCenter) * (6.5 - kick * 1.6));
    color += palette(beatSweep * 0.72 + t * 0.020) * sweepBeam * kick * (0.030 + energy * 0.070);

    float backdropWave = smoothReactiveWave(frac(u + t * 0.018), voice + sparkle * 0.45);
    float backdropY = -0.66 + backdropWave * (0.075 + voice * 0.15 + sparkle * 0.045);
    float backdropRibbon = lineGlow(p.y - backdropY, 0.010 + voice * 0.008);
    float backdropEcho = lineGlow(p.y - backdropY - 0.070, 0.007);
    color += palette(u * 0.52 + t * 0.017 + 0.46) *
        (backdropRibbon * (0.020 + voice * 0.11) + backdropEcho * (0.008 + sparkle * 0.040));

    float crownPosition = u * 63.0;
    int crownIndex = (int)floor(crownPosition);
    float crownBand = lerp(getBand(crownIndex), getBand(min(63, crownIndex + 1)), frac(crownPosition));
    float crownY = -0.82 + crownBand * 0.26 + sin(screenX * 2.2 - t * (0.62 + Motion.y * 0.58)) * 0.035;
    float crown = lineGlow(p.y - crownY, 0.011 + crownBand * 0.012);
    float crownEcho = lineGlow(p.y - crownY - 0.085 - crownBand * 0.045, 0.008);
    color += palette(u * 0.70 + t * 0.024 + 0.16) *
        (crown * (0.030 + crownBand * 0.35) + crownEcho * crownBand * 0.12);

    [unroll]
    for (int rowIndex = 0; rowIndex < 2; rowIndex++)
    {
        float depth = rowIndex;
        float rowWidth = 0.70 + depth * 0.38;
        float normalizedX = screenX / rowWidth;
        float rowMask = smoothstep(1.04, 0.97, abs(normalizedX));
        float xPosition = saturate(normalizedX * 0.5 + 0.5);
        float barCoordinate = xPosition * 64.0;
        int barIndex = (int)clamp(floor(barCoordinate), 0.0, 63.0);
        int mappedIndex = barIndex;
        float barLocalX = frac(barCoordinate) - 0.5;
        float blendedBand = getBand(mappedIndex);
        float shapedBand = pow(saturate((blendedBand - 0.030) / 0.970), 0.74);
        float sweepDistance = abs(barIndex / 63.0 - beatSweep);
        sweepDistance = min(sweepDistance, 1.0 - sweepDistance);
        float sweepPulse = exp(-sweepDistance * 18.0) * kick * smoothstep(0.055, 0.20, shapedBand);

        float baseY = -0.12 + depth * 0.63;
        float heightScale = 0.34 + depth * 0.78;
        float activation = smoothstep(0.050, 0.145, shapedBand + sweepPulse * 0.28);
        float barHeight = activation * (shapedBand * heightScale + sweepPulse * (0.030 + depth * 0.060));
        float topY = baseY - barHeight;

        float frontHalfWidth = 0.365;
        float frontX = smoothstep(frontHalfWidth + 0.018, frontHalfWidth - 0.010, abs(barLocalX));
        float frontY = smoothstep(topY - 0.012, topY + 0.012, p.y) *
            smoothstep(baseY + 0.012, baseY - 0.012, p.y);
        float segmentSize = 0.068 + depth * 0.006;
        float segmentPosition = frac((baseY - p.y) / segmentSize);
        float segmentMask = smoothstep(0.10, 0.22, segmentPosition) * smoothstep(0.93, 0.80, segmentPosition);
        float frontFace = frontX * frontY * segmentMask * rowMask * activation;

        float cap = lineGlow(p.y - topY, 0.006 + sparkle * 0.003) * frontX * rowMask * activation;
        float capHalo = exp(-abs(p.y - topY) * (22.0 - sparkle * 5.0)) *
            exp(-barLocalX * barLocalX * 11.0) * rowMask * activation;
        float peakSpark = exp(-barLocalX * barLocalX * 95.0 - (p.y - topY) * (p.y - topY) * 520.0) *
            rowMask * activation * (0.28 + sparkle * 0.72 + sweepPulse * 0.80);

        float heightPosition = saturate((baseY - p.y) / max(0.04, barHeight));
        float3 barColor = palette(mappedIndex / 63.0 * 0.76 + depth * 0.11 + t * 0.018);
        float frontLight = 0.24 + shapedBand * 0.92 + heightPosition * 0.15 + sweepPulse * 0.38;
        color += barColor * frontFace * frontLight * (0.34 + depth * 0.82);
        color += lerp(barColor, Palette3.rgb, 0.38) * cap *
            (0.060 + shapedBand * 0.42 + sparkle * 0.18 + sweepPulse * 0.28) * (0.26 + depth * 0.86);
        color += barColor * capHalo * shapedBand * (0.028 + depth * 0.078);
        color += lerp(barColor, Palette3.rgb, 0.68) * peakSpark * (0.10 + shapedBand * 0.38);

        float reflectionBottom = baseY + barHeight * (0.12 + depth * 0.15);
        float reflectionY = smoothstep(baseY - 0.012, baseY + 0.020, p.y) *
            smoothstep(reflectionBottom + 0.020, reflectionBottom - 0.020, p.y);
        float reflectionFade = saturate(1.0 - (p.y - baseY) / max(0.05, reflectionBottom - baseY));
        float reflectionSegments = smoothstep(0.08, 0.22, frac((p.y - baseY) / segmentSize)) *
            smoothstep(0.96, 0.78, frac((p.y - baseY) / segmentSize));
        color += barColor * frontX * reflectionY * reflectionSegments * reflectionFade * rowMask *
            shapedBand * (0.008 + depth * 0.024);
    }

    float shockRadius = frac(Motion.w * 0.25 + seed * 0.031) * 1.55;
    float2 shockPosition = float2(screenX, (p.y - 0.58) * 0.44);
    float shock = lineGlow(length(shockPosition) - shockRadius, 0.015 + kick * 0.022);
    color += palette(shockRadius * 0.34 + t * 0.018) * shock * kick * (0.040 + energy * 0.070);

    color *= 1.12 + energy * 0.24 + kick * 0.08;
    float2 warp = float2(
        (skyNoise - 0.5) * (0.0005 + AudioC.w * 0.0010),
        -0.0006 - kick * 0.0011 - AudioA.y * 0.0005);
    return makeScene(color, warp, 0.795);
}

SceneResult vocalLoom(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float v = saturate(p.y * 0.5 + 0.5);
    float energy = audioCurve(AudioA.x + AudioC.w * 0.44, 1.62);
    float bassDrive = audioCurve(AudioA.y + AudioC.x * 0.88, 1.72);
    float vocalDrive = audioCurve(AudioB.x + AudioC.y * 0.72, 1.68);
    float detail = audioCurve(AudioA.w + AudioC.z * 0.72, 1.58);
    float3 color = 0.0;

    float atmosphere = fbm(float2(p.x * 0.44 + t * 0.052, p.y * 0.92 - t * 0.033) + seed * 0.015);
    float atmosphereBand = pow(saturate(1.0 - abs(atmosphere - 0.52) * 4.0), 2.7);
    color += palette(atmosphere * 0.43 + u * 0.12 + t * 0.008) * atmosphereBand * (0.030 + energy * 0.075);

    float3 verticalColor = 0.0;
    float3 horizontalColor = 0.0;

    [unroll]
    for (int i = 0; i < 5; i++)
    {
        float fi = i / 4.0;
        float band = getBand(7 + i * 5);
        float wave = smoothReactiveWave(saturate(v + (fi - 0.5) * 0.025), vocalDrive + band);
        float x = (-0.76 + fi * 1.52) * aspect;
        x += sin(v * TAU * (0.72 + fi * 0.24) - t * (0.52 + Motion.y * 0.48) + i * 1.31 + seed) * (0.050 + band * 0.075);
        x += wave * (0.035 + vocalDrive * 0.095 + band * 0.045);
        float width = 0.007 + band * 0.006 + energy * 0.0025;
        float thread = lineGlow(p.x - x, width);
        float runner = pow(saturate(0.5 + 0.5 * sin(v * 11.0 - Motion.w * 1.55 + i * 1.8)), 10.0);
        float segmentGate = 0.62 + runner * (0.25 + detail * 0.36);
        float3 strand = palette(fi * 0.61 + v * 0.14 + t * 0.022) * thread * segmentGate * (0.11 + band * 0.48 + vocalDrive * 0.22);
        verticalColor = max(verticalColor, strand);
    }

    [unroll]
    for (int j = 0; j < 4; j++)
    {
        float fi = j / 3.0;
        float band = getBand(5 + j * 7);
        float wave = smoothReactiveWave(saturate(u + (fi - 0.5) * 0.018), energy + band);
        float y = -0.62 + fi * 1.24;
        y += sin(u * TAU * (0.88 + fi * 0.22) + t * (0.47 + Motion.y * 0.43) + j * 1.47) * (0.045 + band * 0.070);
        y += wave * (0.040 + energy * 0.075 + band * 0.050);
        y -= bassDrive * sin(u * PI + fi * 2.0) * 0.040;
        float width = 0.0075 + band * 0.0065 + energy * 0.0025;
        float ribbon = lineGlow(p.y - y, width);
        float runner = pow(saturate(0.5 + 0.5 * sin(u * 12.0 + Motion.w * 1.42 - j * 1.6)), 10.0);
        float segmentGate = 0.62 + runner * (0.24 + detail * 0.34);
        float3 strand = palette(0.18 + fi * 0.58 - u * 0.10 + t * 0.019) * ribbon * segmentGate *
            (0.12 + band * 0.50 + energy * 0.20);
        horizontalColor = max(horizontalColor, strand);
    }

    float3 woven = max(horizontalColor, verticalColor);
    woven += min(verticalColor, horizontalColor) * (0.12 + AudioB.w * 0.16);
    color += woven;

    float travelingCross = pow(saturate(0.5 + 0.5 * sin((u + v) * 15.0 - Motion.w * 1.8)), 18.0);
    color += palette(u * 0.34 + v * 0.31 + t * 0.031) * travelingCross * min(length(verticalColor), length(horizontalColor)) *
        (0.08 + AudioC.z * 0.22);
    color *= 1.30 + energy * 0.30;
    float2 warp = float2(smoothReactiveWave(v, vocalDrive), smoothReactiveWave(u, energy)) * (0.00035 + AudioC.w * 0.00075);
    return makeScene(color, warp, 0.858);
}

SceneResult bassTerrain(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float u = saturate(p.x / aspect * 0.5 + 0.5);
    float energy = audioCurve(AudioA.x + AudioA.y * 0.82 + AudioB.x * 0.38, 1.72);
    float kick = audioCurve(AudioC.x * 1.8 + AudioB.w * 0.72, 2.15);
    float detail = audioCurve(AudioC.y + AudioC.z * 0.72 + AudioC.w * 0.35, 1.65);

    float sky = saturate(0.54 - p.y * 0.34);
    float3 color = palette(0.60 + u * 0.12 + t * 0.008) * (0.016 + sky * 0.022 + energy * 0.014);
    float atmosphere = fbm(float2(p.x * 0.42 + t * 0.032, p.y * 0.70 + t * (0.17 + Motion.y * 0.12)) + seed * 0.01);
    float atmosphereBand = pow(saturate(1.0 - abs(atmosphere - 0.52) * 4.0), 2.6);
    color += palette(atmosphere * 0.52 + p.y * 0.08 + t * 0.006) * atmosphereBand *
        (0.028 + AudioA.y * 0.095 + AudioC.y * 0.065);

    float2 ascentCoordinate = float2((p.x / aspect + 1.0) * 70.0, (p.y + t * (0.70 + Motion.y * 0.42 + energy * 0.18)) * 44.0);
    float2 ascentCell = floor(ascentCoordinate);
    float2 ascentLocal = frac(ascentCoordinate) - 0.5;
    float ascentSeed = hash21(ascentCell + seed);
    float ascentParticle = pow(ascentSeed, 52.0) * exp(-dot(ascentLocal * float2(3.1, 0.72), ascentLocal * float2(3.1, 0.72)) * 42.0);
    color += palette(ascentSeed + t * 0.028) * ascentParticle * (0.035 + AudioC.z * 0.34 + AudioB.w * 0.16);
    float ascentRibs = pow(saturate(0.5 + 0.5 * sin(p.y * 9.5 + p.x * 0.82 + t * (2.1 + Motion.y * 1.4 + energy * 0.8))), 13.0);
    color += palette(p.y * 0.10 + u * 0.17 + t * 0.015) * ascentRibs * (0.009 + energy * 0.024 + kick * 0.018);

    float climbSpeed = 0.135 + Motion.y * 0.10 + energy * 0.035;
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float layer = i / 8.0;
        float climb = frac(t * climbSpeed + layer + seed * 0.004);
        float nearDepth = 1.0 - climb;
        float ridgeBase = 1.24 - climb * 2.48;
        float waveOffset = t * (0.014 + layer * 0.006) + layer * 0.073;
        float shiftedU = 1.0 - abs(frac((u + waveOffset) * 0.5) * 2.0 - 1.0);
        float lowBand = getBand(min(13, 1 + i));
        float voiceBand = getBand(min(29, 9 + i * 2));
        float wave = reactiveWave(shiftedU, energy + lowBand * 0.85);
        float perspective = lerp(0.50, 1.12, nearDepth);
        float amplitude = (0.115 + energy * 0.30 + lowBand * 0.28) * perspective;
        float ridge = ridgeBase + wave * amplitude;
        ridge += sin(u * TAU * (1.0 + layer * 1.8) + t * (0.46 + Motion.y * 0.36) + i * 0.71) *
            (0.028 + voiceBand * 0.092) * perspective;
        ridge -= kick * (0.055 + nearDepth * 0.13);

        float layerFade = smoothstep(0.018, 0.11, climb) * smoothstep(0.995, 0.88, climb);
        float width = (0.0030 + nearDepth * 0.0032 + lowBand * 0.0032 + kick * 0.0018);
        float edge = lineGlow(p.y - ridge, width) * layerFade;
        float echo = lineGlow(p.y - ridge - 0.034 - nearDepth * 0.018, width * 0.52) * layerFade;
        float below = max(0.0, p.y - ridge);
        float face = step(ridge, p.y) * exp(-below * lerp(13.0, 6.0, nearDepth)) * layerFade;
        float facet = 0.48 + 0.52 * sin((u * (5.0 + layer * 4.0) + below * 4.5) * PI - t * (0.65 + Motion.y * 0.7));
        float intensity = 0.11 + energy * 0.25 + lowBand * 0.46 + kick * 0.25;
        float3 layerColor = palette(layer * 0.57 + u * 0.14 + t * 0.024);
        color += layerColor * (edge * intensity + echo * (0.024 + detail * 0.045));
        color += layerColor * face * (0.012 + nearDepth * 0.018 + lowBand * 0.030) * (0.55 + facet * 0.45);

        float runnerPosition = frac(t * (0.18 + Motion.y * 0.15) + layer * 1.61 + Motion.x * 0.10);
        float runner = exp(-abs(u - runnerPosition) * (55.0 - detail * 14.0)) * edge;
        color += lerp(layerColor, Palette3.rgb, 0.68) * runner * (0.09 + AudioB.z * 0.22 + kick * 0.18);

        float peakSpark = pow(saturate(1.0 - abs(wave)), 9.0) * edge * (AudioC.z + AudioB.z * 0.42);
        color += lerp(layerColor, Palette3.rgb, 0.58) * peakSpark * 0.060;
    }

    float horizon = exp(-abs(p.y + 0.68 - sin(p.x * 0.55 + t * 0.17) * 0.055) * (8.0 + energy * 3.0));
    color += palette(u * 0.30 + t * 0.032 + 0.68) * horizon * (0.018 + AudioC.x * 0.12 + AudioB.w * 0.055);
    color *= 1.02 + AudioA.x * 0.26 + kick * 0.12;
    float2 warp = float2(sampleWave(u) * AudioC.w * 0.0007, 0.0042 + AudioA.y * 0.0048 + AudioC.x * 0.0052);
    return makeScene(color, warp, 0.855);
}

SceneResult discoCubeFloor(float2 p, float seed)
{
    float t = ResolutionTime.z;
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float2 screen = float2(p.x / aspect, p.y);
    float drive = audioCurve(AudioA.y + AudioC.x * 1.15 + AudioB.w * 0.55, 1.85);
    float beatTime = Motion.w;
    float phraseTime = beatTime * 0.25;
    float phraseIndex = floor(phraseTime);
    float phraseBlend = smoothstep(0.0, 0.42, frac(phraseTime));

    float2 q = screen;
    q.x += sin(screen.y * 1.18 + t * 0.11 + seed) * 0.0045;
    q.y += sin(screen.x * 1.52 - t * 0.09 + seed * 0.41) * 0.0035;
    const float columns = 16.0;
    const float rows = 9.0;
    float2 tileCoordinate = float2((q.x + 1.0) * 0.5 * columns, (q.y + 1.0) * 0.5 * rows);
    tileCoordinate.x += (tileCoordinate.y - rows * 0.5) * sin(t * 0.10 + seed) * 0.010;
    float2 tileId = floor(tileCoordinate);
    float2 cell = frac(tileCoordinate) - 0.5;

    float outerDistance = roundedBoxSdf(cell + float2(-0.015, 0.024), float2(0.475, 0.465), 0.070);
    float faceDistance = roundedBoxSdf(cell, float2(0.425, 0.415), 0.076);
    float outer = 1.0 - smoothstep(-0.006, 0.018, outerDistance);
    float face = 1.0 - smoothstep(-0.010, 0.014, faceDistance);
    float bevel = saturate(outer - face);
    float rim = exp(-abs(faceDistance) * 55.0);

    int bandIndex = (int)fmod(tileId.x * 2.0 + tileId.y * 5.0, 32.0);
    float band = getBand(bandIndex);
    float previousSelection = hash21(tileId + (phraseIndex - 1.0) * float2(17.17, 9.31) + floor(seed));
    float nextSelection = hash21(tileId + phraseIndex * float2(17.17, 9.31) + floor(seed));
    float selection = lerp(previousSelection, nextSelection, phraseBlend);
    float selected = smoothstep(0.70, 0.84, selection);
    float previousHeldSelection = hash21(tileId * 1.37 + (phraseIndex - 1.0) * float2(5.71, 13.19) + seed);
    float nextHeldSelection = hash21(tileId * 1.37 + phraseIndex * float2(5.71, 13.19) + seed);
    float heldSelection = lerp(previousHeldSelection, nextHeldSelection, phraseBlend);
    float held = smoothstep(0.82, 0.94, heldSelection) * (0.13 + AudioA.x * 0.18);

    float diagonalPhase = frac((tileId.x + tileId.y * 0.72) / (columns + rows) - beatTime * 0.10);
    float diagonalPulse = pow(saturate(1.0 - abs(diagonalPhase - 0.5) * 7.0), 3.0) * (0.12 + AudioC.y * 0.82);
    float beatBloom = 0.34 + AudioB.w * 0.76 + AudioC.x * 0.28;
    float light = selected * beatBloom * (0.72 + AudioB.z * 0.30);
    light += held + diagonalPulse + band * (0.028 + selected * (0.34 + AudioA.x * 0.28));

    float colorSeed = hash21(tileId * 0.73 + floor(seed) * 0.031);
    float3 tileColor = palette(colorSeed * 0.78 + tileId.x * 0.035 + t * 0.012);
    float faceShade = 0.48 + cell.y * 0.22 + cell.x * 0.08;
    float3 color = palette(colorSeed + 0.42) * bevel * (0.010 + light * 0.15);
    color += tileColor * face * (0.004 + light * (0.37 + faceShade * 0.25));
    color += tileColor * rim * (0.012 + light * 0.54 + AudioC.z * selected * 0.48);

    float2 microCell = frac((cell + 0.5) * 13.0) - 0.5;
    float microDots = exp(-dot(microCell, microCell) * 76.0) * face;
    color += lerp(tileColor, Palette3.rgb, 0.56) * microDots * (0.0015 + light * 0.21 + AudioC.z * selected * 0.20);

    float motifChoice = hash21(tileId + seed * 0.083);
    float2 motifCorner = float2(motifChoice > 0.5 ? -0.48 : 0.48, motifChoice > 0.25 && motifChoice < 0.75 ? -0.48 : 0.48);
    float arc = lineGlow(length(cell - motifCorner) - 0.42, 0.020 + band * 0.012) * face;
    float diagonal = lineGlow(cell.x + cell.y * (motifChoice > 0.5 ? 1.0 : -1.0), 0.020 + AudioC.z * 0.010) * face;
    float motif = lerp(arc, diagonal, step(0.64, motifChoice));
    color += lerp(tileColor, Palette3.rgb, 0.42) * motif * selected * (0.12 + AudioB.w * 0.65 + AudioC.y * 0.35);

    float groutGlow = exp(-min(abs(cell.x) - 0.468, abs(cell.y) - 0.458) * -38.0) * 0.0015;
    color += palette(q.x * 0.16 + q.y * 0.09 + t * 0.009) * groutGlow;
    float bassBloom = exp(-length(q - float2(sin(t * 0.37) * 0.38, 0.24)) * (2.8 - drive * 0.8));
    color += palette(t * 0.025 + 0.58) * bassBloom * (0.018 + AudioC.x * 0.16);
    color *= 1.18 + AudioA.x * 0.42;

    float2 warp = float2(sin(q.y * 2.3 + t * 0.52), cos(q.x * 2.0 - t * 0.43)) *
        (0.00018 + AudioC.w * 0.00065);
    return makeScene(color, warp, 0.86);
}

SceneResult helixReactor(float2 p, float seed)
{
    float helixTime = ResolutionTime.z;
    float helixAspect = ResolutionTime.x / ResolutionTime.y;
    float helixEnergy = audioCurve(AudioA.x + AudioB.x * 0.58 + AudioC.w * 0.44, 1.72);
    float helixBass = audioCurve(AudioA.y + AudioC.x * 1.05 + AudioB.w * 0.34, 1.92);
    float helixVoice = audioCurve(AudioB.x + AudioC.y * 0.82, 1.74);
    float helixSparkle = audioCurve(AudioA.w + AudioC.z * 0.88 + AudioB.z * 0.42, 1.68);
    float2 helixCenter = float2(
        sin(helixTime * 0.19 + seed) * helixAspect * (0.035 + helixVoice * 0.028),
        cos(helixTime * 0.15 + seed * 0.67) * (0.050 + helixVoice * 0.025));
    float2 helixPosition = rotate2(p - helixCenter, sin(helixTime * 0.13 + seed * 0.21) * 0.085);

    float helixCloud = fbm(float2(helixPosition.x * 0.55 + helixTime * 0.045, helixPosition.y * 1.10 - helixTime * 0.031) + seed * 0.017);
    float helixVeil = pow(saturate(1.0 - abs(helixCloud - 0.52) * 4.0), 3.1);
    float3 helixColor = palette(helixCloud * 0.46 + helixPosition.x * 0.045 + helixTime * 0.009) *
        (0.014 + helixVeil * (0.035 + helixEnergy * 0.090));
    float helixAxis = exp(-helixPosition.y * helixPosition.y * (42.0 - helixEnergy * 12.0));
    helixColor += palette(helixPosition.x * 0.10 + helixTime * 0.014 + 0.52) * helixAxis * (0.008 + helixEnergy * 0.040);
    float helixDepthGridX = lineGlow(abs(frac((helixPosition.x / helixAspect + 1.0) * 7.0 - helixTime * 0.12) - 0.5) - 0.485, 0.012);
    float helixDepthGridY = lineGlow(abs(frac((helixPosition.y + 1.0) * 5.0 + helixTime * 0.09) - 0.5) - 0.485, 0.012);
    helixColor += palette(helixPosition.x * 0.08 + helixTime * 0.009 + 0.64) *
        (helixDepthGridX + helixDepthGridY) * (0.004 + helixEnergy * 0.016);

    [unroll]
    for (int helixIndex = 0; helixIndex < 24; helixIndex++)
    {
        float helixLayer = (helixIndex + 0.5) / 24.0;
        float helixFlow = frac(helixLayer - helixTime * (0.055 + Motion.y * 0.040 + helixEnergy * 0.024) + seed * 0.003);
        float helixNextFlow = helixFlow + 0.052;
        float helixSegmentMask = step(helixNextFlow, 1.0);
        int helixBandIndex = (helixIndex * 5 + 2) & 31;
        float helixBandValue = getBand(helixBandIndex);
        float helixWaveValue = smoothReactiveWave(frac(helixFlow + helixTime * 0.018), helixVoice + helixBandValue);
        float helixAngle = helixFlow * TAU * (2.35 + helixVoice * 0.90) + helixTime * (0.38 + Motion.y * 0.42) + seed;
        helixAngle += helixWaveValue * helixVoice * 0.82;
        float helixNextAngle = helixNextFlow * TAU * (2.35 + helixVoice * 0.90) + helixTime * (0.38 + Motion.y * 0.42) + seed;
        float helixRadius = 0.19 + helixBass * 0.13 + helixBandValue * 0.14;
        float helixNextBand = getBand((helixBandIndex + 3) & 31);
        float helixNextRadius = 0.19 + helixBass * 0.13 + helixNextBand * 0.14;
        float helixAxisX = lerp(-helixAspect * 1.33, helixAspect * 1.33, helixFlow);
        float helixNextAxisX = lerp(-helixAspect * 1.33, helixAspect * 1.33, helixNextFlow);
        float3 helixRailA3 = float3(helixAxisX, sin(helixAngle) * helixRadius, 1.58 + cos(helixAngle) * 0.40);
        float3 helixRailB3 = float3(helixAxisX, -sin(helixAngle) * helixRadius, 1.58 - cos(helixAngle) * 0.40);
        float3 helixRailANext3 = float3(helixNextAxisX, sin(helixNextAngle) * helixNextRadius, 1.58 + cos(helixNextAngle) * 0.40);
        float3 helixRailBNext3 = float3(helixNextAxisX, -sin(helixNextAngle) * helixNextRadius, 1.58 - cos(helixNextAngle) * 0.40);
        float2 helixRailA = projectPerspective(helixRailA3, 1.53);
        float2 helixRailB = projectPerspective(helixRailB3, 1.53);
        float2 helixRailANext = projectPerspective(helixRailANext3, 1.53);
        float2 helixRailBNext = projectPerspective(helixRailBNext3, 1.53);
        float helixRailDistance = min(
            segmentDistance(helixPosition, helixRailA, helixRailANext),
            segmentDistance(helixPosition, helixRailB, helixRailBNext));
        float helixRailGlow = lineGlow(helixRailDistance, 0.006 + helixBandValue * 0.008 + helixEnergy * 0.003) * helixSegmentMask;
        float helixRungDistance = segmentDistance(helixPosition, helixRailA, helixRailB);
        float helixRungGate = 0.58 + 0.42 * smoothstep(0.24, 0.82, hash11(helixIndex * 17.13 + floor(Motion.w * 0.25)));
        float helixRungGlow = lineGlow(helixRungDistance, 0.0045 + helixBass * 0.003) * helixRungGate;
        float helixNodeDistance = min(length(helixPosition - helixRailA), length(helixPosition - helixRailB));
        float helixNodeGlow = exp(-helixNodeDistance * helixNodeDistance * (310.0 - helixSparkle * 120.0));
        float helixDepthLight = saturate(2.1 - min(helixRailA3.z, helixRailB3.z)) * 0.55 + 0.48;
        float3 helixRailColor = palette(helixFlow * 0.82 + helixBandValue * 0.18 + helixTime * 0.023);
        helixColor += helixRailColor * helixRailGlow * helixDepthLight * (0.075 + helixEnergy * 0.20 + helixBandValue * 0.62);
        helixColor += lerp(helixRailColor, Palette3.rgb, 0.62) * helixRungGlow * helixDepthLight * (0.050 + helixEnergy * 0.080 + helixBass * 0.24 + AudioB.w * 0.18);
        helixColor += lerp(helixRailColor, Palette3.rgb, 0.78) * helixNodeGlow * (0.020 + helixSparkle * 0.32 + AudioC.z * 0.36);
    }

    float helixBeatFront = frac(Motion.w * 0.25 + seed * 0.011);
    float helixBeatX = lerp(-helixAspect * 1.18, helixAspect * 1.18, helixBeatFront);
    float helixBeatSweep = exp(-abs(helixPosition.x - helixBeatX) * (8.5 - helixBass * 2.0));
    helixColor += palette(helixBeatFront + helixTime * 0.018) * helixBeatSweep * AudioC.x * (0.025 + helixEnergy * 0.095);
    helixColor *= 1.05 + helixEnergy * 0.34;
    float helixWarpWave = smoothReactiveWave(saturate(p.x / helixAspect * 0.5 + 0.5), helixVoice + helixEnergy);
    float2 helixWarp = float2(-0.0011 - helixBass * 0.0020, helixWarpWave * (0.0007 + helixVoice * 0.0013));
    return makeScene(helixColor, helixWarp, 0.842);
}

SceneResult orbitalShardStorm(float2 p, float seed)
{
    float shardTime = ResolutionTime.z;
    float shardEnergy = audioCurve(AudioA.x + AudioC.w * 0.55 + AudioB.x * 0.35, 1.82);
    float shardKick = audioCurve(AudioC.x * 1.55 + AudioA.y * 0.65 + AudioB.w * 0.48, 2.05);
    float shardVoice = audioCurve(AudioB.x + AudioC.y * 0.78, 1.70);
    float shardSparkle = audioCurve(AudioC.z + AudioA.w * 0.82 + AudioB.z * 0.52, 1.86);
    float2 shardCenter = float2(sin(shardTime * 0.17 + seed) * 0.12, cos(shardTime * 0.13 + seed * 0.43) * 0.075);
    float2 shardPosition = p - shardCenter;
    float shardCloud = fbm(float2(shardPosition.x * 0.61 - shardTime * 0.038, shardPosition.y * 0.88 + shardTime * 0.026) + seed * 0.021);
    float shardNebula = pow(saturate(1.0 - abs(shardCloud - 0.50) * 3.8), 3.0);
    float3 shardColor = palette(shardCloud * 0.55 + length(shardPosition) * 0.08 + shardTime * 0.008) *
        (0.015 + shardNebula * (0.040 + shardEnergy * 0.105));

    [unroll]
    for (int shardIndex = 0; shardIndex < 22; shardIndex++)
    {
        float shardLayer = (shardIndex + 0.5) / 22.0;
        float shardRandomA = hash11(shardIndex * 31.17 + floor(seed));
        float shardRandomB = hash11(shardIndex * 73.41 + seed * 0.37);
        int shardBandIndex = (shardIndex * 11 + 3) & 31;
        float shardBandValue = getBand(shardBandIndex);
        float shardDrive = audioCurve(shardBandValue * 1.45 + shardEnergy * 0.24 + AudioB.z * 0.32, 1.62);
        float shardOrbitAngle = shardRandomA * TAU + shardTime * (0.10 + shardEnergy * 0.46 + shardDrive * 0.28) * lerp(-1.0, 1.0, step(0.5, shardRandomB));
        shardOrbitAngle += sin(shardTime * 0.21 + shardIndex) * shardVoice * 0.34;
        float shardOrbitRadius = 0.32 + shardLayer * 0.98 + shardKick * (0.06 + shardRandomB * 0.22);
        float shardDepth = 1.05 + 1.45 * (0.5 + 0.5 * sin(shardOrbitAngle * 0.71 + shardRandomB * TAU));
        float3 shardPosition3 = float3(
            cos(shardOrbitAngle) * shardOrbitRadius,
            sin(shardOrbitAngle) * shardOrbitRadius * (0.58 + shardVoice * 0.12),
            shardDepth);
        shardPosition3 = rotateX3(shardPosition3, sin(seed * 0.12 + shardTime * 0.09) * 0.22);
        float2 shardProjected = projectPerspective(shardPosition3, 1.42);
        float shardOrientation = shardOrbitAngle + shardRandomB * TAU + shardTime * (0.13 + shardSparkle * 0.52);
        float2 shardAxis = float2(cos(shardOrientation), sin(shardOrientation));
        float2 shardSide = float2(-shardAxis.y, shardAxis.x);
        float shardInverseDepth = 1.0 / max(0.55, shardPosition3.z);
        float shardLength = (0.050 + shardDrive * 0.14 + shardKick * 0.055) * shardInverseDepth * 1.7;
        float shardWidth = (0.020 + shardSparkle * 0.034 + shardBandValue * 0.028) * shardInverseDepth * 1.6;
        float2 shardTipA = shardProjected + shardAxis * shardLength;
        float2 shardTipB = shardProjected - shardAxis * shardLength * 0.62;
        float2 shardWing = shardProjected + shardSide * shardWidth;
        float2 shardWingOpposite = shardProjected - shardSide * shardWidth;
        float shardEdgeDistance = min(
            min(segmentDistance(shardPosition, shardTipA, shardWing), segmentDistance(shardPosition, shardWing, shardTipB)),
            min(segmentDistance(shardPosition, shardTipB, shardWingOpposite), segmentDistance(shardPosition, shardWingOpposite, shardTipA)));
        float shardEdgeGlow = lineGlow(shardEdgeDistance, 0.0045 + shardSparkle * 0.0045);
        float2 shardLocal = shardPosition - shardProjected;
        float shardBody = exp(-pow(dot(shardLocal, shardAxis) / max(0.014, shardLength), 2.0) * 2.8 -
            pow(dot(shardLocal, shardSide) / max(0.010, shardWidth), 2.0) * 5.5);
        float2 shardTrailEnd = shardProjected - shardAxis * shardLength * (1.6 + shardDrive * 2.2);
        float shardTrail = lineGlow(segmentDistance(shardPosition, shardProjected, shardTrailEnd), 0.0035 + shardDrive * 0.0030);
        shardTrail *= smoothstep(0.04, 0.24, shardDrive + shardSparkle * 0.36);
        float shardFrontLight = saturate(1.55 - shardPosition3.z * 0.36);
        float3 shardPieceColor = palette(shardLayer * 0.63 + shardRandomA * 0.24 + shardTime * 0.025);
        shardColor += shardPieceColor * shardBody * shardFrontLight * (0.018 + shardDrive * 0.24 + shardKick * 0.10);
        shardColor += lerp(shardPieceColor, Palette3.rgb, 0.56) * shardEdgeGlow * shardFrontLight * (0.024 + shardDrive * 0.46 + shardSparkle * 0.24);
        shardColor += shardPieceColor * shardTrail * shardFrontLight * (0.012 + shardDrive * 0.19);
    }

    float shardLensRadius = length(shardPosition * float2(0.80, 1.0));
    float shardLensRing = lineGlow(shardLensRadius - (0.16 + shardKick * 0.20), 0.020 + shardKick * 0.016);
    float shardLensCore = exp(-shardLensRadius * (7.0 - shardEnergy * 1.8));
    shardColor += palette(shardTime * 0.032 + 0.62) * (shardLensCore * (0.025 + shardEnergy * 0.13) + shardLensRing * AudioC.x * 0.20);
    shardColor *= 1.03 + shardEnergy * 0.30;
    float2 shardWarp = normalize(shardPosition + 0.001).yx * float2(-1.0, 1.0) * (0.0010 + shardEnergy * 0.0022 + shardKick * 0.0028);
    return makeScene(shardColor, shardWarp, 0.872);
}

SceneResult spectralGyroscope(float2 p, float seed)
{
    float gyroTime = ResolutionTime.z;
    float gyroEnergy = audioCurve(AudioA.x + AudioC.w * 0.52 + AudioA.z * 0.36, 1.78);
    float gyroBass = audioCurve(AudioA.y + AudioC.x * 1.10 + AudioB.w * 0.42, 1.92);
    float gyroVoice = audioCurve(AudioB.x + AudioC.y * 0.82, 1.75);
    float gyroSparkle = audioCurve(AudioC.z + AudioA.w * 0.78, 1.72);
    float2 gyroCenter = float2(
        sin(gyroTime * 0.19 + seed) * (0.10 + gyroVoice * 0.07),
        cos(gyroTime * 0.16 + seed * 0.58) * (0.065 + gyroVoice * 0.045));
    float2 gyroPosition = p - gyroCenter;
    float gyroCloud = fbm(float2(gyroPosition.x * 0.48 + gyroTime * 0.025, gyroPosition.y * 0.75 - gyroTime * 0.021) + seed * 0.018);
    float gyroVolume = exp(-length(gyroPosition) * (1.55 - gyroEnergy * 0.35));
    float3 gyroColor = palette(gyroCloud * 0.40 + length(gyroPosition) * 0.12 + gyroTime * 0.008) *
        gyroVolume * (0.018 + gyroEnergy * 0.070);

    [unroll]
    for (int gyroIndex = 0; gyroIndex < 9; gyroIndex++)
    {
        float gyroLayer = gyroIndex / 8.0;
        int gyroBandIndex = min(31, 1 + gyroIndex * 4);
        float gyroBandValue = getBand(gyroBandIndex);
        float gyroDirection = lerp(-1.0, 1.0, step(0.5, frac(gyroIndex * 0.618)));
        float gyroRotation = seed * 0.13 + gyroIndex * 1.37 + gyroTime * gyroDirection *
            (0.09 + Motion.y * 0.16 + gyroEnergy * 0.58 + gyroBandValue * 0.30);
        float gyroFlatten = 0.22 + 0.60 * abs(sin(seed * 0.07 + gyroIndex * 0.91 + gyroTime * (0.08 + gyroVoice * 0.30)));
        gyroFlatten = saturate(gyroFlatten + gyroVoice * 0.10);
        float gyroRadius = 0.20 + gyroLayer * 0.73 + gyroBass * (0.035 + gyroLayer * 0.12) + gyroBandValue * 0.095;
        float2 gyroRingSpace = rotate2(gyroPosition, gyroRotation);
        gyroRingSpace.y /= max(0.18, gyroFlatten);
        float gyroRadiusAtPixel = length(gyroRingSpace);
        float gyroRingDistance = abs(gyroRadiusAtPixel - gyroRadius) * gyroFlatten;
        float gyroAzimuth = atan2(gyroRingSpace.y, gyroRingSpace.x);
        float gyroFront = 0.42 + 0.58 * saturate(0.5 + 0.5 * sin(gyroAzimuth + gyroIndex * 0.73));
        float gyroArcRunner = pow(saturate(0.5 + 0.5 * cos(gyroAzimuth * 2.0 - gyroTime * (1.2 + Motion.y * 1.8) + gyroIndex)), 13.0);
        float gyroRingGlow = lineGlow(gyroRingDistance, 0.0065 + gyroBandValue * 0.0095 + gyroEnergy * 0.0035);
        float gyroMembrane = exp(-gyroRingDistance * (5.2 - gyroEnergy * 1.0)) * smoothstep(0.16, 0.98, gyroRadiusAtPixel / max(0.1, gyroRadius));
        float3 gyroRingColor = palette(gyroLayer * 0.70 + gyroAzimuth / TAU + gyroTime * 0.020);
        gyroColor += gyroRingColor * gyroRingGlow * gyroFront * (0.070 + gyroEnergy * 0.18 + gyroBandValue * 0.58);
        gyroColor += gyroRingColor * gyroMembrane * (0.004 + gyroBandValue * 0.012 + gyroVoice * 0.009);
        gyroColor += lerp(gyroRingColor, Palette3.rgb, 0.72) * gyroRingGlow * gyroArcRunner * (0.035 + gyroSparkle * 0.45 + AudioB.z * 0.22);
    }

    float gyroCoreRadius = length(gyroPosition * float2(0.82, 1.0));
    float gyroCore = exp(-gyroCoreRadius * gyroCoreRadius * (18.0 - gyroBass * 7.0));
    float gyroShockRadius = 0.13 + frac(Motion.w * 0.25 + seed * 0.019) * (0.85 + gyroBass * 0.35);
    float gyroShock = lineGlow(gyroCoreRadius - gyroShockRadius, 0.014 + gyroBass * 0.012) * AudioC.x;
    gyroColor += palette(gyroTime * 0.035 + 0.48) * gyroCore * (0.045 + gyroEnergy * 0.20 + AudioB.w * 0.16);
    gyroColor += palette(gyroShockRadius * 0.30 + 0.72) * gyroShock * (0.050 + gyroBass * 0.24);
    gyroColor *= 1.05 + gyroEnergy * 0.32;
    float2 gyroWarp = normalize(gyroPosition + 0.001).yx * float2(-1.0, 1.0) * (0.0018 + gyroVoice * 0.0034);
    gyroWarp -= normalize(gyroPosition + 0.001) * gyroBass * 0.0028;
    return makeScene(gyroColor, gyroWarp, 0.902);
}

SceneResult liquidChromeTorus(float2 p, float seed)
{
    float torusTime = ResolutionTime.z;
    float torusEnergy = audioCurve(AudioA.x + AudioC.w * 0.48 + AudioA.z * 0.32, 1.76);
    float torusBass = audioCurve(AudioA.y + AudioC.x * 1.08 + AudioB.w * 0.36, 1.92);
    float torusVoice = audioCurve(AudioB.x + AudioC.y * 0.84, 1.72);
    float torusSparkle = audioCurve(AudioC.z + AudioA.w * 0.86 + AudioB.z * 0.35, 1.82);
    float2 torusCenter = float2(
        0.28 * sin(torusTime * 0.17 + seed),
        -0.08 + 0.15 * cos(torusTime * 0.13 + seed * 0.47));
    float2 torusScreen = p - torusCenter;
    float torusBackgroundA = fbm(float2(torusScreen.x * 0.52 + torusTime * 0.028, torusScreen.y * 0.82 - torusTime * 0.019) + seed * 0.014);
    float torusBackgroundB = fbm(float2(torusScreen.y * 0.68 - torusTime * 0.021, -torusScreen.x * 0.43 + torusTime * 0.016) + seed * 0.031);
    float torusCaustic = pow(saturate(1.0 - abs(torusBackgroundA - torusBackgroundB) * 5.2), 9.0);
    float3 torusColor = palette(torusBackgroundA * 0.44 + torusBackgroundB * 0.20 + torusTime * 0.007) *
        (0.018 + torusCaustic * (0.038 + torusEnergy * 0.110));

    float torusPolarRadius = max(0.035, length(torusScreen));
    float torusPolarAngle = atan2(torusScreen.y, torusScreen.x);
    float torusLightRays = pow(saturate(0.5 + 0.5 * sin(torusPolarAngle * 13.0 + torusBackgroundA * 4.0 - torusTime * (0.42 + torusEnergy * 0.55))), 15.0);
    torusLightRays *= smoothstep(0.10, 0.52, torusPolarRadius) * (1.0 - smoothstep(1.20, 2.15, torusPolarRadius));
    torusColor += palette(torusPolarAngle / TAU + torusTime * 0.012 + 0.36) * torusLightRays * (0.008 + torusEnergy * 0.050 + torusSparkle * 0.045);

    [unroll]
    for (int torusFlowIndex = 0; torusFlowIndex < 4; torusFlowIndex++)
    {
        float torusFlowLayer = torusFlowIndex / 3.0;
        float torusFlowBand = getBand(4 + torusFlowIndex * 7);
        float torusFlowPosition = saturate(p.x / (ResolutionTime.x / ResolutionTime.y) * 0.5 + 0.5);
        float torusFlowWave = smoothReactiveWave(frac(torusFlowPosition + torusFlowLayer * 0.11 + torusTime * 0.012), torusVoice + torusFlowBand);
        float torusFlowY = -0.78 + torusFlowLayer * 0.52;
        torusFlowY += sin(p.x * (0.72 + torusFlowLayer * 0.32) - torusTime * (0.18 + torusFlowLayer * 0.10) + seed) * (0.11 + torusEnergy * 0.055);
        torusFlowY += torusFlowWave * (0.025 + torusFlowBand * 0.075 + torusVoice * 0.045);
        float torusFlowGlow = lineGlow(p.y - torusFlowY, 0.010 + torusFlowBand * 0.010);
        torusColor += palette(torusFlowLayer * 0.54 + torusTime * 0.014 + 0.14) * torusFlowGlow *
            (0.015 + torusEnergy * 0.050 + torusFlowBand * 0.10);
    }

    float3 torusRayOrigin = float3(0.0, 0.0, -2.85);
    float3 torusRayDirection = normalize(float3(torusScreen * 0.70, 1.55));
    float torusTiltX = 1.02 + sin(torusTime * 0.13 + seed) * (0.28 + torusVoice * 0.20);
    float torusTiltY = torusTime * (0.075 + torusEnergy * 0.20) + seed * 0.17;
    float torusTravel = 0.0;
    float torusHitMask = 0.0;
    float3 torusHitPosition = 0.0;
    [loop]
    for (int torusStep = 0; torusStep < 40; torusStep++)
    {
        float3 torusWorldPosition = torusRayOrigin + torusRayDirection * torusTravel;
        float3 torusObjectPosition = rotateY3(rotateX3(torusWorldPosition, torusTiltX), torusTiltY);
        float torusStepDistance = reactiveTorusDistance(torusObjectPosition, torusBass, torusVoice, torusSparkle, torusTime);
        if (abs(torusStepDistance) < 0.0035)
        {
            torusHitMask = 1.0;
            torusHitPosition = torusObjectPosition;
            break;
        }
        torusTravel += max(0.006, torusStepDistance * 0.72);
        if (torusTravel > 5.4)
            break;
    }

    if (torusHitMask > 0.5)
    {
        float3 torusNormal = reactiveTorusNormal(torusHitPosition, torusBass, torusVoice, torusSparkle, torusTime);
        float3 torusObjectRay = normalize(rotateY3(rotateX3(torusRayDirection, torusTiltX), torusTiltY));
        float3 torusLightDirection = normalize(float3(-0.42, -0.58, -0.72));
        float torusDiffuse = saturate(dot(torusNormal, torusLightDirection));
        float torusFresnel = pow(1.0 - saturate(dot(-torusObjectRay, torusNormal)), 3.0);
        float3 torusHalfVector = normalize(torusLightDirection - torusObjectRay);
        float torusSpecular = pow(saturate(dot(torusNormal, torusHalfVector)), 42.0 - torusSparkle * 18.0);
        float torusAzimuth = atan2(torusHitPosition.z, torusHitPosition.x);
        int torusBandIndex = (int)clamp(floor(frac(torusAzimuth / TAU + 0.5) * 31.0), 0.0, 31.0);
        float torusBandValue = getBand(torusBandIndex);
        float torusPulse = pow(saturate(0.5 + 0.5 * sin(torusAzimuth * 3.0 - Motion.w * TAU * 0.25)), 9.0);
        float3 torusSurfaceColor = palette(torusAzimuth / TAU + torusNormal.y * 0.22 + torusTime * 0.016);
        float3 torusReflectionColor = palette(torusBackgroundA + torusNormal.x * 0.34 + 0.47);
        torusColor += lerp(torusSurfaceColor, torusReflectionColor, 0.44 + torusFresnel * 0.42) *
            (0.060 + torusDiffuse * 0.24 + torusEnergy * 0.24 + torusBandValue * 0.36);
        torusColor += Palette3.rgb * torusSpecular * (0.34 + torusSparkle * 0.88 + AudioC.z * 0.42);
        torusColor += torusSurfaceColor * torusPulse * (0.018 + torusBandValue * 0.24 + AudioB.w * 0.18);
        float torusChromeStripe = pow(saturate(0.5 + 0.5 * sin(torusNormal.x * 12.0 + torusNormal.y * 8.0 + torusTime * 0.36)), 9.0);
        torusColor += lerp(Palette3.rgb, torusSurfaceColor, 0.30) * torusChromeStripe * (0.025 + torusEnergy * 0.12 + torusSparkle * 0.15);
    }

    float torusShadowRadius = length(torusScreen * float2(0.72, 1.0));
    float torusBassRing = lineGlow(torusShadowRadius - (0.52 + torusBass * 0.30), 0.030 + torusBass * 0.018) * AudioC.x;
    torusColor += palette(torusShadowRadius * 0.28 + torusTime * 0.020 + 0.61) * torusBassRing * (0.035 + torusBass * 0.14);
    float torusHorizontalFlare = exp(-abs(torusScreen.y) * 7.5) * exp(-abs(torusScreen.x) * 0.95);
    torusColor += palette(torusTime * 0.018 + 0.52) * torusHorizontalFlare * (0.006 + torusEnergy * 0.032 + AudioB.w * 0.025);
    torusColor *= 1.05 + torusEnergy * 0.40;
    float2 torusWarp = float2(torusBackgroundB - 0.5, torusBackgroundA - 0.5) * (0.0012 + torusEnergy * 0.0038);
    torusWarp += normalize(torusScreen + 0.001).yx * float2(-1.0, 1.0) * torusVoice * 0.0018;
    return makeScene(torusColor, torusWarp, 0.888);
}

SceneResult chromaticFountain(float2 p, float seed)
{
    float fountainTime = ResolutionTime.z;
    float fountainAspect = ResolutionTime.x / ResolutionTime.y;
    float fountainEnergy = audioCurve(AudioA.x + AudioC.w * 0.52 + AudioB.x * 0.34, 1.78);
    float fountainBass = audioCurve(AudioA.y + AudioC.x * 1.18 + AudioB.w * 0.42, 2.0);
    float fountainVoice = audioCurve(AudioB.x + AudioC.y * 0.82, 1.76);
    float fountainSparkle = audioCurve(AudioC.z + AudioA.w * 0.82 + AudioB.z * 0.55, 1.86);
    float fountainCloud = fbm(float2(p.x * 0.46 + fountainTime * 0.030, p.y * 0.72 - fountainTime * 0.020) + seed * 0.019);
    float fountainCurtain = pow(saturate(1.0 - abs(fountainCloud - 0.52) * 4.1), 2.8);
    float3 fountainColor = palette(fountainCloud * 0.46 + p.y * 0.08 + fountainTime * 0.008) *
        (0.016 + fountainCurtain * (0.036 + fountainEnergy * 0.090));

    float fountainFloorY = 0.82;
    float fountainFloorDistance = max(0.050, fountainFloorY - p.y + 0.08);
    float fountainLaneCoordinate = p.x / fountainFloorDistance;
    float fountainLane = lineGlow(abs(frac(fountainLaneCoordinate * 0.42) - 0.5) - 0.478, 0.014);
    float fountainDepthCoordinate = 0.24 / fountainFloorDistance - fountainTime * (0.48 + Motion.y * 0.42);
    float fountainDepth = lineGlow(abs(frac(fountainDepthCoordinate) - 0.5) - 0.478, 0.014);
    float fountainFloorMask = smoothstep(0.98, fountainFloorY, p.y);
    fountainColor += palette(fountainLaneCoordinate * 0.04 + fountainDepthCoordinate * 0.03 + 0.58) *
        (fountainLane + fountainDepth * (0.65 + fountainBass * 0.72)) * fountainFloorMask * (0.026 + fountainEnergy * 0.075);

    float fountainFanAngle = atan2(p.y - fountainFloorY, p.x);
    float fountainFanRadius = length(float2(p.x / fountainAspect, (p.y - fountainFloorY) * 0.72));
    float fountainFan = pow(saturate(0.5 + 0.5 * sin(fountainFanAngle * 17.0 - fountainTime * (0.38 + fountainEnergy * 0.72))), 18.0);
    fountainFan *= smoothstep(0.05, 0.42, fountainFanRadius) * smoothstep(1.55, 0.42, fountainFanRadius);
    fountainColor += palette(fountainFanAngle / TAU + fountainTime * 0.016 + 0.44) * fountainFan * (0.006 + fountainEnergy * 0.050 + fountainSparkle * 0.030);

    [unroll]
    for (int fountainIndex = 0; fountainIndex < 52; fountainIndex++)
    {
        float fountainLayer = (fountainIndex + 0.5) / 52.0;
        float fountainRandomA = hash11(fountainIndex * 41.37 + floor(seed));
        float fountainRandomB = hash11(fountainIndex * 87.11 + seed * 0.29);
        int fountainBandIndex = (fountainIndex * 13 + 1) & 31;
        float fountainBandValue = getBand(fountainBandIndex);
        float fountainLaunch = audioCurve(fountainBandValue * 1.58 + AudioB.z * 0.42 + AudioC.y * 0.32, 1.74);
        float fountainLife = frac(fountainTime * (0.13 + Motion.y * 0.10 + fountainEnergy * 0.16) + fountainRandomA + fountainLayer * 0.37);
        float fountainLifeFade = smoothstep(0.01, 0.10, fountainLife) * smoothstep(1.0, 0.78, fountainLife);
        float fountainEmitter = lerp(-1.18, 1.18, frac(fountainLayer * 7.0 + fountainRandomB * 0.18));
        float fountainHeight = sin(fountainLife * PI) * (0.22 + fountainLaunch * 1.34 + fountainBass * 0.24);
        float fountainSpread = (fountainLife - 0.5) * (0.22 + fountainVoice * 0.68) * lerp(-1.0, 1.0, step(0.5, fountainRandomB));
        float fountainSwirl = sin(fountainLife * TAU * (1.2 + fountainRandomA) + fountainTime * 0.42 + fountainIndex) *
            fountainVoice * (0.035 + fountainLife * 0.070);
        float fountainParticleDepth = 1.0 + fountainRandomB * 1.55 + cos(fountainLife * PI) * 0.22;
        float3 fountainParticle3 = float3(fountainEmitter + fountainSpread + fountainSwirl, fountainHeight, fountainParticleDepth);
        float2 fountainProjected = projectPerspective(fountainParticle3, 1.34);
        fountainProjected.y = fountainFloorY - fountainProjected.y;
        float fountainPreviousLife = max(0.0, fountainLife - 0.055);
        float fountainPreviousHeight = sin(fountainPreviousLife * PI) * (0.22 + fountainLaunch * 1.34 + fountainBass * 0.24);
        float fountainPreviousSpread = (fountainPreviousLife - 0.5) * (0.22 + fountainVoice * 0.68) * lerp(-1.0, 1.0, step(0.5, fountainRandomB));
        float fountainPreviousSwirl = sin(fountainPreviousLife * TAU * (1.2 + fountainRandomA) + fountainTime * 0.42 + fountainIndex) *
            fountainVoice * (0.035 + fountainPreviousLife * 0.070);
        float3 fountainPrevious3 = float3(fountainEmitter + fountainPreviousSpread + fountainPreviousSwirl, fountainPreviousHeight, fountainParticleDepth);
        float2 fountainPreviousProjected = projectPerspective(fountainPrevious3, 1.34);
        fountainPreviousProjected.y = fountainFloorY - fountainPreviousProjected.y;
        float fountainParticleDistance = length(p - fountainProjected);
        float fountainParticleCore = exp(-fountainParticleDistance * fountainParticleDistance * (270.0 - fountainSparkle * 95.0));
        float fountainTrailDistance = segmentDistance(p, fountainPreviousProjected, fountainProjected);
        float fountainTrailGlow = lineGlow(fountainTrailDistance, 0.0045 + fountainLaunch * 0.0060);
        float fountainDepthLight = 1.0 / max(0.72, fountainParticleDepth);
        float fountainActivation = smoothstep(0.018, 0.135, fountainLaunch + fountainEnergy * 0.30);
        float3 fountainParticleColor = palette(fountainLayer * 0.78 + fountainBandValue * 0.20 + fountainTime * 0.024);
        fountainColor += fountainParticleColor * fountainTrailGlow * fountainLifeFade * fountainActivation * fountainDepthLight *
            (0.035 + fountainLaunch * 0.42 + fountainVoice * 0.14);
        fountainColor += lerp(fountainParticleColor, Palette3.rgb, 0.68) * fountainParticleCore * fountainLifeFade * fountainActivation * fountainDepthLight *
            (0.080 + fountainLaunch * 0.72 + fountainSparkle * 0.44);
    }

    float fountainEmitterGlow = exp(-abs(p.y - fountainFloorY) * 17.0) * exp(-abs(p.x) * 1.6);
    float fountainShockRadius = frac(Motion.w * 0.25 + seed * 0.013) * 1.18;
    float fountainShock = lineGlow(length(float2(p.x / fountainAspect, (p.y - fountainFloorY) * 0.42)) - fountainShockRadius, 0.018 + fountainBass * 0.018);
    fountainColor += palette(p.x * 0.09 + fountainTime * 0.020 + 0.46) * fountainEmitterGlow * (0.012 + fountainEnergy * 0.080 + fountainBass * 0.055);
    fountainColor += palette(fountainShockRadius * 0.30 + 0.68) * fountainShock * AudioC.x * (0.045 + fountainBass * 0.18);
    fountainColor *= 1.04 + fountainEnergy * 0.38;
    float2 fountainWarp = float2((fountainCloud - 0.5) * (0.0010 + AudioC.w * 0.0025), 0.0012 + fountainBass * 0.0038);
    return makeScene(fountainColor, fountainWarp, 0.856);
}

float3 sampleFeedback(float2 uv, float2 warp, float blurAmount)
{
    float2 sampleUv = uv + warp;
    float2 diagonal = float2(ResolutionTime.y / ResolutionTime.x, 1.0) * blurAmount;
    float3 color = PreviousFrame.SampleLevel(LinearMirror, sampleUv, 0).rgb * 0.52;
    color += PreviousFrame.SampleLevel(LinearMirror, sampleUv + diagonal, 0).rgb * 0.12;
    color += PreviousFrame.SampleLevel(LinearMirror, sampleUv - diagonal, 0).rgb * 0.12;
    color += PreviousFrame.SampleLevel(LinearMirror, sampleUv + diagonal * float2(1.0, -1.0), 0).rgb * 0.12;
    color += PreviousFrame.SampleLevel(LinearMirror, sampleUv + diagonal * float2(-1.0, 1.0), 0).rgb * 0.12;
    return color;
}

float3 sampleTransitionFrame(float2 uv, float2 warp, float blurAmount)
{
    float2 sampleUv = uv + warp;
    float2 spread = float2(ResolutionTime.y / ResolutionTime.x, 1.0) * blurAmount;
    float3 color = TransitionFrame.SampleLevel(LinearMirror, sampleUv, 0).rgb * 0.60;
    color += TransitionFrame.SampleLevel(LinearMirror, sampleUv + spread, 0).rgb * 0.10;
    color += TransitionFrame.SampleLevel(LinearMirror, sampleUv - spread, 0).rgb * 0.10;
    color += TransitionFrame.SampleLevel(LinearMirror, sampleUv + spread * float2(1.0, -1.0), 0).rgb * 0.10;
    color += TransitionFrame.SampleLevel(LinearMirror, sampleUv + spread * float2(-1.0, 1.0), 0).rgb * 0.10;
    return color;
}

float2 scenePosition(VertexOutput input)
{
    float2 sceneUv = input.uv;
    if (Modes.y >= 32.0)
    {
        float virtualHeight = min(360.0, ResolutionTime.y);
        float2 grid = float2(virtualHeight * ResolutionTime.x / ResolutionTime.y, virtualHeight);
        sceneUv = (floor(sceneUv * grid) + 0.5) / grid;
    }
    float2 p = sceneUv * 2.0 - 1.0;
    p.x *= ResolutionTime.x / max(1.0, ResolutionTime.y);
    bool roamingScene = abs(Modes.y - 23.0) < 0.5 || abs(Modes.y - 24.0) < 0.5
        || abs(Modes.y - 27.0) < 0.5 || abs(Modes.y - 29.0) < 0.5;
    if (roamingScene)
    {
        // Integrated musical travel and coherent noise avoid frame-random camera jitter.
        float travel = Stage.x;
        float phase = Modes.y * 1.73 + Presets.y * 0.07;
        float2 wander = float2(noise21(float2(travel * 0.16, phase)),
            noise21(float2(travel * 0.13, phase + 8.0))) * 2.0 - 1.0;
        float aspect = ResolutionTime.x / max(1.0, ResolutionTime.y);
        float horizontalRoom = max(0.0, aspect - 1.18);
        float2 pan = float2(wander.x * min(0.52, horizontalRoom), wander.y * 0.09);
        float roll = sin(travel * 0.29 + phase) * 0.14;
        float zoom = 1.0 + sin(travel * 0.37 + phase) * 0.065;
        return rotate2(p - pan, roll) * zoom * max(1.0, 1.35 / aspect);
    }

    return p;
}

float3 sceneEnvironment(float2 p, int modeId)
{
    float t = Stage.x;
    float activity = Dynamics.x;
    float level = 0.025 + activity * 0.14;
    float3 backdrop = 0.0;
    if (modeId == 22 || modeId == 28)
    {
        // A receding reflective floor with broad moving caustics.
        float floorMask = smoothstep(0.1, 0.65, p.y);
        float2 floorUv = float2(p.x, 0.65) / max(0.22, p.y + 0.3);
        float caustic = sin(floorUv.x * 5.0 + sin(floorUv.y * 4.0 + t)) *
            sin(floorUv.y * 6.0 - t * 1.8 + cos(floorUv.x * 3.0));
        float facets = pow(1.0 - abs(caustic), 8.0);
        backdrop = palette(floorUv.y * 0.13 + caustic * 0.1) * floorMask *
            (0.035 + facets * (0.07 + AudioA.y * 0.28)) * (0.2 + activity);
        float rays = pow(max(0.0, cos(p.x * 2.6 + p.y * 1.1 + t * 0.3)), 8.0);
        backdrop += palette(p.x * 0.1 + 0.6) * rays * level * 0.38;
    }
    else if (modeId == 23)
    {
        float curtain = pow(0.5 + 0.5 * sin(p.x * 3.0 + sin(p.y * 2.0 + t * 0.7)), 4.0);
        float crossLight = pow(0.5 + 0.5 * cos(p.x * 1.8 - p.y * 2.2 - t * 0.4), 6.0);
        backdrop = palette(p.y * 0.12 + t * 0.02) * curtain * level;
        backdrop += palette(p.x * 0.13 + 0.4) * crossLight * level * 0.7;
    }
    else if (modeId == 24 || modeId == 26)
    {
        float2 q = rotate2(p, t * 0.09);
        float heightField = sin(q.x * 2.2 + t * 0.4) * cos(q.y * 3.0 - t * 0.3);
        float folds = pow(0.5 + heightField * 0.5, 3.0);
        float contours = pow(1.0 - abs(sin(heightField * 10.0 + t * 0.3)), 16.0);
        backdrop = palette(heightField * 0.2 + 0.35) * (folds * level * 0.65 + contours * level * 0.24);
    }
    else if (modeId == 25)
    {
        float layerA = fbm(p * 1.4 + float2(t * 0.13, -t * 0.11));
        float layerB = fbm(p * 2.2 + layerA * 1.8 - t * 0.07);
        float pigment = smoothstep(0.38, 0.7, layerB);
        backdrop = palette(layerA * 0.6 + 0.35) * pigment * level * 0.8;
    }
    else if (modeId == 27 || modeId == 29)
    {
        float2 q = rotate2(p, -t * 0.18);
        float r = length(q * float2(0.75, 1.0));
        float a = atan2(q.y, q.x);
        float relief = 0.5 + 0.5 * sin(a * (modeId == 27 ? 5.0 : 7.0) + r * 5.0 - t * 0.65);
        float petals = pow(relief, 6.0) * smoothstep(0.15, 0.7, r);
        float rings = pow(max(0.0, cos(r * 12.0 - t * 1.3)), 12.0);
        backdrop = palette(r * 0.16 + a / TAU * 0.2 + 0.45) * petals * level;
        backdrop += palette(r * 0.2 + 0.1) * rings * level * 0.28;
    }
    else if (modeId == 30)
    {
        float sky = fbm(float2(p.x * 0.55 + t * 0.04, p.y * 1.4));
        float curtains = pow(max(0.0, sin(p.x * 2.0 + sky * 4.0 + t * 0.3)), 3.0);
        backdrop = palette(sky * 0.5 + p.x * 0.08) * curtains * level * 0.75;
        float horizon = exp(-abs(p.y - 0.58) * 8.0);
        backdrop += palette(p.x * 0.1 + 0.5) * horizon * level * 0.8;
    }
    else if (modeId == 31)
    {
        // Restrained CRT phosphor field behind the bouncing mark.
        float2 tiles = p * float2(16.0, 12.0);
        float2 cell = floor(tiles);
        float dotMask = exp(-dot(frac(tiles) - 0.5, frac(tiles) - 0.5) * 170.0);
        float sweep = pow(max(0.0, cos(cell.x * 0.2 + cell.y * 0.13 - t * 0.6)), 10.0);
        backdrop = palette(cell.x * 0.012 + cell.y * 0.009 + Stage.y) * dotMask * sweep * level * 0.75;
    }
    return backdrop;
}

float2 accentCameraUv(float2 uv)
{
    float aspect = ResolutionTime.x / max(1.0, ResolutionTime.y);
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float c = abs(cos(Camera.z));
    float s = abs(sin(Camera.z));
    // Fit the rotated/translated viewport inside the source image. No mirrored
    // borders and no permanent zoom when the camera has settled.
    float fitX = (aspect - 2.0 * abs(Camera.x)) / (aspect * c + s);
    float fitY = (1.0 - 2.0 * abs(Camera.y)) / (c + aspect * s);
    float fit = max(0.1, min(1.0, min(fitX, fitY))) / (1.0 + Camera.w);
    return (rotate2(p, Camera.z) * fit + Camera.xy) / float2(aspect, 1.0) + 0.5;
}

float3 filterSample(float2 uv)
{
    return PreviousFrame.SampleLevel(LinearMirror, uv, 0).rgb;
}

float3 filteredScene(float2 uv)
{
    float3 base = filterSample(uv);
    float amount = Filter.y;
    if (amount <= 0.0) return base;
    int style = (int)round(Filter.x);
    float2 pixel = 1.0 / ResolutionTime.xy;
    float2 direction = float2(cos(Filter.z), sin(Filter.z));
    float2 offset = direction * float2(ResolutionTime.y / ResolutionTime.x, 1.0);
    float3 color = base;
    [branch] if (style == 0)
    {
        // Keep the primary exposure crisp; only the displaced copy is softened.
        float2 ghostUv = uv + offset * (0.008 + amount * 0.014);
        float2 blur = pixel * (0.5 + Filter.w * 2.5);
        float3 ghost = (filterSample(ghostUv) * 2.0 + filterSample(ghostUv + blur) + filterSample(ghostUv - blur)) * 0.25;
        color = base * 0.9 + ghost * 0.32;
    }
    else if (style == 1)
    {
        // Deliberate chunky square tiles, with native-resolution seams and no bilinear enlargement.
        float cell = max(6.0, floor(ResolutionTime.y / 1080.0 * (10.0 + floor(Filter.w * 7.0))));
        float2 grid = ResolutionTime.xy / cell;
        float2 center = (floor(uv * grid) + 0.5) / grid;
        float3 mosaic = filterSample(center) * 0.5;
        mosaic += (filterSample(center + pixel * cell * 0.25) + filterSample(center - pixel * cell * 0.25)) * 0.25;
        float2 tile = abs(frac(uv * grid) - 0.5) * cell;
        float seam = smoothstep(cell * 0.5 - 1.1, cell * 0.5, max(tile.x, tile.y));
        color = mosaic * (1.0 - seam * 0.20);
    }
    else if (style == 2)
    {
        float3 bleed = 0.0;
        [unroll] for (int i = 1; i <= 4; i++)
            bleed += filterSample(uv - offset * i * 0.0025) * (5.0 - i) / 10.0;
        bleed = max(0.0, bleed - min(bleed.r, min(bleed.g, bleed.b)) * 0.8);
        color = base + bleed * 0.42;
    }
    else if (style == 3)
    {
        float2 split = (uv - 0.5) * (0.006 + Filter.w * 0.012) + offset * 0.002;
        color = float3(filterSample(uv + split).r, base.g, filterSample(uv - split).b);
    }
    else if (style == 4)
    {
        float scan = 0.84 + 0.16 * cos(uv.y * ResolutionTime.y * PI);
        int channel = (int)floor(uv.x * ResolutionTime.x) % 3;
        float3 phosphor = channel == 0 ? float3(1.12, 0.92, 0.92) :
            (channel == 1 ? float3(0.92, 1.12, 0.92) : float3(0.92, 0.92, 1.12));
        color = base * phosphor * scan * 1.07;
    }
    else if (style == 5)
    {
        float luma = dot(base, float3(0.2126, 0.7152, 0.0722));
        float3 sheen = 0.5 + 0.5 * cos(TAU * (luma * 1.5 + dot(uv, direction) * 0.5 + Filter.w) + float3(0, 2.1, 4.2));
        color = lerp(base, sheen * max(base.r, max(base.g, base.b)), 0.65);
    }
    else if (style == 6)
    {
        float3 dx = filterSample(uv + float2(pixel.x * 2, 0)) - filterSample(uv - float2(pixel.x * 2, 0));
        float3 dy = filterSample(uv + float2(0, pixel.y * 2)) - filterSample(uv - float2(0, pixel.y * 2));
        float3 edge = sqrt(dx * dx + dy * dy);
        color = base * 0.86 + edge * (0.65 + Filter.w * 0.3);
    }
    else if (style == 7)
    {
        float2 radial = uv - float2(0.5 + cos(Filter.z) * 0.12, 0.5 + sin(Filter.z) * 0.12);
        float3 echo = 0;
        [unroll] for (int i = 1; i <= 3; i++)
            echo += filterSample(uv - radial * i * (0.012 + Filter.w * 0.012)) / (i + 2.0);
        color = base * 0.92 + echo * 0.42;
    }
    else if (style == 8)
    {
        // Fixed pin grid: preserve the source hue while intensity controls dot size.
        float cell = max(4.0, floor(ResolutionTime.y / 1080.0 * (6.0 + Filter.w * 3.0)));
        float2 grid = ResolutionTime.xy / cell;
        float2 pin = floor(uv * grid);
        float2 center = (pin + 0.5) / grid;
        float3 source = filterSample(center);
        float intensity = max(source.r, max(source.g, source.b));
        float radius = 0.43 * sqrt(saturate(intensity));
        float distance = length(frac(uv * grid) - 0.5);
        float aa = 0.7 / cell;
        float dotInk = (1.0 - smoothstep(max(0.0, radius - aa), radius + aa, distance)) * smoothstep(0.005, 0.04, intensity);
        float3 ink = source / max(intensity, 0.001);
        // Every ninth pin row is slightly lighter, recalling a nine-pin print head.
        float headStripe = ((int)pin.y % 9 == 8) ? 0.84 : 1.0;
        color = ink * dotInk * headStripe;
    }
    else if (style == 9)
    {
        // Film stock renews at 24 Hz regardless of display refresh. Grain is local, not a global flash.
        float frame = floor(ResolutionTime.z * 24.0);
        float2 grainCell = floor(uv * ResolutionTime.xy / (1.4 + Filter.w * 1.6));
        float grain = (hash21(grainCell + frame * float2(17.1, 39.7)) +
            hash21(grainCell * 1.37 + frame * float2(43.3, 11.9)) - 1.0);
        float luma = dot(base, float3(0.2126, 0.7152, 0.0722));
        float density = sqrt(saturate(luma)) * (0.55 + Filter.w * 0.25);
        color = max(0.0, base * (1.0 + grain * 0.7) + grain * density);
    }
    else if (style == 10)
    {
        // Anaglyph-style two-eye exposure, not stereoscopic scene rendering.
        float separation = (0.004 + Filter.w * 0.009) * (1.0 + sin(ResolutionTime.z * 0.55) * 0.15);
        float2 eye = float2(separation * ResolutionTime.y / ResolutionTime.x, 0);
        float3 leftEye = filterSample(uv - eye);
        float3 rightEye = filterSample(uv + eye);
        float leftLight = dot(leftEye, float3(0.35, 0.45, 0.20));
        float rightLight = dot(rightEye, float3(0.35, 0.45, 0.20));
        color = float3(max(leftEye.r, leftLight * 0.8), max(rightEye.g, rightLight * 0.65),
            max(rightEye.b, rightLight * 0.85));
    }
    else if (style == 11)
    {
        float t = ResolutionTime.z;
        float tracking = frac(t * 0.075 + Filter.w);
        float band = exp(-pow((uv.y - tracking) / 0.035, 2.0));
        float shift = band * sin(uv.y * 85.0 + t * 2.0) * 0.008;
        float2 tapeUv = uv + float2(shift, 0);
        float3 tape = filterSample(tapeUv);
        float3 delayed = filterSample(tapeUv - float2(0.004 + Filter.w * 0.005, 0));
        float luma = dot(tape, float3(0.299, 0.587, 0.114));
        float delayedLuma = dot(delayed, float3(0.299, 0.587, 0.114));
        color = max(0.0, luma.xxx + (delayed - delayedLuma) * 0.85);
        color *= 0.94 + 0.06 * cos(uv.y * ResolutionTime.y * PI);
        color = lerp(color, tape * 0.7, band * 0.25);
    }
    else if (style == 12)
    {
        float t = ResolutionTime.z;
        float pitch = 10.0 + floor(Filter.w * 10.0);
        float lens = sin(uv.x * ResolutionTime.x / pitch * TAU + t * 0.9);
        float2 refractUv = uv + float2(lens * pixel.x * (2.0 + Filter.w * 3.0), 0);
        float3 lenticular = filterSample(refractUv);
        float3 coating = 0.84 + 0.26 * (0.5 + 0.5 * cos(lens * 1.4 + t * 0.3 + float3(0, 2.1, 4.2)));
        color = lenticular * coating;
    }
    else if (style == 13)
    {
        float t = ResolutionTime.z;
        float aspect = ResolutionTime.x / ResolutionTime.y;
        float2 center = float2(0.5 + sin(t * 0.19 + Filter.z) * 0.30, 0.5 + cos(t * 0.23) * 0.26);
        float2 local = (uv - center) * float2(aspect, 1.0);
        float radius = 0.23 + Filter.w * 0.13;
        float r = length(local) / radius;
        float lens = pow(saturate(1.0 - r * r), 2.0);
        float2 bend = local / float2(aspect, 1.0) * lens * 0.28;
        float3 glass = filterSample(uv - bend);
        glass.r = filterSample(uv - bend * 1.08).r;
        glass.b = filterSample(uv - bend * 0.92).b;
        color = glass * (1.0 + lens * 0.06);
    }
    // The raster styles must fully replace the source, otherwise fine lines leak through the grid.
    color = lerp(base, color, (style == 1 || style == 8) ? 1.0 : amount);
    // A stable per-visit color grade, not frame-random flicker. Black remains black.
    float3 grade = 0.88 + 0.24 * (0.5 + 0.5 * cos(Filter.w * TAU + float3(0, 2.1, 4.2)));
    return saturate(color * lerp(float3(1, 1, 1), grade, amount));
}

float4 PSTransitionBlend(VertexOutput input) : SV_Target
{
    float t = saturate(Motion.z);
    float envelope = sin(t * PI);
    float2 uv = input.uv;
    float2 incomingUv = accentCameraUv(uv);
    float3 incoming = filteredScene(incomingUv);
    // Camera motion is presentation-only: never feed it back into scene trails.
    if (t >= 1.0) return float4(incoming, 1.0);
    float2 direction = float2(cos(Presets.y), sin(Presets.y));
    float2 drift = direction * (0.012 * envelope);
    int style = ((int)round(Modes.x) + (int)round(Modes.y)) % 3;
    if (style == 1)
    {
        float2 centered = uv - 0.5;
        drift = float2(-centered.y, centered.x) * envelope * 0.035;
    }
    else if (style == 2)
    {
        drift = float2(sin(uv.y * 6.0 + t * 3.0), cos(uv.x * 5.0 - t * 2.0)) * envelope * 0.009;
    }
    float3 outgoing = TransitionFrame.SampleLevel(LinearMirror, uv + drift, 0).rgb;
    if (style == 2)
    {
        float2 separation = direction * envelope * 0.003;
        outgoing.r = TransitionFrame.SampleLevel(LinearMirror, uv + drift + separation, 0).r;
        outgoing.b = TransitionFrame.SampleLevel(LinearMirror, uv + drift - separation, 0).b;
    }
    // Blend light, not display values: overlapping colors stay luminous at midpoint.
    float3 light = lerp(pow(saturate(outgoing), 2.2), pow(saturate(incoming), 2.2), t);
    float impact = saturate(Dynamics.y);
    float activity = saturate(Dynamics.x);
    float2 flareOffset = direction * envelope * (0.008 + 0.008 * impact);
    float3 carried = TransitionFrame.SampleLevel(LinearMirror, uv + drift + flareOffset, 0).rgb;
    float3 arriving = incoming;
    float3 chroma = max(carried, arriving);
    chroma = max(0.0, chroma - min(chroma.r, min(chroma.g, chroma.b)) * 0.7);
    float crest = pow(0.5 + 0.5 * sin(dot(uv, direction) * 8.0 - t * 5.0), 3.0);
    float flare = envelope * envelope * (0.05 + activity * 0.10 + impact * 0.12);
    light += pow(chroma, 2.2) * flare * (0.35 + crest * 0.65);
    return float4(pow(saturate(light), 1.0 / 2.2), 1.0);
}

float4 composeScene(VertexOutput input, float2 p, SceneResult scene, int currentMode)
{
    float2 uv = input.uv;
    if (currentMode == 7)
        return float4(pow(1.0 - exp(-max(0.0, scene.color) * 1.8), 0.85), 1.0);
    if (currentMode == 27)
        return float4(pow(1.0 - exp(-max(0.0, scene.color) * 2.8), 0.85), 1.0);
    if (currentMode == 22)
    {
        float dt = ResolutionTime.w;
        float presence = max(noteMotion(AudioA.y), max(noteMotion(AudioB.x), noteMotion(AudioA.w)));
        float aspect = ResolutionTime.x / max(1.0, ResolutionTime.y);
        float2 q = (uv - 0.5) * float2(aspect, 1.0);
        float2 pivot = float2(sin(Stage.x * 0.23) * 0.20, cos(Stage.x * 0.19) * 0.12);
        float2 flow = q - pivot;
        float curl = sin(flow.y * 3.0 + Stage.x * 0.3) * 0.22 + sin(Stage.x * 0.17) * 0.14;
        flow = rotate2(flow, dt * curl) * exp(-dt * (0.18 + presence * 0.24));
        flow += float2(sin(q.y * 4.0 + Stage.x * 0.3), cos(q.x * 3.0 - Stage.x * 0.2)) * dt * 0.028;
        float2 sourceUv = (flow + pivot) / float2(aspect, 1.0) + 0.5;
        float3 past = PreviousFrame.SampleLevel(LinearMirror, sourceUv, 0).rgb;
        float inBounds = step(0.0, sourceUv.x) * step(sourceUv.x, 1.0) * step(0.0, sourceUv.y) * step(sourceUv.y, 1.0);
        // Advect colored light with a time-based decay; max blending cannot build white haze.
        float retention = exp(-dt * lerp(7.0, 2.5, presence));
        float3 retained = pow(saturate(past), 1.8) * retention * inBounds;
        float sourceLuma = dot(scene.color, float3(0.2126, 0.7152, 0.0722));
        float3 sourceColor = max(0.0, lerp(sourceLuma.xxx, scene.color, 1.55));
        float3 fresh = 1.0 - exp(-sourceColor * 2.5);
        float3 result = pow(saturate(max(fresh, retained)), 1.0 / 1.8);
        return float4(result, 1.0);
    }
    // Transitions are composed after feedback, never accumulated into scene trails.
    float transition = 1.0;
    float transitionArc = sin(transition * PI);
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float screenU = saturate(p.x / aspect * 0.5 + 0.5);
    int previousMode = (int)round(Modes.x);
    bool radialScene = currentMode == 1 || currentMode == 2 || currentMode == 8 || currentMode == 12 ||
        currentMode == 19 || currentMode == 20 || currentMode == 21;
    bool previousRadialScene = previousMode == 1 || previousMode == 2 || previousMode == 8 || previousMode == 12 ||
        previousMode == 19 || previousMode == 20 || previousMode == 21;
    bool linearScene = currentMode == 5 || currentMode == 7 || currentMode == 11 || (currentMode >= 14 && currentMode <= 16) || currentMode == 18;
    bool previousLinearScene = previousMode == 5 || previousMode == 7 || previousMode == 11 || (previousMode >= 14 && previousMode <= 16) || previousMode == 18;
    bool floorScene = currentMode == 17;
    bool previousFloorScene = previousMode == 17;
    bool risingScene = currentMode == 22;
    bool previousRisingScene = previousMode == 22;
    float revealMask = 1.0;
    float transitionAccent = 0.0;
    float3 surfaceColor = scene.color;
    if (currentMode >= 22 && currentMode != 31)
    {
        float neutralFloor = min(surfaceColor.r, min(surfaceColor.g, surfaceColor.b));
        surfaceColor = max(0.0, surfaceColor - min(0.055, neutralFloor));
    }
    float3 emission = surfaceColor * (0.018 + revealMask * 0.982);
    if (currentMode >= 22)
    {
        if (currentMode < 32 && currentMode != 22 && currentMode != 26 && currentMode != 31 && currentMode != 25 && currentMode != 28 && currentMode != 29 && currentMode != 30)
            emission += sceneEnvironment(p, currentMode) * revealMask * 0.38;
        emission *= (currentMode == 31 ? 2.0 : 2.8);
    }
    float motionGovernor = (0.58 + Dynamics.x * 0.27 + Dynamics.y * 0.15) * lerp(0.84, 1.0, Dynamics.z);
    float2 warp = scene.warp * Feedback.y * (0.28 + revealMask * 0.72) * motionGovernor;
    float2 radial = normalize(p + 0.001);
    [branch]
    if (radialScene)
    {
        warp += radial.yx * float2(-1.0, 1.0) * transitionArc * (0.0025 + AudioB.w * 0.0035);
        warp -= radial * transitionArc * (0.002 + AudioC.x * 0.004);
    }
    else if (risingScene || previousRisingScene)
    {
        warp += float2(sampleWave(screenU) * transitionArc * 0.0012, transitionArc * (0.0030 + AudioA.y * 0.0035));
    }
    else if (linearScene || previousLinearScene)
    {
        warp += float2(-transitionArc * (0.0025 + AudioA.y * 0.002), sampleWave(screenU) * transitionArc * 0.0015);
    }
    else
    {
        warp += float2(fbm(p * 1.2) - 0.5, fbm(p.yx * 1.1 + 3.7) - 0.5) * transitionArc * 0.0035;
    }
    float blur = transitionArc * (0.0042 + AudioC.w * 0.0048 + AudioB.w * 0.0032);
    blur *= lerp(1.12, 0.92, Dynamics.z);
    float3 history = sampleFeedback(uv, warp, blur);
    if (currentMode >= 32)
    {
        float virtualHeight = min(360.0, ResolutionTime.y);
        float2 grid = float2(virtualHeight * ResolutionTime.x / ResolutionTime.y, virtualHeight);
        float2 historyUv = (floor((uv + warp) * grid) + 0.5) / grid;
        history = PreviousFrame.SampleLevel(LinearMirror, historyUv, 0).rgb;
    }
    history *= smoothstep(0.04, 0.38, transition) * (0.12 + revealMask * 0.88);
    float persistence = lerp(0.998, scene.persistence * Feedback.x, revealMask);
    persistence *= lerp(1.0, 0.94 + AudioA.x * 0.035, revealMask);
    persistence *= lerp(0.88, 1.0, Dynamics.z);

    emission += palette(screenU * 0.2 + transition) * transitionAccent * (0.055 + AudioA.z * 0.075 + AudioB.w * 0.13);
    emission *= 0.82 + AudioA.x * 0.55 + AudioB.w * 0.12;

    float historyGamma = lerp(1.03, 1.55, revealMask);
    float historyWeight = lerp(0.995, 0.88, revealMask);
    float3 historyLinear = pow(saturate(history), historyGamma);
    float3 colorLinear = historyLinear * persistence * historyWeight + emission * (0.32 + transitionArc * 0.16);
    colorLinear = 1.0 - exp(-max(colorLinear, 0.0) * 0.96);
    float3 color = pow(saturate(colorLinear), 0.72);
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = lerp(luma.xxx, color, 1.10 + Feedback.w * 0.12);
    color = smoothstep(0.035, 0.93, color);
    float maxChannel = max(color.r, max(color.g, color.b));
    float softCeiling = lerp(0.86, 1.0, Dynamics.z) + Dynamics.y * 0.05;
    float compressedPeak = softCeiling + max(0.0, maxChannel - softCeiling) * 0.24;
    color *= maxChannel > 0.0001 ? min(1.0, compressedPeak / maxChannel) : 1.0;

    if (currentMode >= 22 || currentMode == 1)
    {
        // Decode the previous display frame before fading; never accumulate
        // already tone-mapped color, which makes trails grow into white smears.
        float trailRate = lerp(14.0, 5.2, Dynamics.x) + Dynamics.w * 2.0;
        if (currentMode == 24 || currentMode == 26) trailRate += 3.0;
        if (currentMode == 31) trailRate = 28.0;
        if (currentMode >= 32) trailRate = 5.0;
        float retention = exp(-ResolutionTime.w * trailRate);
        float historyPeak = max(history.r, max(history.g, history.b));
        float trailMask = smoothstep(0.22, 0.48, historyPeak);
        float neutralHistory = min(history.r, min(history.g, history.b));
        float3 chromaticHistory = max(0.0, history - neutralHistory * 0.12);
        float3 trailLinear = pow(saturate(chromaticHistory), 1.8) * retention * trailMask;
        if (currentMode == 23 || currentMode == 24 || currentMode == 27) trailLinear *= 0.18;
        if (currentMode == 1 || currentMode == 22 || currentMode == 25 || currentMode == 26 || currentMode == 28 || currentMode == 29 || currentMode == 30) trailLinear = 0.0;
        float3 freshLinear = 1.0 - exp(-max(emission, 0.0) * 0.48);
        float freshLuma = dot(freshLinear, float3(0.2126, 0.7152, 0.0722));
        freshLinear = max(0.0, lerp(freshLuma.xxx, freshLinear, 1.52));
        color = pow(saturate(max(freshLinear, trailLinear)), 1.0 / 1.8);
    }


    float vignette = saturate(1.2 - dot(p, p) * 0.13);
    color *= 0.82 + vignette * 0.18;
    float ambientMotion = 0.72 + 0.28 * sin(p.x * 0.7 + p.y * 1.1 + ResolutionTime.z * 0.11);
    if (currentMode < 22)
        color += palette(length(p) * 0.08 + ResolutionTime.z * 0.005) * ambientMotion * (0.010 + AudioA.x * 0.014);
    if (currentMode >= 32)
        color = floor(saturate(color) * 31.0 + 0.5) / 31.0;
    return float4(saturate(color), 1.0);
}

// Ray-plane panels give solid faces, perspective and directional lighting.
float3 panelFace(float2 p, float3 center, float angle, float2 size, float3 tint)
{
    float3 ray = normalize(float3(p, 1.8));
    float3 normal = float3(sin(angle), 0.0, -cos(angle));
    float denominator = dot(ray, normal);
    if (abs(denominator) < 0.001) return 0.0;
    float travel = dot(center, normal) / denominator;
    if (travel <= 0.0) return 0.0;
    float3 hit = ray * travel - center;
    float2 local = float2(dot(hit, float3(cos(angle), 0, sin(angle))), hit.y);
    float sdf = roundedBoxSdf(local, size, 0.025);
    float face = 1.0 - smoothstep(-0.004, 0.004, sdf);
    float lighting = 0.22 + 0.78 * abs(dot(normal, normalize(float3(-0.5, 0.7, -1))));
    return tint * face * lighting + tint * exp(-abs(sdf) * 180.0) * 0.22;
}

SceneResult kineticMobile(float2 p, float seed)
{
    p = rotate2(p, sin(Stage.x * 0.38) * 0.12);
    float3 col = float3(0.025, 0.034, 0.04) * (1.0 - p.y * 0.25);
    for (int k = 11; k >= 0; k--)
    {
        float depth = 2.4 + (k % 3) * 0.65;
        float bandValue = getBand(k * 2) / (getBand(k * 2) + 0.18);
        float angle = Stage.x * (0.5 + (k % 3) * 0.16) + sin(Stage.x * 1.8 + k * 0.8) * (0.12 + bandValue * 1.25);
        float3 center = float3(((k % 4) - 1.5) * 1.02, ((k / 4) - 1.0) * 0.8 + sin(Stage.x + k) * bandValue * 0.24, depth);
        center.x += sin(Stage.x * 0.8 + k) * (0.08 + bandValue * 0.16);
        center.z += sin(Stage.x * 0.7 + k * 0.4) * 0.28;
        center = rotateY3(center - float3(0, 0, 3.05), sin(Stage.x * 0.32) * 0.30) + float3(0, 0, 3.05);
        float2 anchor = projectPerspective(center + float3(0, 0.55, 0), 1.8);
        float2 top = projectPerspective(center + float3(0, 0.22, 0), 1.8);
        col += float3(0.12, 0.16, 0.17) * exp(-segmentDistance(p, anchor, top) * 380.0);
        col += panelFace(p, center, angle, float2(0.31, 0.23), palette(k * 0.13) * (0.28 + bandValue * 0.85));
    }
    return makeScene(col, 0.0, 0.50);
}

SceneResult sandPlate(float2 p, float seed)
{
    float2 q = rotate2(p * 1.12, Stage.x * 0.38);
    q.y /= 0.73 + sin(Stage.x * 0.44) * 0.13;
    float plate = 1.0 - smoothstep(0.85, 0.87, max(abs(q.x), abs(q.y)));
    float orderA = 2.0 + AudioA.y * 3.0;
    float orderB = 3.0 + AudioB.x * 4.0;
    float field = cos(q.x * PI * orderA) * cos(q.y * PI * orderB) - cos(q.y * PI * orderA) * cos(q.x * PI * orderB);
    float grains = smoothstep(0.62, 0.92, hash21(floor(q * 490.0)));
    float nodes = exp(-abs(field) * (18.0 - AudioC.x * 8.0));
    float scatter = AudioC.x * grains * 0.14;
    float3 col = float3(0.075, 0.085, 0.10) * plate;
    col += lerp(float3(0.85, 0.67, 0.27), palette(Stage.y), 0.25) * plate * (nodes * grains * (0.12 + Dynamics.x * 1.5) + scatter);
    col += float3(0.3, 0.36, 0.4) * exp(-abs(max(abs(q.x), abs(q.y)) - 0.86) * 240.0);
    return makeScene(col, 0.0, 0.48);
}

float historyValue(int row, int column);

SceneResult resonanceTunnel(float2 p, float seed)
{
    p.x -= Stereo.z * 0.16;
    p.x /= 1.0 + Stereo.w * 0.12;
    float low = getBand(2) / (getBand(2) + 0.12);
    float voice = getBand(12) / (getBand(12) + 0.12);
    float high = getBand(25) / (getBand(25) + 0.10);
    float presence = saturate(AudioA.x * 1.5 + max(low, max(voice, high)) * 0.45);
    float t = Stage.x;
    float3 ray = normalize(float3(p, 1.65));
    float3 col = float3(0.002, 0.004, 0.008);
    float2 sky = p - float2(sin(t * 0.2) * 0.22, cos(t * 0.17) * 0.14);
    float radiusSky = max(0.08, length(sky));
    float angleSky = atan2(sky.y, sky.x);
    float track = abs(sin(angleSky * 18.0 + sin(t * 0.12) * 0.5));
    float lineSky = 1.0 - smoothstep(0.015, 0.015 + max(fwidth(track), 0.005), track);
    float packetSky = pow(0.5 + 0.5 * cos(log(radiusSky) * 12.0 - t * 1.4), 9.0);
    col += palette(angleSky / TAU + 0.4) * lineSky * (0.25 + packetSky) *
        smoothstep(0.5, 1.05, radiusSky) * (0.008 + high * 0.11);
    // Ray-plane intersections keep every echo tilted and genuinely in perspective.
    for (int echo = 15; echo >= 0; echo--)
    {
        float age = echo * 0.5 + Stage.z * 0.5;
        float past = t - age * 0.28;
        float3 center = float3(sin(past * 0.65) * 0.75 - age * 0.07,
            cos(past * 0.47) * 0.20 + age * 0.045, 2.70 + age * 0.38);
        float tilt = sin(past * 0.32) * 0.5 + voice * 0.22;
        float3 axisU = rotateY3(rotateX3(float3(1, 0, 0), tilt), 0.28 + sin(past * 0.37) * 0.35);
        float3 axisV = rotateY3(rotateX3(float3(0, 1, 0), tilt), 0.28 + sin(past * 0.37) * 0.35);
        float3 normal = cross(axisU, axisV);
        float denominator = dot(ray, normal);
        if (denominator <= 0.08) continue;
        float distanceAlongRay = dot(center, normal) / denominator;
        float3 local = ray * distanceAlongRay - center;
        float2 ringUv = float2(dot(local, axisU), dot(local, axisV));
        float angle = atan2(ringUv.y, ringUv.x);
        float coordinate = (0.5 + 0.5 * cos(angle + past * 0.25)) * 30.999;
        int cell = min(30, (int)floor(coordinate));
        float fraction = smoothstep(0.0, 1.0, frac(coordinate));
        int row = min(7, echo / 2);
        float captured = lerp(historyValue(row, cell), historyValue(row, cell + 1), fraction);
        float live = sampleWave(coordinate / 31.0);
        float waveform = echo == 0 ? live : captured;
        float radius = 1.02 + low * 0.24 + waveform * (0.12 + presence * 0.20);
        radius += sin(angle * 5.0 + past) * voice * 0.09;
        float d = abs(length(ringUv) - radius);
        float aa = max(fwidth(d), 0.002);
        float core = 1.0 - smoothstep(0.007, 0.013 + aa, d);
        float halo = exp(-d * 42.0) * 0.22;
        float rim = exp(-abs(d - 0.042) * 150.0) * high * 0.22;
        float attenuation = exp(-age * 0.23);
        float3 tint = palette(age * 0.055 + cos(angle) * 0.09 + Stage.y * 0.035);
        float bead = pow(saturate(cos(angle * 48.0 + past * 1.2)), 10.0);
        col += tint * (core + halo + rim) * attenuation * (0.008 + presence * 0.70);
        col += lerp(tint, float3(0.8, 0.95, 1.0), 0.45) * core * bead * high * attenuation * 0.30;
    }
    // Large off-axis echoes provide motion across the backdrop without fogging the foreground.
    float2 backdrop = p - float2(sin(t * 0.3) * 1.2, cos(t * 0.23) * 0.6);
    float phase = length(backdrop) * 9.0 - t * 1.7;
    float rings = pow(0.5 + 0.5 * cos(phase), 22.0);
    col += palette(length(backdrop) * 0.09 + 0.55) * rings * (0.001 + presence * 0.024);
    return makeScene(col, 0.0, 0.0);
}

SceneResult interferencePrism(float2 p, float seed)
{
    float t = Stage.x;
    float low = sqrt(saturate(getBand(3)));
    float middle = sqrt(saturate(getBand(13)));
    float high = sqrt(saturate(getBand(24)));
    float2 sourceA = float2(sin(t * 0.43) * 0.85, cos(t * 0.37) * 0.5);
    float2 sourceB = float2(cos(t * 0.31) * 0.9, sin(t * 0.47) * 0.6);
    float2 q = rotate2(p, sin(t * 0.17) * 0.32);
    float distanceA = length(q - sourceA);
    float distanceB = length(q - sourceB);
    // Smoothly moving interference contours, with independent spectral forces.
    float field = sin(distanceA * (5.0 + low * 3.0) - t * 1.2);
    field += cos(distanceB * (6.0 + middle * 2.0) + t * 0.85) * 0.72;
    field += sin(q.x * 2.0 + q.y * 3.0 + t * 0.4) * (0.10 + high * 0.25);
    float contour = abs(frac(field * 1.7) - 0.5);
    float aa = max(fwidth(field) * 1.7, 0.003);
    float edge = 1.0 - smoothstep(0.025, 0.025 + aa, contour);
    float ribbon = pow(saturate(1.0 - contour * 2.0), 5.0);
    float drive = saturate(low * 0.55 + middle * 0.3 + high * 0.15);
    float presence = saturate(AudioA.x * 2.0 + drive);
    float3 tint = palette(field * 0.16 + distanceA * 0.08 + Stage.y * 0.04);
    float3 col = tint * (edge * 0.43 + ribbon * 0.18) * (0.025 + presence * 0.8);
    float fringe = exp(-abs(contour - 0.12) * 100.0);
    col += palette(field * 0.16 + 0.3) * fringe * drive * 0.13;
    return makeScene(col, 0.0, 0.0);
}

SceneResult chromaticLoom(float2 p, float seed)
{
    float t = Stage.x;
    float2 q = rotate2(p, 0.48 + sin(t * 0.17) * 0.28);
    float3 col = float3(0.002, 0.003, 0.006);
    // Wide satin strips span beyond the viewport; each has its own spectral identity.
    for (int strip = 0; strip < 9; strip++)
    {
        float drive = noteMotion(getBand(strip * 3 + 2));
        float phase = q.x * 1.7 - t * 0.65 + strip * 0.78;
        float center = (strip - 4) * 0.37 + sin(phase) * (0.10 + drive * 0.32);
        center += sin(q.x * 3.1 + t * 0.4 + strip) * drive * 0.065;
        float width = (0.028 + drive * 0.19) * (0.30 + 0.70 * abs(cos(phase * 0.7)));
        float d = q.y - center;
        float aa = max(fwidth(d), 0.001);
        float mask = 1.0 - smoothstep(width - aa, width + aa, abs(d));
        float v = clamp(d / max(width, 0.001), -1.0, 1.0);
        float shade = sqrt(saturate(1.0 - v * v));
        float spec = pow(saturate(1.0 - abs(v - 0.35) * 1.8), 12.0);
        float ribs = pow(0.5 + 0.5 * cos(q.x * 38.0 - t * 1.5 + strip), 12.0);
        float3 tint = palette(strip * 0.107 + q.x * 0.025);
        float3 satin = tint * (0.08 + drive * 0.7) * (0.28 + shade * 0.72);
        satin += lerp(tint, float3(1, 0.95, 0.9), 0.45) * spec * drive * 0.38;
        satin += tint * ribs * drive * 0.08;
        col = lerp(col, satin, mask);
        float edge = exp(-abs(abs(d) - width) * 210.0);
        col += tint * edge * (0.008 + drive * 0.22);
    }
    return makeScene(col, 0.0, 0.0);
}

SceneResult rippleBloom(float2 p, float seed)
{
    float low = noteMotion(AudioA.y);
    float voice = noteMotion(AudioB.x);
    float high = noteMotion(AudioA.w);
    float presence = max(low, max(voice, high));
    float t = Stage.x;
    float2 center = float2(sin(t * 0.28) * 0.38, cos(t * 0.23) * 0.18);
    float2 q = rotate2(p - center, sin(t * 0.21) * 0.28);
    q.y /= 0.78 + sin(t * 0.31) * 0.12;
    float radius = length(q);
    float angle = atan2(q.y, q.x);
    // Cosine lookup closes the waveform seam at the back of the circular membrane.
    float coordinate = 0.5 + 0.5 * cos(angle - t * 0.16);
    float live = smoothReactiveWave(coordinate, 0.3);
    float lobes = sin(angle * 5.0 + t * 0.46) * voice * 0.08;
    float membrane = 0.40 + low * 0.24 + live * (0.02 + presence * 0.12) + lobes;
    float3 col = float3(0.001, 0.002, 0.004);
    float aa = max(fwidth(radius), 0.001);
    // Broad colored ripples and narrow phosphor rims recreate the WMP bloom silhouette.
    for (int ripple = 0; ripple < 9; ripple++)
    {
        float age = ripple + Stage.z;
        float coordinate31 = coordinate * 30.999;
        int cell = min(30, (int)floor(coordinate31));
        float captured = lerp(historyValue(min(ripple, 7), cell),
            historyValue(min(ripple, 7), cell + 1), frac(coordinate31));
        float front = membrane + age * 0.19 + captured * presence * 0.045;
        float d = radius - front;
        float rim = 1.0 - smoothstep(0.003, 0.008 + aa, abs(d));
        float satin = exp(-abs(d + 0.035) * 24.0) * 0.17;
        float beads = pow(saturate(cos(angle * (72.0 + ripple * 4.0) + t * 0.7)), 8.0);
        float fade = exp(-age * 0.26);
        float3 tint = palette(0.10 + age * 0.075 + sin(angle * 2.0 + t * 0.12) * 0.04);
        col += tint * (rim * (0.20 + beads * high * 0.28) + satin) * fade * presence;
    }
    float edgeDistance = abs(radius - membrane);
    float mainRim = 1.0 - smoothstep(0.008, 0.017 + aa, edgeDistance);
    float tightGlow = exp(-edgeDistance * 55.0) * 0.18;
    float3 rimColor = lerp(palette(0.08 + angle / TAU * 0.10), float3(1, 0.92, 0.94), 0.48);
    col += rimColor * (mainRim + tightGlow) * (0.004 + presence * 0.85);
    float inside = 1.0 - smoothstep(membrane - 0.035, membrane, radius);
    float swirl = sin(radius * 21.0 - t * 1.3 + sin(angle * 3.0 + t * 0.3) * voice * 2.4);
    col += palette(0.48 + swirl * 0.08) * inside * (0.01 + 0.06 * swirl * swirl) * presence;
    return makeScene(col, 0.0, 0.0);
}

SceneResult magneticSculpture(float2 p, float seed)
{
    float3 col = float3(0.003, 0.006, 0.012);
    // Elliptical magnetic paths occupy the outer frame while leaving the sculpture readable.
    for (int field = 0; field < 7; field++)
    {
        float force = noteMotion(getBand(field * 4));
        float2 fieldUv = rotate2(p, Stage.x * 0.12 + field * 0.43);
        fieldUv.y /= 0.55 + 0.04 * field;
        float radius = length(fieldUv);
        float angle = atan2(fieldUv.y, fieldUv.x);
        float distance = abs(radius - 1.0 - field * 0.19 - sin(angle * 3 + Stage.x * 0.4) * force * 0.10);
        float fieldLine = 1.0 - smoothstep(0.003, 0.007 + fwidth(radius), distance);
        float runner = pow(0.5 + 0.5 * cos(angle * 3 - Stage.x * 1.2 + field), 12);
        col += palette(field * 0.13 + 0.3) * fieldLine * (0.009 + force * 0.10) * (0.45 + runner);
    }
    float2 trackUv = rotate2(p, sin(Stage.x * 0.23) * 0.5);
    trackUv.y /= 0.62;
    float trackRadius = length(trackUv);
    float trackAngle = atan2(trackUv.y, trackUv.x);
    for (int orbitIndex = 0; orbitIndex < 3; orbitIndex++)
    {
        float arc = pow(saturate(cos(trackAngle - Stage.x * (0.45 + orbitIndex * 0.13) - orbitIndex * 2.1)), 8.0);
        float strength = getBand(4 + orbitIndex * 10);
        col += palette(orbitIndex * 0.31 + trackAngle * 0.04) * exp(-abs(trackRadius - 0.92 - orbitIndex * 0.16) * 260.0)
            * arc * (0.006 + strength / (strength + 0.18) * 0.14);
    }
    float2 previousCenter = 0;
    for (int bead = 39; bead >= 0; bead--)
    {
        float f = (bead % 8) / 7.0;
        float branch = floor(bead / 8.0);
        float a = branch * TAU / 5.0 + Stage.x * 0.72;
        float bandValue = sqrt(saturate(getBand((int)branch * 7)));
        float opening = saturate(AudioC.x * 1.8 + AudioA.y * 0.7);
        float reach = 0.12 + f * (0.62 + opening * 0.55 + bandValue * 0.35);
        float bend = sin(f * 4.2 - Stage.x * 1.6 + branch) * (0.12 + bandValue * 0.85)
            + stereoPan(branch / 4.0) * bandValue * f * 0.32;
        float3 pos = rotateY3(float3(cos(a + bend) * reach, sin(a + bend) * reach * 0.82, sin(f * 5.0 + branch - Stage.x) * (0.12 + AudioB.x * 0.65)), Stage.x * 0.28);
        pos.z += 2.5;
        float2 center = projectPerspective(pos, 1.8);
        if (bead % 8 != 7)
            col += palette(branch * 0.19 + f * 0.08) * exp(-segmentDistance(p, center, previousCenter) * 400) * (0.06 + bandValue * 0.32);
        previousCenter = center;
        float size = (0.042 + bandValue * 0.02) * 1.8 / pos.z;
        float orbit = abs(length(p) - reach * 1.8 / pos.z);
        col += palette(branch * 0.19) * exp(-orbit * 450) * (0.002 + bandValue * 0.008);
        float2 q = (p - center) / size;
        float rr = dot(q, q);
        if (rr < 1.0)
        {
            float3 n = float3(q, sqrt(1.0 - rr));
            float light = max(0.0, dot(n, normalize(float3(-0.4, -0.6, 1.0))));
            float spec = pow(light, 32.0);
            float3 metal = palette(branch * 0.16 + f * 0.08) * (0.10 + light * 0.55) + spec * 0.85;
            col = lerp(col, metal, 1.0 - smoothstep(0.92, 1.0, rr));
        }
    }
    return makeScene(col, 0.0, 0.35);
}

float historyValue(int row, int column)
{
    int idx = clamp(row, 0, 7) * 32 + clamp(column, 0, 31);
    return History[idx / 4][idx % 4];
}

SceneResult spectralWaterfall(float2 p, float seed)
{
    float2 background = p;
    p -= float2(sin(Stage.x * 0.43) * 0.22, cos(Stage.x * 0.31) * 0.10);
    p = rotate2(p, sin(Stage.x * 0.35) * 0.27);
    float3 col = float3(0.003, 0.009, 0.014);
    // A scrolling perspective stage, with a quiet gap around the waveform plane.
    float depth = 1.0 / max(0.12, abs(background.y) + 0.12);
    float2 grid = float2(background.x * depth * 2.0, depth * 2.5 - Stage.x * 0.65);
    float2 lineDistance = abs(frac(grid + 0.5) - 0.5);
    float2 aaGrid = max(fwidth(grid), 0.001);
    float2 lines = 1.0 - smoothstep(aaGrid * 0.3, aaGrid * 1.3, lineDistance);
    float stageMask = smoothstep(0.16, 0.6, abs(background.y));
    float music = saturate(AudioA.x * 2.0);
    col += palette(background.x * 0.12 + 0.45) * max(lines.x, lines.y) * stageMask * (0.008 + music * 0.06);
    for (int row = 7; row >= 0; row--)
    {
        if (row >= (int)Stage.w) continue;
        float age = row + Stage.z;
        float z = 1.85 + age * 0.36;
        float coordinate = (p.x * z / 5.4 + 0.5) * 31.0;
        if (coordinate < 0.0 || coordinate > 31.0) continue;
        int cell = min(30, (int)floor(coordinate));
        float a = historyValue(row, cell);
        float b = historyValue(row, cell + 1);
        float2 pa = projectPerspective(float3((cell / 31.0 - 0.5) * 3.0, -0.08 + a * 0.95, z), 1.8);
        float2 pb = projectPerspective(float3(((cell + 1) / 31.0 - 0.5) * 3.0, -0.08 + b * 0.95, z), 1.8);
        float d = segmentDistance(p, pa, pb);
        float fade = (1.0 - age / 8.0) * (row == 0 ? smoothstep(0.0, 0.12, Stage.z) : 1.0);
        col += palette(coordinate / 38.0 + row * 0.035) * (exp(-d * 330) + exp(-d * 95) * 0.18) * fade * 0.95;
    }
    return makeScene(col, 0.0, 0.0);
}

float dvdGlyph(float2 q)
{
    float d1 = abs(length(float2((q.x + 0.24) * 1.2, q.y)) - 0.11);
    d1 = max(d1, -q.x - 0.24);
    d1 = min(d1, segmentDistance(q, float2(-0.24, -0.11), float2(-0.24, 0.11)));
    float v = min(segmentDistance(q, float2(-0.09, -0.11), float2(0, 0.11)), segmentDistance(q, float2(0, 0.11), float2(0.09, -0.11)));
    float d2 = abs(length(float2((q.x - 0.15) * 1.2, q.y)) - 0.11);
    d2 = max(d2, 0.15 - q.x);
    d2 = min(d2, segmentDistance(q, float2(0.15, -0.11), float2(0.15, 0.11)));
    float disc = abs(length(float2(q.x * 0.48, (q.y - 0.18) * 2.2)) - 0.13);
    return 1.0 - smoothstep(0.011, 0.019, min(min(d1, d2), min(v, disc)));
}

SceneResult retroDvd(float2 p, float seed)
{
    float aspect = ResolutionTime.x / ResolutionTime.y;
    float2 limit = float2(max(0.1, aspect - 0.43), 0.70);
    float2 phase = Stage.x * float2(0.22, 0.31) + float2(0.23, 0.67);
    float2 center = (1.0 - 4.0 * abs(frac(phase) - 0.5)) * limit;
    float2 q = p - center;
    float glyph = dvdGlyph(q);
    float3 tint = palette(floor(phase.x * 2.0) * 0.173 + floor(phase.y * 2.0) * 0.213 + Stage.y * 0.3);
    float3 col = float3(0.012, 0.016, 0.023);
    col += tint * glyph * (0.55 + Dynamics.x * 0.5);
    float scan = 0.96 + 0.04 * cos(p.y * ResolutionTime.y * PI);
    return makeScene(col * scan, 0.0, 0.24);
}

float ferroPressure(int bandIndex)
{
    // Motion bands are already filtered; a second broad smoothstep erased normal notes.
    float energy = max(0.0, getBand(bandIndex) - 0.003);
    return energy / (energy + 0.14);
}

float ferroHeight(float2 uv)
{
    float height = 0.015;
    for (int spike = 0; spike < 7; spike++)
    {
        float angle = spike * TAU / 6.0;
        float2 center = spike == 6 ? float2(0, 0) : float2(cos(angle), sin(angle)) * 0.56;
        // Each magnetic pole keeps its frequency identity as the fluid flexes around it.
        float pressure = ferroPressure(1 + spike * 5);
        center += float2(cos(Stage.x * 0.65 + angle), sin(Stage.x * 0.65 + angle)) * pressure * 0.055;
        float radius = length(uv - center);
        float shape = pow(saturate(1.0 - radius / (0.30 + pressure * 0.12)), 2.0);
        height += shape * (0.008 + pressure * 0.94);
        height += sin(radius * 24.0 - Stage.x * 2.5) * exp(-radius * 7.0) * pressure * 0.012;
    }
    height += sin(length(uv) * 23.0 - Stage.x * 2.0) * getBand(1) * 0.008;
    return height;
}

SceneResult ferrofluid(float2 p, float seed)
{
    float3 origin = float3(0.0, 1.65, -2.65);
    float3 ray = normalize(float3(p.x * 0.74, -0.88 - p.y * 0.70, 1.48));
    float travel = 0.7;
    float3 hit = origin;
    bool found = false;
    for (int stepIndex = 0; stepIndex < 72; stepIndex++)
    {
        hit = origin + ray * travel;
        float surface = hit.y - ferroHeight(hit.xz);
        float distanceField = max(max(surface, length(hit.xz) - 1.12), -0.07 - hit.y);
        if (distanceField < 0.0035)
        {
            found = true;
            break;
        }
        travel += max(0.003, distanceField * 0.22);
        if (travel > 5.5) break;
    }
    float3 col = float3(0.005, 0.012, 0.018);
    // The metal dish stays crisp; reflected strip lights reveal surface normals.
    float floorTravel = (-0.08 - origin.y) / min(-0.001, ray.y);
    float3 floorHit = origin + ray * floorTravel;
    float dishRadius = length(floorHit.xz);
    float outside = smoothstep(1.16, 1.22, dishRadius);
    float field = abs(frac(dishRadius * 3.0 - Stage.x * 0.13) - 0.5);
    float angle = atan2(floorHit.z, floorHit.x);
    int sector = min(6, (int)floor((angle / TAU + 0.5) * 7.0));
    float localForce = ferroPressure(1 + sector * 5);
    float3 fieldTint = palette(sector / 7.0 + 0.1);
    col += outside * fieldTint * exp(-field * 65.0) * exp(-max(0.0, dishRadius - 1.2) * 0.22) * (0.035 + localForce * 0.35);
    float spokes = abs(sin(angle * 12.0 + Stage.x * 0.18 + dishRadius * 0.28));
    float spokeLine = 1.0 - smoothstep(0.018, 0.018 + max(fwidth(spokes), 0.008), spokes);
    float packet = pow(0.5 + 0.5 * cos(dishRadius * 8.0 - Stage.x * 1.8), 10.0);
    col += outside * palette(sector / 7.0 + 0.4) * spokeLine * (0.01 + localForce * 0.22) * (0.25 + packet) / (1.0 + dishRadius * 0.15);
    float rim = exp(-abs(dishRadius - 1.15) * 150.0);
    col += float3(0.16, 0.24, 0.28) * rim;
    if (found)
    {
        float eps = 0.006;
        float slopeX = (ferroHeight(hit.xz + float2(eps, 0)) - ferroHeight(hit.xz - float2(eps, 0))) / (2.0 * eps);
        float slopeZ = (ferroHeight(hit.xz + float2(0, eps)) - ferroHeight(hit.xz - float2(0, eps))) / (2.0 * eps);
        float3 normal = normalize(float3(-slopeX, 1.0, -slopeZ));
        float3 reflected = reflect(ray, normal);
        float edge = pow(1.0 - max(0.0, dot(normal, -ray)), 3.0);
        float stripA = pow(max(0.0, 1.0 - abs(reflected.x - 0.3) * 5.0), 6.0);
        float stripB = pow(max(0.0, 1.0 - abs(reflected.z + 0.3) * 6.0), 5.0);
        float highlight = pow(max(0.0, dot(normal, normalize(float3(-0.6, 1.0, -0.4)))), 35.0);
        float3 tint = palette(hit.x * 0.13 + hit.z * 0.1 + Stage.y * 0.1);
        col = float3(0.014, 0.025, 0.033) + tint * (stripA * 0.65 + stripB * 0.38 + edge * 0.30);
        col += float3(0.65, 0.85, 0.95) * highlight * 0.38;
        col *= 0.70 + 0.30 * smoothstep(0.0, 0.15, hit.y);
    }
    return makeScene(col, 0.0, 0.20);
}

SceneResult geissSilk(float2 p, float seed)
{
    float low = noteMotion(AudioA.y);
    float mid = noteMotion(AudioB.x);
    float high = noteMotion(AudioA.w);
    float presence = max(low, max(mid, high));
    float t = Stage.x;
    float2 q = rotate2(p - float2(sin(t * 0.24) * 0.22, cos(t * 0.19) * 0.16),
        0.40 + sin(t * 0.18) * 0.62);
    float coordinate = saturate(q.x * 0.25 + 0.5);
    float wave = reactiveWave(coordinate, 0.35);
    float3 col = 0.0;
    // Two bright live filaments seed the expanding Geiss-style flow field.
    for (int ribbon = 0; ribbon < 2; ribbon++)
    {
        float side = ribbon == 0 ? 1.0 : -1.0;
        float curve = sin(q.x * 1.5 + t * 0.8 + ribbon * PI) * (0.12 + mid * 0.28);
        curve += side * (0.08 + low * 0.25);
        curve += wave * (0.03 + presence * 0.42);
        curve += sin(q.x * 3.2 - t * 0.6) * low * 0.10;
        float d = q.y - curve;
        float aa = max(fwidth(d), 0.001);
        float core = 1.0 - smoothstep(0.002, 0.005 + aa, abs(d));
        float filament = exp(-abs(d) * 110.0) * 0.15;
        float crest = exp(-pow(q.x - sin(t * 0.62 + ribbon * 2.1) * 1.35, 2.0) * 5.0);
        float3 tint = palette(ribbon * 0.32 + q.x * 0.045 + Stage.y * 0.04);
        col += tint * (core * 0.48 + filament) * presence * (0.35 + crest * 0.65);
        col += lerp(tint, float3(1, 0.95, 0.83), 0.6) * core * crest * high * 0.26;
    }
    return makeScene(col, 0.0, 0.0);
}

SceneResult rasterCurtain(float2 p, float seed)
{
    float2 q = rotate2(p - float2(sin(Stage.x * 0.3) * 0.3, 0), 0.5 + sin(Stage.x * 0.22) * 0.45);
    float3 col = 0;
    float coordinate = saturate(q.x * 0.23 + 0.5) * 31;
    int cell = min(30, (int)floor(coordinate));
    for (int layer = 7; layer >= 0; layer--)
    {
        float captured = lerp(historyValue(layer, cell), historyValue(layer, cell + 1), frac(coordinate));
        float age = layer + Stage.z;
        float fold = sin(q.x * 1.8 + Stage.x * 0.45 + layer * 0.13) * 0.20;
        float d = abs(q.y - captured * 0.60 - fold - age * 0.07 + 0.28);
        float trace = exp(-d * 190) + exp(-d * 32) * 0.12;
        col += palette(0.06 + layer * 0.035 + q.x * 0.035) * trace * (1.0 - age / 9.0) * (0.02 + AudioA.x * 0.9);
    }
    float grain = pow(saturate(cos(q.x * 90) * cos(q.y * 90)), 12);
    col += palette(0.15) * grain * exp(-abs(q.y) * 2) * AudioA.x * 0.025;
    return makeScene(col, float2(0.0008, -0.0012), 0.5);
}

SceneResult radialLightFan(float2 p, float seed)
{
    float2 q = p - float2(sin(Stage.x * 0.34) * 0.48, cos(Stage.x * 0.27) * 0.25);
    float r = length(q);
    float a = atan2(q.y, q.x) + Stage.x * 0.22;
    float sectorPosition = frac(a / TAU) * 16.0;
    int sector = (int)floor(sectorPosition);
    float force = sqrt(saturate(getBand(sector * 2)));
    float rayShape = pow(saturate(1.0 - abs(frac(sectorPosition) - 0.5) * 2), 2.1);
    float hole = 0.15 + AudioA.y * 0.16;
    float mask = smoothstep(hole, hole + 0.035, r);
    float sweep = 0.55 + 0.45 * sin(r * 8 - Stage.x * 2.2 + sector);
    float3 tint = palette(sector * 0.035 + Stage.y * 0.02);
    float3 col = tint * rayShape * mask * (0.006 + force * 1.35) * (0.55 + sweep * 0.45);
    float rim = exp(-abs(r - hole - sampleWave(frac(a / TAU)) * 0.025) * 200);
    col += palette(0.2) * rim * (0.015 + AudioA.x * 0.35);
    float dots = pow(saturate(cos(a * 32) * cos(r * 70 - Stage.x * 3)), 16);
    col += tint * dots * mask * AudioA.z * 0.16;
    return makeScene(col, q * -0.001, 0.4);
}

SceneResult phosphorEcho(float2 p, float seed)
{
    float2 q = rotate2(p - float2(sin(Stage.x * 0.35) * 0.32, cos(Stage.x * 0.29) * 0.16), Stage.x * 0.12);
    float a = atan2(q.y, q.x);
    float coordinate = (cos(a) * 0.5 + 0.5) * 30.999;
    int cell = min(30, (int)floor(coordinate));
    float r = length(q);
    float3 col = 0;
    for (int echo = 7; echo >= 0; echo--)
    {
        float captured = lerp(historyValue(echo, cell), historyValue(echo, cell + 1), frac(coordinate));
        float age = echo + Stage.z;
        float radius = 0.22 + age * 0.18 + captured * (0.09 + age * 0.015);
        float scallop = sin(a * 5 + age * 0.3 + Stage.x * 0.35) * 0.035;
        float d = abs(r - radius - scallop);
        float dash = echo == 0 ? 1.0 : 0.45 + 0.55 * step(0.0, cos(a * 90 + age));
        col += palette(echo * 0.045 + 0.42) * exp(-d * 170) * dash * (1.0 - age / 9.0) * (0.015 + AudioA.x * 0.75);
    }
    return makeScene(col, q * -0.0007, 0.45);
}

#define DECLARE_SCENE_SHADER(entryName, sceneIndex, sceneFunction) \
float4 entryName(VertexOutput input) : SV_TARGET \
{ \
    float2 p = scenePosition(input); \
    return composeScene(input, p, sceneFunction(p, Presets.y), sceneIndex); \
}

DECLARE_SCENE_SHADER(PSLiquidGlass, 0, liquidGlass)
DECLARE_SCENE_SHADER(PSFilamentKaleidoscope, 1, filamentKaleidoscope)
DECLARE_SCENE_SHADER(PSVolumetricTunnel, 2, volumetricTunnel)
DECLARE_SCENE_SHADER(PSPlasmaNebula, 3, plasmaNebula)
DECLARE_SCENE_SHADER(PSCrystalMirror, 4, crystalMirror)
DECLARE_SCENE_SHADER(PSRibbonCanyon, 5, ribbonCanyon)
DECLARE_SCENE_SHADER(PSElectricLattice, 6, electricLattice)
DECLARE_SCENE_SHADER(PSPrismConcerto, 7, prismConcerto)
DECLARE_SCENE_SHADER(PSFibonacciShell, 8, fibonacciShell)
DECLARE_SCENE_SHADER(PSRisingFlame, 9, risingFlame)
DECLARE_SCENE_SHADER(PSGlassMosaic, 10, glassMosaic)
DECLARE_SCENE_SHADER(PSCometTrace, 11, cometTrace)
DECLARE_SCENE_SHADER(PSFractalWings, 12, fractalWings)
DECLARE_SCENE_SHADER(PSSpectralCathedral, 13, spectralCathedral)
DECLARE_SCENE_SHADER(PSOscilloscopeRibbon, 14, oscilloscopeRibbon)
DECLARE_SCENE_SHADER(PSVocalLoom, 15, vocalLoom)
DECLARE_SCENE_SHADER(PSBassTerrain, 16, bassTerrain)
DECLARE_SCENE_SHADER(PSDiscoCubeFloor, 17, discoCubeFloor)
DECLARE_SCENE_SHADER(PSHelixReactor, 18, helixReactor)
DECLARE_SCENE_SHADER(PSOrbitalShardStorm, 19, orbitalShardStorm)
DECLARE_SCENE_SHADER(PSSpectralGyroscope, 20, spectralGyroscope)
DECLARE_SCENE_SHADER(PSLiquidChromeTorus, 21, liquidChromeTorus)
DECLARE_SCENE_SHADER(PSGeissSilk, 22, geissSilk)
DECLARE_SCENE_SHADER(PSKineticMobile, 23, kineticMobile)
DECLARE_SCENE_SHADER(PSSandPlate, 24, sandPlate)
DECLARE_SCENE_SHADER(PSResonanceTunnel, 25, resonanceTunnel)
DECLARE_SCENE_SHADER(PSInterferencePrism, 26, interferencePrism)
DECLARE_SCENE_SHADER(PSChromaticLoom, 27, chromaticLoom)
DECLARE_SCENE_SHADER(PSRippleBloom, 28, rippleBloom)
DECLARE_SCENE_SHADER(PSMagneticSculpture, 29, magneticSculpture)
DECLARE_SCENE_SHADER(PSSpectralWaterfall, 30, spectralWaterfall)
DECLARE_SCENE_SHADER(PSFerrofluid, 31, ferrofluid)
DECLARE_SCENE_SHADER(PSRasterCurtain, 32, rasterCurtain)
DECLARE_SCENE_SHADER(PSRadialLightFan, 33, radialLightFan)
DECLARE_SCENE_SHADER(PSPhosphorEcho, 34, phosphorEcho)
