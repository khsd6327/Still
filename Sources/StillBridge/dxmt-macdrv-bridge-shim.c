/* SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Compatibility bridge for Wine and DXMT's winemetal.so. Wine loads its Unix
 * libraries locally, so DXMT's
 * dlsym(RTLD_DEFAULT, "macdrv_functions") cannot see winemac symbols.
 * DYLD_INSERT_LIBRARIES makes this compatibility table globally visible.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void *HWND;
typedef void *macdrv_metal_device;
typedef void *macdrv_metal_view;
typedef void *macdrv_metal_layer;
typedef void *macdrv_view;

struct dxmt_win_data
{
    HWND hwnd;
    void *cocoa_window;
    macdrv_view cocoa_view;
    macdrv_view client_cocoa_view;
};

struct proxy_view
{
    macdrv_metal_view actual_view;
    macdrv_metal_layer layer;
};

typedef macdrv_metal_view (*create_bridge_fn)(HWND, macdrv_metal_device,
                                               macdrv_metal_layer *);
typedef void (*release_bridge_fn)(macdrv_metal_view);

static void *open_loaded_winemac(void)
{
    uint32_t i;

    for (i = 0; i < _dyld_image_count(); ++i)
    {
        const char *path = _dyld_get_image_name(i);
        size_t len;

        if (!path) continue;
        len = strlen(path);
        if (len < sizeof("/winemac.so") - 1 ||
            strcmp(path + len - (sizeof("/winemac.so") - 1), "/winemac.so"))
            continue;
        return dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
    }
    return NULL;
}

static struct dxmt_win_data *shim_get_win_data(HWND hwnd)
{
    struct dxmt_win_data *data = calloc(1, sizeof(*data));

    if (!data) return NULL;
    data->hwnd = hwnd;
    data->cocoa_view = hwnd;
    data->client_cocoa_view = hwnd;
    return data;
}

static void shim_release_win_data(struct dxmt_win_data *data)
{
    free(data);
}

static macdrv_metal_view shim_create_metal_view(macdrv_view encoded_hwnd,
                                                 macdrv_metal_device device)
{
    struct proxy_view *proxy;
    create_bridge_fn create_bridge;
    release_bridge_fn release_bridge;
    void *winemac = open_loaded_winemac();

    if (!winemac)
    {
        return NULL;
    }
    create_bridge = (create_bridge_fn)dlsym(winemac,
        "still_macdrv_create_metal_view_from_hwnd_v1");
    if (!create_bridge)
    {
        return NULL;
    }

    proxy = calloc(1, sizeof(*proxy));
    if (!proxy) return NULL;
    proxy->actual_view = create_bridge((HWND)encoded_hwnd, device, &proxy->layer);
    if (!proxy->actual_view || !proxy->layer)
    {
        release_bridge = (release_bridge_fn)dlsym(winemac,
            "still_macdrv_release_metal_view_v1");
        if (proxy->actual_view && release_bridge) release_bridge(proxy->actual_view);
        free(proxy);
        return NULL;
    }
    return proxy;
}

static macdrv_metal_layer shim_get_metal_layer(macdrv_metal_view view)
{
    struct proxy_view *proxy = view;
    return proxy ? proxy->layer : NULL;
}

static void shim_release_metal_view(macdrv_metal_view view)
{
    struct proxy_view *proxy = view;
    release_bridge_fn release_bridge;
    void *winemac;

    if (!proxy) return;
    winemac = open_loaded_winemac();
    release_bridge = winemac ? (release_bridge_fn)dlsym(winemac,
        "still_macdrv_release_metal_view_v1") : NULL;
    if (release_bridge && proxy->actual_view) release_bridge(proxy->actual_view);
    free(proxy);
}

struct dxmt_macdrv_functions
{
    void *macdrv_init_display_devices;
    struct dxmt_win_data *(*get_win_data)(HWND);
    void (*release_win_data)(struct dxmt_win_data *);
    void *macdrv_get_cocoa_window;
    void *macdrv_create_metal_device;
    void *macdrv_release_metal_device;
    macdrv_metal_view (*macdrv_view_create_metal_view)(macdrv_view,
                                                       macdrv_metal_device);
    macdrv_metal_layer (*macdrv_view_get_metal_layer)(macdrv_metal_view);
    void (*macdrv_view_release_metal_view)(macdrv_metal_view);
    void *on_main_thread;
};

__attribute__((visibility("default"))) const struct dxmt_macdrv_functions macdrv_functions =
{
    NULL,
    shim_get_win_data,
    shim_release_win_data,
    NULL,
    NULL,
    NULL,
    shim_create_metal_view,
    shim_get_metal_layer,
    shim_release_metal_view,
    NULL,
};
