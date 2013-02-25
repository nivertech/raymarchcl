typedef struct {
  float3 pos;
  float3 dir;
} TRay;

typedef struct {
  float3 pos;
  float distance;
  int objectID;
  int iter;
} TIsec;

typedef struct {
  float3 albedo;
  float r0;
  float smoothness;
  float invR0;
  float specPow;
} TMaterial;

typedef struct {
  float2 pixelPos;
  float3 eyePos;
  float4 mcPos;
  float3 mcNormal;
} TRenderState;

typedef struct {
  int2 resolution;
  float invAspect;
  float time;
  float3 eyePos;
  float3 targetPos;
  float3 up;
  int maxIter;
  int maxVoxelIter;
  float maxDist;
  float startDist;
  float eps;
  int aoIter;
  float aoStepDist;
  float aoAmp;
  float3 voxelBounds;
  float3 voxelBounds2;
  float3 voxelBoundsMin;
  float3 voxelBoundsMax;
  float3 invVoxelScale;
  int3 voxelRes;
  float voxelSize;
  float isoVal;
  float groundY;
  float3 skyColor;
  int shadowIter;
  float shadowBias;
  float3 lightPos;
  float3 lightColor;
  float lightScatter;
  float minLightAtt;
  float gamma;
  float exposure;
  float dof;
  float frameBlend;
  float fogDensity;
  float flareAmp;
  float3 normOffsets[4];
  TMaterial materials[2];
} TRenderOptions;

float4 distUnion(const float4 v1, const float4 v2) {
  return v1.x < v2.x ? v1 : v2;
}

/**
 * @returns distance to box or -1 if no isec
 */
float intersectsBox(const float3 bmin, const float3 bmax, const float3 p, const float3 dir) {
  float3 omin = (bmin - p) / dir;
  float3 omax = (bmax - p) / dir;
  float3 m = min(omax, omin);
  float a = max(max(m.x, 0.0f), max(m.y, m.z));
  m = max(omax, omin);
  float b = min(m.x, min(m.y, m.z));
  return b > a ? a : -1.0f;
}

float voxelDataAt(global const float* voxels, const int3 res, const int3 p) {
  if (p.x >= 0 && p.x < res.x && p.y >= 0 && p.y < res.y && p.z >= 0 && p.z < res.z) {
    return voxels[p.z * res.x * res.y + p.y * res.x + p.x];
  }
  return 0.0f;
}

float voxelLookup(global const float* voxels, global const TRenderOptions* opts, const float3 p) {
  //float3 pv = p * (float3)(opts->voxelRes.x, opts->voxelRes.y, opts->voxelRes.z);
  int3 pv = (int3)(p.x * opts->voxelRes.x, p.y * opts->voxelRes.y, p.z * opts->voxelRes.z);
  return voxelDataAt(voxels, opts->voxelRes, pv);
}

float4 distanceToScene(global const float* voxels, global const TRenderOptions* opts,
                       const float3 rpos, const float3 dir, const int steps) {
  float4 res = distUnion((float4)(rpos.y + opts->groundY, 1.0, rpos.xz), (float4)(10000.0f, -1.0f, 0.0f, 0.0f));
  float idist = intersectsBox(opts->voxelBoundsMin, opts->voxelBoundsMax, rpos, dir);
  if (idist >= 0.0f && idist < res.x) {
    float3 delta = dir / (float3)(steps) * opts->invVoxelScale;
    float3 p = rpos + opts->voxelBounds;
    if (idist > 0.0f) p += dir * idist;
    p *= opts->invVoxelScale;
    for(int i = 0; i < steps; i++) {
      float v = voxelLookup(voxels, opts, p);
      if (v > opts->isoVal) {
        float d = length(rpos - (p * opts->voxelBounds2 - opts->voxelBounds)) - opts->voxelSize;
        return distUnion((float4)(d, 2.0f, 0.0f, 0.0f), res);
      }
      p += delta;
    }
  }
  return res;
}

float3 sceneNormal(global const float* voxels, global const TRenderOptions* opts,
                   const float3 p, const float3 dir) {
  const float f1 = distanceToScene(voxels, opts, p + opts->normOffsets[0], dir, opts->maxIter).x;
  const float f2 = distanceToScene(voxels, opts, p + opts->normOffsets[1], dir, opts->maxIter).x;
  const float f3 = distanceToScene(voxels, opts, p + opts->normOffsets[2], dir, opts->maxIter).x;
  const float f4 = distanceToScene(voxels, opts, p + opts->normOffsets[3], dir, opts->maxIter).x;
  return normalize(opts->normOffsets[0] * f1 + opts->normOffsets[1] * f2 +
                   opts->normOffsets[2] * f3 + opts->normOffsets[3] * f4);
}

