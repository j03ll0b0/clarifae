/*
 * effect.c — Clarifae Android pre-processing effect.
 *
 * Implements the AOSP effect ABI: it exports the AUDIO_EFFECT_LIBRARY_INFO_SYM
 * (symbol "AELI") so AudioFlinger can load libclarifae.so, advertises a
 * noise-suppression pre-processing descriptor, and on each process() pass hands
 * the captured PCM to the selected backend (rnnoise / dtln / deepfilternet).
 *
 * Configuration is read live from persist.clarifae.* (see config.c); changes
 * made from the WebUI apply to the next process() pass without a reboot. The
 * host enable/disable plus persist.clarifae.enabled together gate processing;
 * when bypassed the input is copied through untouched.
 */
#include "audio_effect.h"
#include "clarifae_uuid.h"
#include "backend.h"
#include "config.h"
#include "log.h"

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const struct effect_interface_s* itfe;  /* MUST be first: handle aliases this */
    effect_descriptor_t desc;

    int      host_enabled;   /* EFFECT_CMD_ENABLE/DISABLE */
    int      configured;
    uint32_t sample_rate;
    int      channels;
    uint8_t  in_format, out_format;
    uint8_t  in_access, out_access;

    const clarifae_backend_t* backend;
    void*    bstate;
    int      cur_mode;

    clarifae_config_t cfg;

    float*   fbuf;           /* interleaved float scratch [frames*channels] */
    size_t   fbuf_cap;       /* capacity in floats */
} clarifae_ctx_t;

/* ---- descriptor ---- */
static const effect_uuid_t kTypeNs = CLARIFAE_TYPE_NS_UUID;
static const effect_uuid_t kImpl   = CLARIFAE_IMPL_UUID;

static void fill_descriptor(effect_descriptor_t* d) {
    memset(d, 0, sizeof(*d));
    d->type = kTypeNs;
    d->uuid = kImpl;
    d->apiVersion = EFFECT_CONTROL_API_VERSION;
    d->flags = EFFECT_FLAG_TYPE_PRE_PROC | EFFECT_FLAG_INSERT_FIRST;
    d->cpuLoad = 20;       /* ~2 MIPS hint */
    d->memoryUsage = 512;  /* KB hint */
    strncpy(d->name, "Clarifae NS", EFFECT_STRING_LEN - 1);
    strncpy(d->implementor, "Clarifae Project", EFFECT_STRING_LEN - 1);
}

static int uuid_eq(const effect_uuid_t* a, const effect_uuid_t* b) {
    return memcmp(a, b, sizeof(effect_uuid_t)) == 0;
}

/* ---- backend lifecycle ---- */
static void backend_close(clarifae_ctx_t* c) {
    if (c->backend && c->bstate) c->backend->destroy(c->bstate);
    c->backend = NULL;
    c->bstate = NULL;
}

static void backend_apply_params(clarifae_ctx_t* c) {
    if (c->backend && c->bstate) {
        c->backend->set_params(c->bstate,
                               (float)c->cfg.strength / 100.0f,
                               (float)c->cfg.atten_db,
                               (float)c->cfg.vad / 100.0f,
                               c->cfg.highpass, c->cfg.autogain);
    }
}

static int backend_open(clarifae_ctx_t* c) {
    backend_close(c);
    if (c->sample_rate == 0 || c->channels <= 0) return -EINVAL;

    char err[160] = {0};
    const clarifae_backend_t* b = clarifae_backend_for_mode(c->cfg.mode);
    void* st = b->create((int)c->sample_rate, c->channels, err, sizeof(err));
    if (!st && b != clarifae_backend_rnnoise()) {
        CLARIFAE_LOGW("backend '%s' create failed (%s); falling back to rnnoise",
                      b->name, err);
        b = clarifae_backend_rnnoise();
        st = b->create((int)c->sample_rate, c->channels, err, sizeof(err));
    }
    if (!st) {
        CLARIFAE_LOGE("backend create failed: %s", err);
        return -ENODEV;
    }
    c->backend = b;
    c->bstate = st;
    c->cur_mode = c->cfg.mode;
    backend_apply_params(c);
    CLARIFAE_LOGI("active backend=%s mode=%d rate=%u ch=%d", b->name, c->cfg.mode,
                  c->sample_rate, c->channels);
    return 0;
}

static int ensure_fbuf(clarifae_ctx_t* c, size_t need) {
    if (need <= c->fbuf_cap) return 0;
    float* nb = (float*)realloc(c->fbuf, need * sizeof(float));
    if (!nb) return -ENOMEM;
    c->fbuf = nb;
    c->fbuf_cap = need;
    return 0;
}

