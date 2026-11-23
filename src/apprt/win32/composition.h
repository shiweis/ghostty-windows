#ifndef GHOSTTY_WIN32_COMPOSITION_H
#define GHOSTTY_WIN32_COMPOSITION_H

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ghostty_composition ghostty_composition;
/* Calls require this surface's current WGL context and serialized ownership. */

HRESULT ghostty_composition_create(HWND hwnd, UINT width, UINT height,
                                   unsigned int renderbuffer,
                                   ghostty_composition **out);
HRESULT ghostty_composition_resize(ghostty_composition *self, UINT width,
                                   UINT height,
                                   unsigned int renderbuffer);
HRESULT ghostty_composition_lock(ghostty_composition *self);
HRESULT ghostty_composition_present(ghostty_composition *self);
HRESULT ghostty_composition_cancel(ghostty_composition *self);
void ghostty_composition_destroy(ghostty_composition *self);

#ifdef __cplusplus
}
#endif

#endif