void raymarch(global const float* voxels, global const TRenderOptions* opts,
              const TRay* ray, TIsec* result, const float maxDist, const int maxSteps) {
  result->distance = opts->startDist;
  result->objectID = 0;
  result->iter = 1;
  for(int i = 0; i < maxSteps; i++) {
    result->pos = ray->pos + ray->dir * result->distance;
    float4 sceneDist = distanceToScene(voxels, opts, result->pos, ray->dir, opts->maxVoxelIter);
    result->objectID = (int)(sceneDist.y);
    if(fabs(sceneDist.x) <= opts->eps || result->distance >= maxDist) {
      break;
    }
    result->distance += sceneDist.x;
    result->iter++;
  }
  if(result->distance >= maxDist) {
    result->pos = ray->pos + ray->dir * result->distance;
    result->objectID = 0;
    result->distance = 1000.0f;
  }
}

TMaterial objectMaterial(global const TRenderOptions* opts, const int objectID) {
  return opts->materials[objectID];
}

float3 lightPos(global const TRenderOptions* opts, const TRenderState* state) {
  return opts->lightPos + state->mcNormal * opts->lightScatter;
}

float3 reflect(const float3 v, const float3 n){
	return v - 2.0f * dot(v, n) * n;
}

float3 applyAtmosphere(global const TRenderOptions* opts,
                       const TRenderState* state, const TRay* ray, const TIsec* isec, float3 col) {
  float fa = exp(isec->distance * isec->distance * -opts->fogDensity);
  //float3 col = mix(opts->skyColor), col, fa);
  col = (float3)(mix(opts->skyColor.x, col.x, fa),
                 mix(opts->skyColor.y, col.y, fa),
                 mix(opts->skyColor.z, col.z, fa));
  float3 lp = lightPos(opts, state);
  float d = clamp(dot(lp - ray->pos, ray->dir), 0.0f, isec->distance);
  lp = ray->pos + ray->dir * d - lp;
  col += opts->lightColor * opts->flareAmp / dot(lp,lp);
  return col;
}

float shadow(global const float* voxels, global const TRenderOptions* opts,
             const float3 p, const float3 ldir, const float ldist) {
  TRay shadowRay;
  shadowRay.pos = p;
  shadowRay.dir = ldir;
  TIsec shadowIsec;
  raymarch(voxels, opts, &shadowRay, &shadowIsec, ldist, opts->shadowIter);
  return shadowIsec.distance > 0.0f ? step(ldist, shadowIsec.distance) : 0.0f;
}

// http://en.wikipedia.org/wiki/Schlick's_approximation
float schlick(const TMaterial mat, const float3 normal, const float3 view) {
  float d = clamp(1.0f - dot(normal, -view), 0.0f, 1.0f);
  float d2 = d * d;
  return mat.r0 + mat.invR0 * d2 * d2 * d;
}

float diffuseIntensity(const float3 ldir, const float3 normal) {
  return max(0.0f, dot(ldir, normal));
}

float blinnPhongIntensity(const TMaterial mat, const TRay* ray, const float3 lightDir, const float3 normal) {
  float3 vHalf = normalize(lightDir - ray->dir);
  float nh = dot(vHalf, normal);
  if (nh > 0.0f) {
    return pow(nh, mat.specPow) * (mat.specPow + 2.0f) * 0.125f;
  }
  return 0.0f;
}

float ambientOcclusion(global const float* voxels, global const TRenderOptions* opts, const float3 pos, const float3 normal) {
  float ao = 1.0f;
  float d = 0.0f;
  for(int i = 0; i <= opts->aoIter; i++) {
    d += opts->aoStepDist;
    float4 sceneDist = distanceToScene(voxels, opts, pos + normal * d, normal, opts->aoIter);
    ao *= 1.0f - max(0.0f, (d - sceneDist.x) * opts->aoAmp / d );
  }
  return ao;
}

float3 objectLighting(global const float* voxels, global const TRenderOptions* opts,
                      const TRenderState* state, const TRay* ray, TIsec* isec,
                      const TMaterial mat, const float3 normal, const float3 reflectCol) {
  float ao = ambientOcclusion(voxels, opts, isec->pos, normal);
  float3 diffReflect = opts->skyColor * ao;
  float3 specReflect = reflectCol * ao;

  // point light
  float3 deltaLight = lightPos(opts, state) - isec->pos;
  float lightDist = dot(deltaLight, deltaLight);
  float att = 1.0f / lightDist;
  if (att > opts->minLightAtt) {
    float3 lightDir = normalize(deltaLight);
    float shadowFactor = shadow(voxels, opts, isec->pos + lightDir * opts->shadowBias, lightDir, min(sqrt(lightDist) - opts->shadowBias, opts->maxDist));
    float3 incidentLight = opts->lightColor * shadowFactor * att;
    diffReflect += diffuseIntensity(lightDir, normal) * incidentLight;
    specReflect += blinnPhongIntensity(mat, ray, lightDir, normal) * incidentLight;
  }

  diffReflect *= mat.albedo;

  // specular
  float spec = schlick(mat, normal, ray->dir);
  float3 col = (float3)(mix(diffReflect.x, specReflect.x, spec),
                        mix(diffReflect.y, specReflect.y, spec),
                        mix(diffReflect.z, specReflect.z, spec));
  return col;
}