/* ---- effect interface callbacks ---- */
static int32_t ce_process(effect_handle_t self,
                          audio_buffer_t* in, audio_buffer_t* out) {
    clarifae_ctx_t* c = (clarifae_ctx_t*)self;
    if (!c || !in || !out || !in->raw || !out->raw) return -EINVAL;

    size_t frames = in->frameCount;
    if (out->frameCount < frames) frames = out->frameCount;
    int ch = c->channels > 0 ? c->channels : 1;

    /* live config refresh (cheap serial check) */
    if (clarifae_config_changed()) {
        int prev_mode = c->cfg.mode;
        clarifae_config_load(&c->cfg);   /* also updates clarifae_log_level */
        if (c->configured) {
            if (c->cfg.mode != prev_mode || !c->backend) {
                backend_open(c);
            } else {
                backend_apply_params(c);
            }
        }
    }

    int bypass = (!c->cfg.enabled) || (!c->configured) || (!c->backend) || (!c->bstate);

    /* ---- bypass: copy input to output (respecting accumulate) ---- */
    if (bypass) {
        size_t n = frames * (size_t)ch;
        if (c->in_format == AUDIO_FORMAT_PCM_FLOAT) {
            if (c->out_access == EFFECT_BUFFER_ACCESS_ACCUMULATE)
                for (size_t i = 0; i < n; i++) out->f32[i] += in->f32[i];
            else
                memmove(out->f32, in->f32, n * sizeof(float));
        } else {
            if (c->out_access == EFFECT_BUFFER_ACCESS_ACCUMULATE)
                for (size_t i = 0; i < n; i++) {
                    int32_t v = out->s16[i] + in->s16[i];
                    out->s16[i] = (int16_t)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
                }
            else
                memmove(out->s16, in->s16, n * sizeof(int16_t));
        }
        return 0;
    }

    size_t n = frames * (size_t)ch;
    if (ensure_fbuf(c, n) != 0) return -ENOMEM;

    /* input -> float (int16 range) */
    if (c->in_format == AUDIO_FORMAT_PCM_FLOAT) {
        for (size_t i = 0; i < n; i++) c->fbuf[i] = in->f32[i] * 32768.0f;
    } else {
        for (size_t i = 0; i < n; i++) c->fbuf[i] = (float)in->s16[i];
    }

    c->backend->process(c->bstate, c->fbuf, (int)frames);

    /* float -> output */
    if (c->out_format == AUDIO_FORMAT_PCM_FLOAT) {
        for (size_t i = 0; i < n; i++) {
            float v = c->fbuf[i] / 32768.0f;
            if (v < -1.0f) v = -1.0f; else if (v > 1.0f) v = 1.0f;
            if (c->out_access == EFFECT_BUFFER_ACCESS_ACCUMULATE) out->f32[i] += v;
            else out->f32[i] = v;
        }
    } else {
        for (size_t i = 0; i < n; i++) {
            float fv = c->fbuf[i];
            int32_t v = (int32_t)lrintf(fv);
            if (v < -32768) v = -32768; else if (v > 32767) v = 32767;
            if (c->out_access == EFFECT_BUFFER_ACCESS_ACCUMULATE) {
                int32_t a = out->s16[i] + v;
                out->s16[i] = (int16_t)(a < -32768 ? -32768 : (a > 32767 ? 32767 : a));
            } else {
                out->s16[i] = (int16_t)v;
            }
        }
    }
    return 0;
}

static int32_t ce_process_reverse(effect_handle_t self,
                                  audio_buffer_t* in, audio_buffer_t* out) {
    (void)self; (void)in; (void)out;
    return -ENOSYS;   /* no far-end reference path */
}

static void read_buffer_cfg(clarifae_ctx_t* c, const buffer_config_t* incfg,
                            const buffer_config_t* outcfg) {
    c->sample_rate = incfg->samplingRate ? incfg->samplingRate : 16000;
    uint32_t mask = incfg->channels;
    int ch = mask ? __builtin_popcount(mask) : 1;
    if (ch < 1) ch = 1;
    c->channels = ch;
    c->in_format  = incfg->format ? incfg->format : AUDIO_FORMAT_PCM_16_BIT;
    c->out_format = outcfg->format ? outcfg->format : c->in_format;
    c->in_access  = incfg->accessMode;
    c->out_access = outcfg->accessMode;
}

