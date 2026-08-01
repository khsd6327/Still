/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef STILL_DXMT_BRIDGE_V1_H
#define STILL_DXMT_BRIDGE_V1_H

#include <stdint.h>

#define STILL_DXMT_BRIDGE_ABI_V1 1u

typedef void *still_dxmt_hwnd;
typedef void *still_dxmt_metal_device;
typedef void *still_dxmt_metal_view;
typedef void *still_dxmt_metal_layer;

/* The producer owns the returned view. The consumer must release every
 * non-null view exactly once through the matching table. The layer is borrowed
 * for the lifetime of that view. All outputs are cleared on failure. */
struct still_dxmt_bridge_v1
{
    uint32_t abi_version;
    uint32_t struct_size;
    still_dxmt_metal_view (*create_metal_view)(still_dxmt_hwnd hwnd,
                                               still_dxmt_metal_device device,
                                               still_dxmt_metal_layer *layer);
    void (*release_metal_view)(still_dxmt_metal_view view);
};

typedef const struct still_dxmt_bridge_v1 *(*still_dxmt_query_bridge_fn)(
    uint32_t minimum_abi, uint32_t maximum_abi);

#endif
