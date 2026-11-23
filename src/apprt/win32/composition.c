#include "composition.h"

#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <dwmapi.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef HANDLE (WINAPI *PFNWGLDXOPENDEVICENV)(void *);
typedef BOOL (WINAPI *PFNWGLDXCLOSEDEVICENV)(HANDLE);
typedef HANDLE (WINAPI *PFNWGLDXREGISTEROBJECTNV)(HANDLE, void *, GLuint, GLenum, GLenum);
typedef BOOL (WINAPI *PFNWGLDXUNREGISTEROBJECTNV)(HANDLE, HANDLE);
typedef BOOL (WINAPI *PFNWGLDXLOCKOBJECTSNV)(HANDLE, GLint, HANDLE *);
typedef BOOL (WINAPI *PFNWGLDXUNLOCKOBJECTSNV)(HANDLE, GLint, HANDLE *);
typedef const char *(WINAPI *PFNWGLGETEXTENSIONSSTRINGARB)(HDC);

enum {
    GHOSTTY_WGL_ACCESS_WRITE_DISCARD_NV = 0x0002,
    GHOSTTY_GL_RENDERBUFFER = 0x8D41,
};


struct ghostty_composition {
    unsigned int renderbuffer;
    PFNWGLDXOPENDEVICENV open_device;
    HANDLE interop_device;
    HANDLE interop_object;
    PFNWGLDXCLOSEDEVICENV close_device;
    PFNWGLDXREGISTEROBJECTNV register_object;
    PFNWGLDXUNREGISTEROBJECTNV unregister_object;
    PFNWGLDXLOCKOBJECTSNV lock_objects;
    PFNWGLDXUNLOCKOBJECTSNV unlock_objects;
    ID3D11Device *d3d_device;
    ID3D11DeviceContext *d3d_context;
    IDXGISwapChain1 *swap_chain;
    IDCompositionDevice *composition_device;
    IDCompositionTarget *composition_target;
    IDCompositionVisual *root_visual;
    ID3D11Texture2D *backbuffer;
    ID3D11Texture2D *interop_texture;
    BOOL locked;
};

static void warn_cleanup(const char *api) {
    fprintf(stderr, "warning(win32): %s failed during composition cleanup (Win32 error=%lu)\n",
            api, (unsigned long)GetLastError());
}

static void release_candidate(ghostty_composition *self) {
    if (self->locked) {
        HANDLE objects[1] = {self->interop_object};
        if (!self->unlock_objects(self->interop_device, 1, objects))
            warn_cleanup("wglDXUnlockObjectsNV");
        self->locked = FALSE;
    }
    if (self->interop_object && self->interop_device) {
        if (!self->unregister_object(self->interop_device, self->interop_object))
            warn_cleanup("wglDXUnregisterObjectNV");
        self->interop_object = NULL;
    }
    if (self->interop_texture) {
        self->interop_texture->Release();
        self->interop_texture = NULL;
    }
    if (self->backbuffer) {
        self->backbuffer->Release();
        self->backbuffer = NULL;
    }
    if (self->root_visual) {
        self->root_visual->Release();
        self->root_visual = NULL;
    }
    if (self->composition_target) {
        self->composition_target->Release();
        self->composition_target = NULL;
    }
    if (self->composition_device) {
        self->composition_device->Release();
        self->composition_device = NULL;
    }
    if (self->swap_chain) {
        self->swap_chain->Release();
        self->swap_chain = NULL;
    }
    if (self->interop_device) {
        if (!self->close_device(self->interop_device))
            warn_cleanup("wglDXCloseDeviceNV");
        self->interop_device = NULL;
    }
    if (self->d3d_context) {
        self->d3d_context->Release();
        self->d3d_context = NULL;
    }
    if (self->d3d_device) {
        self->d3d_device->Release();
        self->d3d_device = NULL;
    }
}

static HRESULT install_backbuffer(ghostty_composition *self) {
    HRESULT hr = self->swap_chain->GetBuffer(0, IID_PPV_ARGS(&self->backbuffer));
    if (FAILED(hr)) return hr;
    // NV interop pins an allocation; flip-model backbuffers rotate underneath it.
    D3D11_TEXTURE2D_DESC desc;
    self->backbuffer->GetDesc(&desc);
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    desc.MiscFlags = 0;
    hr = self->d3d_device->CreateTexture2D(&desc, NULL, &self->interop_texture);
    if (FAILED(hr)) return hr;

    self->interop_object = self->register_object(
        self->interop_device,
        self->interop_texture,
        (GLuint)self->renderbuffer,
        GHOSTTY_GL_RENDERBUFFER,
        GHOSTTY_WGL_ACCESS_WRITE_DISCARD_NV);
    if (!self->interop_object) {
        self->backbuffer->Release();
        self->backbuffer = NULL;
        return DXGI_ERROR_UNSUPPORTED;
    }
    return S_OK;
}


