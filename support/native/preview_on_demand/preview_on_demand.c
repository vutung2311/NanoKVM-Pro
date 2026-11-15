/*
 * Feed the LCD preview scaler only while something displays it.
 *
 * kvm_vin links the capture channel (VIN 0/0) to the IVPS group that scales
 * frames for the 320x172 LCD, and keeps that link for as long as it runs. The
 * scaler then reads every captured frame (7.4 MB at 2560x1440 YUYV, 60 times a
 * second) whether or not kvm_ui shows it. kvm_ui pulls scaled frames with
 * AX_IVPS_GetChnFrame only while a user holds its preview token (the live
 * preview window, or the LED strip's ambient light), so those calls are the
 * signal that the preview is in use.
 *
 * kvmcomm.sh preloads this library into both programs with KVM_PREVIEW_ROLE:
 *
 *   vin  kvm_vin does not make its VIN -> IVPS link, and unlinking it succeeds
 *        when the link does not exist: kvm_vin's resolution-change rebuild
 *        aborts on a failed unlink.
 *   ui   the first frame request links VIN -> IVPS, a request that finds the
 *        link gone (kvm_vin rebuilt the pipeline) relinks it, and no request
 *        for UNLINK_IDLE_MS unlinks it. A link belongs to the process that
 *        made it, so it also goes when kvm_ui exits.
 *
 * Both roles must be preloaded together. Every other link, including the
 * encoders' (VIN 0/0 -> VENC), passes through untouched.
 *
 * The few Axera SDK types used are declared here, and the vendor functions are
 * resolved at run time, so this builds with the cross compiler alone.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

/* From the AX620E SDK (ax_base_type.h, ax_global_type.h, ax_sys_api.h). */
typedef int AX_S32;
typedef unsigned int AX_U32;
typedef AX_S32 IVPS_GRP;
typedef AX_S32 IVPS_CHN;
enum { AX_ID_IVPS = 0x0d, AX_ID_VIN = 0x11 };
typedef struct { AX_S32 enModId; AX_S32 s32GrpId; AX_S32 s32ChnId; } AX_MOD_INFO_T;
#define AX_LINK_DEST_MAXNUM 6
typedef struct { AX_U32 u32DestNum; AX_MOD_INFO_T astDestMod[AX_LINK_DEST_MAXNUM]; } AX_LINK_DEST_T;
#define AX_ERR_LINK_UNEXIST ((AX_S32)0x800B0317)
#define AX_ERR_LINK_TABLE_EMPTY ((AX_S32)0x800B0381) /* no link at all */

#define UNLINK_IDLE_MS 1000
#define RELINK_CHECK_MS 200

static const AX_MOD_INFO_T PREVIEW_SRC = { AX_ID_VIN, 0, 0 };
static const AX_MOD_INFO_T PREVIEW_DST = { AX_ID_IVPS, 0, 0 };

typedef AX_S32 (*link_fn)(const AX_MOD_INFO_T *, const AX_MOD_INFO_T *);
typedef AX_S32 (*links_fn)(const AX_MOD_INFO_T *, AX_LINK_DEST_T *);
typedef AX_S32 (*get_frame_fn)(IVPS_GRP, IVPS_CHN, void *, AX_S32);

enum role { ROLE_NONE, ROLE_VIN, ROLE_UI };
static enum role role = ROLE_NONE;

static link_fn real_link, real_unlink;
static links_fn real_links_by_src;
static get_frame_fn real_get_frame;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_llong last_request_ms; /* last frame request on IVPS 0/0, 0 = none since unlink */
static long long last_check_ms;      /* last relink check, under lock */

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int same_mod(const AX_MOD_INFO_T *a, const AX_MOD_INFO_T *b)
{
    return a->enModId == b->enModId && a->s32GrpId == b->s32GrpId && a->s32ChnId == b->s32ChnId;
}

static int is_preview(const AX_MOD_INFO_T *src, const AX_MOD_INFO_T *dst)
{
    return src && dst && same_mod(src, &PREVIEW_SRC) && same_mod(dst, &PREVIEW_DST);
}