float3 basicSceneColor(global const float* voxels, global const TRenderOptions* opts,
                       const TRenderState* state, const TRay* ray) {
  TIsec isec;
  raymarch(voxels, opts, ray, &isec, opts->maxDist, opts->maxIter);

  float3 sceneCol;

  if(isec.objectID < 1) {
    sceneCol = opts->skyColor; //skyGradient(ray.dir);
  } else {
    const TMaterial mat = objectMaterial(opts, isec.objectID);
    float3 norm = sceneNormal(voxels, opts, isec.pos, ray->dir);
    // use sky gradient instead of reflection
    //float3 reflectCol = skyColor; //skyGradient(reflect(ray.dir, n));
    // apply lighting
    sceneCol = objectLighting(voxels, opts, state, ray, &isec, mat, norm, opts->skyColor);
  }
  return applyAtmosphere(opts, state, ray, &isec, sceneCol);
}

float3 sceneColor(global const float* voxels, global const TRenderOptions* opts,
                  const TRenderState* state, const TRay* ray) {
  TIsec isec;
  raymarch(voxels, opts, ray, &isec, opts->maxDist, opts->maxIter);
  float3 sceneCol;
  if(isec.objectID < 1) {
    sceneCol = opts->skyColor; //skyGradient(ray.dir);
  } else {
    const TMaterial mat = objectMaterial(opts, isec.objectID);
    float3 norm = sceneNormal(voxels, opts, isec.pos, ray->dir);
    norm = normalize(norm + state->mcNormal / (5.0f + mat.smoothness * 200.0f));

    TRay reflectRay;
    reflectRay.dir = reflect(ray->dir, norm);
    reflectRay.pos = isec.pos + reflectRay.dir * 0.05f; // TODO opts->reflectSeperation
    float3 reflectCol = basicSceneColor(voxels, opts, state, &reflectRay);
    sceneCol = objectLighting(voxels, opts, state, ray, &isec, mat, norm, reflectCol);
  }
  sceneCol = applyAtmosphere(opts, state, ray, &isec, sceneCol);
  return sceneCol;
}

float3 gamma(const float3 col) {
  return col * col;
}

float3 invGamma(const float3 col) {
  return sqrt(col);
}

float3 tonemap(const float3 col, const float g) {
  return gamma(col / (g + col));
}

TRay cameraRayLookat(global const TRenderOptions* opts, const TRenderState* state) {
  float3 forward = normalize(opts->targetPos - state->eyePos);
  float3 right = normalize(cross(forward, opts->up));
  float2 viewCoord = state->pixelPos / (float2)(opts->resolution.x, opts->resolution.y) * 2.0f - 1.0f;
  viewCoord.y *= opts->invAspect;
  TRay ray;
  ray.pos = state->eyePos;
  ray.dir = normalize(right * viewCoord.x + cross(right, forward) * viewCoord.y + forward);
  return ray;
}

TRenderState initRenderState(global const TRenderOptions* opts, const int id) {
  float2 p = (float2)(id % opts->resolution.x, id / opts->resolution.x);
  float4 s1 = sin((float4)(opts->time * 3.3422f + p.x) * (float4)(324.324234f, 563.324234f, 657.324234f, 764.324234f)) * 543.3423f;
  float4 s2 = sin((float4)(opts->time * 1.3422f + p.y) * (float4)(567.324234f, 435.324234f, 432.324234f, 657.324234f)) * 654.5423f;
  TRenderState state;
  float4 tmp;
  state.mcPos = fract((float4)(2142.4f) + s1 + s2, &tmp);
  state.mcNormal = normalize(state.mcPos.xyz - 0.5f);
  state.pixelPos = p + state.mcPos.zw;
  state.eyePos = opts->eyePos + state.mcNormal * opts->dof;
  return state;
}

__kernel void renderImage(global const float* voxels,
                          global float4* pixels,
                          global const TRenderOptions* opts,
                          const int n) {

  int id = get_global_id(0);
  if (id < n) {
    TRenderState state = initRenderState(opts, id);
    TRay ray = cameraRayLookat(opts, &state);
    float3 sceneCol = sceneColor(voxels, opts, &state, &ray) * opts->exposure;
    float4 prevCol = pixels[id] + (state.mcPos - 0.4f) * (1.0f / 255.0f);
    //float4 finalCol = mix(prevCol, (float4)(sceneCol, 1.0f), opts->frameBlend);
    float4 finalCol = (float4)(mix(prevCol.x, sceneCol.x, opts->frameBlend),
                               mix(prevCol.y, sceneCol.y, opts->frameBlend),
                               mix(prevCol.z, sceneCol.z, opts->frameBlend),
                               1.0f);
    //float4 finalCol = (float4)(1.0f);
    pixels[id] = min(max(finalCol, (float4)(0.0f)), (float4)(1.0f));
  }
}

__kernel void tonemapImage(global float4* pixels,
                           global TRenderOptions* opts,
                           const int n) {
  int id = get_global_id(0);
  if (id < n) {
    pixels[id] = (float4)(tonemap(pixels[id].xyz, opts->gamma), 1.0f);
  }
}