static BOOL has_extension(const char *extensions, const char *wanted) {
    const size_t length = strlen(wanted);
    const char *at = extensions;
    while ((at = strstr(at, wanted)) != NULL) {
        if ((at == extensions || at[-1] == ' ') &&
            (at[length] == '\0' || at[length] == ' ')) return TRUE;
        at += length;
    }
    return FALSE;
}

static PROC load_wgl_proc(const char *name) {
    PROC proc = wglGetProcAddress(name);
    if (!proc || proc == (PROC)1 || proc == (PROC)2 ||
        proc == (PROC)3 || proc == (PROC)(INT_PTR)-1) return NULL;
    return proc;
}

static HRESULT resolve_interop(ghostty_composition *self) {
    HDC dc = wglGetCurrentDC();
    if (!dc) return DXGI_ERROR_UNSUPPORTED;

    PFNWGLGETEXTENSIONSSTRINGARB get_extensions =
        (PFNWGLGETEXTENSIONSSTRINGARB)load_wgl_proc("wglGetExtensionsStringARB");
    if (!get_extensions) return DXGI_ERROR_UNSUPPORTED;
    const char *extensions = get_extensions(dc);
    if (!extensions || !has_extension(extensions, "WGL_NV_DX_interop2"))
        return DXGI_ERROR_UNSUPPORTED;

    self->open_device = (PFNWGLDXOPENDEVICENV)load_wgl_proc("wglDXOpenDeviceNV");
    self->close_device = (PFNWGLDXCLOSEDEVICENV)load_wgl_proc("wglDXCloseDeviceNV");
    self->register_object = (PFNWGLDXREGISTEROBJECTNV)load_wgl_proc("wglDXRegisterObjectNV");
    self->unregister_object = (PFNWGLDXUNREGISTEROBJECTNV)load_wgl_proc("wglDXUnregisterObjectNV");
    self->lock_objects = (PFNWGLDXLOCKOBJECTSNV)load_wgl_proc("wglDXLockObjectsNV");
    self->unlock_objects = (PFNWGLDXUNLOCKOBJECTSNV)load_wgl_proc("wglDXUnlockObjectsNV");
    if (!self->open_device || !self->close_device || !self->register_object ||
        !self->unregister_object || !self->lock_objects || !self->unlock_objects)
        return DXGI_ERROR_UNSUPPORTED;
    return S_OK;
}