static int preview_linked(void)
{
    AX_LINK_DEST_T dests;
    memset(&dests, 0, sizeof dests);
    if (!real_links_by_src) /* resolved late: libax_sys may load after us */
        real_links_by_src = (links_fn)dlsym(RTLD_DEFAULT, "AX_SYS_GetLinkBySrc");
    if (!real_links_by_src || real_links_by_src(&PREVIEW_SRC, &dests) != 0)
        return 0;
    for (AX_U32 i = 0; i < dests.u32DestNum && i < AX_LINK_DEST_MAXNUM; i++)
        if (same_mod(&dests.astDestMod[i], &PREVIEW_DST))
            return 1;
    return 0;
}

AX_S32 AX_SYS_Link(const AX_MOD_INFO_T *src, const AX_MOD_INFO_T *dst)
{
    if (role == ROLE_VIN && is_preview(src, dst))
        return 0; /* made on demand by kvm_ui */
    return real_link(src, dst);
}

AX_S32 AX_SYS_UnLink(const AX_MOD_INFO_T *src, const AX_MOD_INFO_T *dst)
{
    if (role == ROLE_VIN && is_preview(src, dst)) {
        /* kvm_vin destroys the IVPS group next: drop kvm_ui's link if any.
         * With no viewer and no stream the link table is empty, which the
         * SDK reports as TABLE_EMPTY rather than UNEXIST. */
        AX_S32 ret = real_unlink(src, dst);
        return ret == AX_ERR_LINK_UNEXIST || ret == AX_ERR_LINK_TABLE_EMPTY ? 0 : ret;
    }
    return real_unlink(src, dst);
}

AX_S32 AX_IVPS_GetChnFrame(IVPS_GRP grp, IVPS_CHN chn, void *frame, AX_S32 timeout_ms)
{
    if (role == ROLE_UI && grp == PREVIEW_DST.s32GrpId && chn == PREVIEW_DST.s32ChnId) {
        long long now = now_ms();
        atomic_store(&last_request_ms, now);
        pthread_mutex_lock(&lock);
        if (now - last_check_ms >= RELINK_CHECK_MS) {
            last_check_ms = now;
            if (!preview_linked()) {
                AX_S32 ret = real_link(&PREVIEW_SRC, &PREVIEW_DST);
                syslog(LOG_INFO, "preview requested: link VIN->IVPS: 0x%X", (unsigned)ret);
            }
        }
        pthread_mutex_unlock(&lock);
    }
    return real_get_frame(grp, chn, frame, timeout_ms);
}

static void *idle_unlinker(void *arg)
{
    (void)arg;
    for (;;) {
        usleep(250 * 1000);
        long long last = atomic_load(&last_request_ms);
        if (!last || now_ms() - last < UNLINK_IDLE_MS)
            continue;
        pthread_mutex_lock(&lock);
        if (atomic_load(&last_request_ms) == last) {
            if (preview_linked()) {
                AX_S32 ret = real_unlink(&PREVIEW_SRC, &PREVIEW_DST);
                syslog(LOG_INFO, "preview idle: unlink VIN->IVPS: 0x%X", (unsigned)ret);
            }
            atomic_store(&last_request_ms, 0);
        }
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

__attribute__((constructor)) static void init(void)
{
    const char *env = getenv("KVM_PREVIEW_ROLE");
    char r[8] = "";
    if (env)
        snprintf(r, sizeof r, "%s", env);
    /* Programs these run (kvm_ui runs shell commands) must not load this. */
    unsetenv("LD_PRELOAD");
    unsetenv("KVM_PREVIEW_ROLE");

    real_link = (link_fn)dlsym(RTLD_NEXT, "AX_SYS_Link");
    real_unlink = (link_fn)dlsym(RTLD_NEXT, "AX_SYS_UnLink");
    real_get_frame = (get_frame_fn)dlsym(RTLD_NEXT, "AX_IVPS_GetChnFrame");
    openlog("preview-on-demand", LOG_PID, LOG_DAEMON);
    if (!real_link || !real_unlink) {
        if (r[0])
            syslog(LOG_ERR, "libax_sys not loaded: preview shim disabled");
        return;
    }
    if (!strcmp(r, "vin")) {
        role = ROLE_VIN;
    } else if (!strcmp(r, "ui") && real_get_frame) {
        pthread_t t;
        role = ROLE_UI;
        if (pthread_create(&t, NULL, idle_unlinker, NULL) == 0)
            pthread_detach(t);
    }
    if (role != ROLE_NONE)
        syslog(LOG_INFO, "active as %s", r);
}