static int32_t ce_command(effect_handle_t self, uint32_t cmd, uint32_t cmdSize,
                          void* pCmd, uint32_t* replySize, void* pReply) {
    clarifae_ctx_t* c = (clarifae_ctx_t*)self;
    if (!c) return -EINVAL;

    switch (cmd) {
    case EFFECT_CMD_INIT:
        if (replySize && pReply && *replySize >= sizeof(int)) *(int*)pReply = 0;
        return 0;

    case EFFECT_CMD_SET_CONFIG: {
        if (!pCmd || cmdSize < sizeof(effect_config_t) ||
            !replySize || !pReply || *replySize < sizeof(int))
            return -EINVAL;
        effect_config_t* ec = (effect_config_t*)pCmd;
        read_buffer_cfg(c, &ec->inputCfg, &ec->outputCfg);
        c->configured = 1;
        clarifae_config_load(&c->cfg);
        int rc = backend_open(c);
        *(int*)pReply = (rc == 0) ? 0 : rc;
        return 0;
    }

    case EFFECT_CMD_GET_CONFIG: {
        if (!replySize || !pReply || *replySize < sizeof(effect_config_t))
            return -EINVAL;
        effect_config_t* ec = (effect_config_t*)pReply;
        memset(ec, 0, sizeof(*ec));
        ec->inputCfg.samplingRate = ec->outputCfg.samplingRate = c->sample_rate;
        ec->inputCfg.format  = c->in_format;
        ec->outputCfg.format = c->out_format;
        ec->inputCfg.accessMode  = c->in_access;
        ec->outputCfg.accessMode = c->out_access;
        ec->inputCfg.mask = ec->outputCfg.mask = EFFECT_CONFIG_ALL;
        return 0;
    }

    case EFFECT_CMD_RESET:
        if (c->backend && c->bstate) c->backend->reset(c->bstate);
        return 0;

    case EFFECT_CMD_ENABLE:
        c->host_enabled = 1;
        if (replySize && pReply && *replySize >= sizeof(int)) *(int*)pReply = 0;
        return 0;

    case EFFECT_CMD_DISABLE:
        c->host_enabled = 0;
        if (replySize && pReply && *replySize >= sizeof(int)) *(int*)pReply = 0;
        return 0;

    /* No proprietary parameters are exposed over this channel — everything is
       configured through persist.clarifae.* — so acknowledge politely. */
    case EFFECT_CMD_SET_PARAM:
    case EFFECT_CMD_SET_PARAM_DEFERRED:
    case EFFECT_CMD_SET_PARAM_COMMIT:
        if (replySize && pReply && *replySize >= sizeof(int)) *(int*)pReply = 0;
        return 0;

    case EFFECT_CMD_GET_PARAM:
        if (replySize) *replySize = 0;
        return 0;

    case EFFECT_CMD_SET_DEVICE:
    case EFFECT_CMD_SET_INPUT_DEVICE:
    case EFFECT_CMD_SET_AUDIO_MODE:
    case EFFECT_CMD_SET_AUDIO_SOURCE:
    case EFFECT_CMD_SET_VOLUME:
    case EFFECT_CMD_OFFLOAD:
        if (replySize && pReply && *replySize >= sizeof(int)) *(int*)pReply = 0;
        return 0;

    default:
        return -EINVAL;
    }
}

static int32_t ce_get_descriptor(effect_handle_t self, effect_descriptor_t* d) {
    clarifae_ctx_t* c = (clarifae_ctx_t*)self;
    if (!c || !d) return -EINVAL;
    *d = c->desc;
    return 0;
}

static const struct effect_interface_s kInterface = {
    .process         = ce_process,
    .command         = ce_command,
    .get_descriptor  = ce_get_descriptor,
    .process_reverse = ce_process_reverse,
};

/* ---- library interface ---- */
static int32_t lib_create(const effect_uuid_t* uuid, int32_t sessionId,
                          int32_t ioId, effect_handle_t* pHandle) {
    (void)sessionId; (void)ioId;
    if (!pHandle || !uuid) return -EINVAL;
    if (!uuid_eq(uuid, &kImpl) && !uuid_eq(uuid, &kTypeNs)) return -EINVAL;

    clarifae_ctx_t* c = (clarifae_ctx_t*)calloc(1, sizeof(*c));
    if (!c) return -ENOMEM;
    c->itfe = &kInterface;
    fill_descriptor(&c->desc);
    clarifae_config_load(&c->cfg);
    c->cur_mode = c->cfg.mode;

    *pHandle = (effect_handle_t)c;
    CLARIFAE_LOGI("effect created (session %d)", sessionId);
    return 0;
}

static int32_t lib_release(effect_handle_t handle) {
    clarifae_ctx_t* c = (clarifae_ctx_t*)handle;
    if (!c) return -EINVAL;
    backend_close(c);
    free(c->fbuf);
    free(c);
    return 0;
}

static int32_t lib_get_descriptor(const effect_uuid_t* uuid,
                                  effect_descriptor_t* d) {
    if (!uuid || !d) return -EINVAL;
    if (!uuid_eq(uuid, &kImpl) && !uuid_eq(uuid, &kTypeNs)) return -EINVAL;
    fill_descriptor(d);
    return 0;
}

__attribute__((visibility("default")))
audio_effect_library_t AUDIO_EFFECT_LIBRARY_INFO_SYM = {
    .tag         = AUDIO_EFFECT_LIBRARY_TAG,
    .version     = EFFECT_LIBRARY_API_VERSION,
    .name        = "Clarifae",
    .implementor = "Clarifae Project",
    .create_effect   = lib_create,
    .release_effect  = lib_release,
    .get_descriptor  = lib_get_descriptor,
};