HRESULT ghostty_composition_create(HWND hwnd, UINT width, UINT height,
                                   unsigned int renderbuffer,
                                   ghostty_composition **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!hwnd || !renderbuffer || width == 0 || height == 0) return E_INVALIDARG;
    BOOL composition_enabled = FALSE;
    if (FAILED(DwmIsCompositionEnabled(&composition_enabled)) || !composition_enabled)
        return DXGI_ERROR_UNSUPPORTED;

    ghostty_composition *self = (ghostty_composition *)calloc(1, sizeof(*self));
    if (!self) return E_OUTOFMEMORY;
    self->renderbuffer = renderbuffer;

    HRESULT hr = resolve_interop(self);
    if (FAILED(hr)) {
        free(self);
        return hr;
    }

    IDXGIFactory1 *factory = NULL;
    hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) {
        free(self);
        return hr;
    }

    HRESULT last_error = DXGI_ERROR_UNSUPPORTED;
    for (UINT index = 0;; ++index) {
        IDXGIAdapter1 *adapter = NULL;
        hr = factory->EnumAdapters1(index, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) {
            if (adapter) adapter->Release();
            last_error = hr;
            break;
        }
        DXGI_ADAPTER_DESC1 adapter_desc;
        hr = adapter->GetDesc1(&adapter_desc);
        if (FAILED(hr)) {
            last_error = hr;
            adapter->Release();
            continue;
        }
        if (adapter_desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
            adapter->Release();
            continue;
        }

        hr = D3D11CreateDevice(
            (IDXGIAdapter *)adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            NULL,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            NULL,
            0,
            D3D11_SDK_VERSION,
            &self->d3d_device,
            NULL,
            &self->d3d_context);
        if (SUCCEEDED(hr)) {
            self->interop_device = self->open_device(self->d3d_device);
            if (!self->interop_device) hr = DXGI_ERROR_UNSUPPORTED;
        }
        if (SUCCEEDED(hr)) {
            IDXGIFactory2 *adapter_factory = NULL;
            hr = adapter->GetParent(IID_PPV_ARGS(&adapter_factory));
            if (SUCCEEDED(hr)) {
                DXGI_SWAP_CHAIN_DESC1 desc;
                ZeroMemory(&desc, sizeof(desc));
                desc.Width = width;
                desc.Height = height;
                desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
                desc.SampleDesc.Count = 1;
                desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
                desc.BufferCount = 2;
                desc.Scaling = DXGI_SCALING_STRETCH;
                desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
                desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
                hr = adapter_factory->CreateSwapChainForComposition(
                    self->d3d_device, &desc, NULL, &self->swap_chain);
                adapter_factory->Release();
            }
            if (SUCCEEDED(hr)) {
                IDXGIDevice *dxgi_device = NULL;
                hr = self->d3d_device->QueryInterface(IID_PPV_ARGS(&dxgi_device));
                if (SUCCEEDED(hr)) {
                    hr = DCompositionCreateDevice(
                        dxgi_device, __uuidof(IDCompositionDevice),
                        (void **)&self->composition_device);
                    dxgi_device->Release();
                }
            }
            if (SUCCEEDED(hr))
                hr = self->composition_device->CreateTargetForHwnd(
                    hwnd, FALSE, &self->composition_target);
            if (SUCCEEDED(hr))
                hr = self->composition_device->CreateVisual(&self->root_visual);
            if (SUCCEEDED(hr)) hr = self->root_visual->SetContent(self->swap_chain);
            if (SUCCEEDED(hr)) hr = self->composition_target->SetRoot(self->root_visual);
            if (SUCCEEDED(hr)) hr = self->composition_device->Commit();
            if (SUCCEEDED(hr)) hr = install_backbuffer(self);
        }
        adapter->Release();
        if (SUCCEEDED(hr)) break;
        last_error = hr;
        release_candidate(self);
    }
    factory->Release();
    if (FAILED(hr) || !self->interop_object) {
        release_candidate(self);
        free(self);
        return last_error;
    }
    *out = self;
    return S_OK;
}

HRESULT ghostty_composition_resize(ghostty_composition *self, UINT width,
                                   UINT height, unsigned int renderbuffer) {
    if (!self) return E_POINTER;
    if (width == 0 || height == 0) return S_OK;
    if (!renderbuffer) return E_INVALIDARG;
    if (self->locked) {
        HANDLE objects[1] = {self->interop_object};
        if (!self->unlock_objects(self->interop_device, 1, objects)) return E_FAIL;
        self->locked = FALSE;
    }
    if (self->interop_object) {
        if (!self->unregister_object(self->interop_device, self->interop_object))
            return E_FAIL;
        self->interop_object = NULL;
    }
    if (self->interop_texture) {
        self->interop_texture->Release();
        self->interop_texture = NULL;
    }
    if (self->backbuffer) {
        self->backbuffer->Release();
        self->backbuffer = NULL;
    }

    HRESULT hr = self->swap_chain->ResizeBuffers(2, width, height,
                                                 DXGI_FORMAT_B8G8R8A8_UNORM, 0);
    if (FAILED(hr)) return hr;
    self->renderbuffer = renderbuffer;
    return install_backbuffer(self);
}

HRESULT ghostty_composition_lock(ghostty_composition *self) {
    if (!self) return E_POINTER;
    if (self->locked) return S_FALSE;
    HANDLE objects[1] = {self->interop_object};
    if (!self->interop_object ||
        !self->lock_objects(self->interop_device, 1, objects)) return E_FAIL;
    self->locked = TRUE;
    return S_OK;
}

HRESULT ghostty_composition_cancel(ghostty_composition *self) {
    if (!self) return E_POINTER;
    if (!self->locked) return S_OK;
    HANDLE objects[1] = {self->interop_object};
    if (!self->unlock_objects(self->interop_device, 1, objects)) return E_FAIL;
    self->locked = FALSE;
    return S_OK;
}

HRESULT ghostty_composition_present(ghostty_composition *self) {
    if (!self) return E_POINTER;
    if (!self->locked) return E_UNEXPECTED;
    HRESULT hr = ghostty_composition_cancel(self);
    if (FAILED(hr)) return hr;
    if (!self->swap_chain) return E_POINTER;
    self->d3d_context->CopyResource(self->backbuffer, self->interop_texture);
    return self->swap_chain->Present(1, 0);
}

void ghostty_composition_destroy(ghostty_composition *self) {
    if (!self) return;
    release_candidate(self);
    free(self);
}
