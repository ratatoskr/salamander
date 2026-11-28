/* C's side of the agree test: calls Zig's tables through the generated helpers, implements a trait for
 * Zig to call, and provides an object through the host. Built with warnings as errors. */

#include "test_schema.h"

/* Calls into Zig */

bool c_damage(Damageable d, float amount) { return Damageable_damage(d, amount); }

float c_health(Damageable d) { return Damageable_health(d); }

Vec3 c_position(Damageable d) { return Damageable_position(d); }

uint32_t c_restore(Freecam f, sal_string name, Vec3 *out) { return Freecam_restore(f, name, out); }

sal_string c_load(Freecam f, sal_string path, Opt_u32 limit) {
    Slice_u8 s = Freecam_load(f, path, limit);
    sal_string out = { (const char *)s.ptr, s.len };
    return out;
}

/* Bitfields go through accessors, so Zig checks C reads its bits the same */

uint32_t c_flags_level(Flags f) { return Flags_level(f); }

Flags c_flags_with_job(Flags f, Job j) { return Flags_with_job(f, j); }

/* A trait implemented in C */

typedef struct Cam {
    float speed;
    uint32_t restores;
} Cam;

static void cam_set_speed(uintptr_t self, float speed) { ((Cam *)self)->speed = speed; }

static Slice_u8 cam_load(uintptr_t self, sal_string path, Opt_u32 limit) {
    (void)self;
    Slice_u8 s = { (const uint8_t *)path.ptr, path.len };
    if (limit.some && limit.value < s.len) s.len = limit.value;
    return s;
}

static uint32_t cam_restore(uintptr_t self, sal_string name, Vec3 *out) {
    Cam *cam = (Cam *)self;
    cam->restores += 1;
    if (name.len == 0) return LoadError_NotFound;
    Vec3 v = { cam->speed, (float)name.len, 0 };
    *out = v;
    return SAL_OK;
}

/* Only the methods it has. The rest are null, so callers get zero or SAL_UNSUPPORTED */
static const Freecam_table cam_table = {
    SAL_TABLE(Freecam),
    .setSpeed = cam_set_speed,
    .load = cam_load,
    .restore = cam_restore,
};

static Cam cam;

Freecam c_cam(void) {
    Freecam f = { (uintptr_t)&cam, &cam_table };
    return f;
}

float c_cam_speed(void) { return cam.speed; }

/* Provides one through the host, owned so the host never points at code that's gone */
uint32_t c_provide(sal_Host host) {
    sal_Owner *owner = sal_Host_owner(host, SAL_STR("c"));
    Freecam mine = { (uintptr_t)&cam, &cam_table };
    return sal_provide_Freecam(host, SAL_STR("c.cam"), 1, sal_own_Freecam(host, mine, owner));
}

/* Gets one back through the host, laid out like this header's version */
float c_get_and_set(sal_Host host, float speed) {
    Freecam f = sal_get_Freecam(host, SAL_STR("c.cam"), 1);
    if (!f.table) return -1;
    Freecam_setSpeed(f, speed);
    return cam.speed;
}

/* Type info, which has to be the same as every other language's */
const sal_TypeInfo *c_type_info(uint32_t which) {
    switch (which) {
    case 0: return &Player_sal_type;
    case 1: return &Scene_Graph_sal_type;
    case 2: return &Bag_sal_type;
    case 3: return &Shape_sal_type;
    default: return NULL;
    }
}

/* A Vec3 through an any, and back only as one */
float c_any_y(void) {
    Vec3 v = { 1, 2, 3 };
    sal_any a = SAL_ANY(Vec3, &v);
    const Vec3 *back = SAL_AS(Vec3, a);
    const Pair *other = SAL_AS(Pair, a);
    return back && !other ? back->y : -1;
}
