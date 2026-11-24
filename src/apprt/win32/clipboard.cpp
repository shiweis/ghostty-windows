#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace {
struct OleApartment {
    HRESULT result = OleInitialize(nullptr);
    ~OleApartment() { if (SUCCEEDED(result)) OleUninitialize(); }
};

struct ClipboardPart {
    UINT format;
    const void *bytes;
    size_t size;
};
}

// Populate a single data object before replacing the previous clipboard.
extern "C" HRESULT ghostty_clipboard_publish(const ClipboardPart *parts, size_t count) {
    OleApartment apartment;
    if (FAILED(apartment.result)) return apartment.result;
    ComPtr<IDataObject> object;
    HRESULT hr = SHCreateDataObject(nullptr, 0, nullptr, nullptr, IID_PPV_ARGS(&object));
    if (FAILED(hr)) return hr;
    for (size_t i = 0; i < count; ++i) {
        const ClipboardPart &part = parts[i];
        STGMEDIUM medium = {};
        medium.tymed = TYMED_HGLOBAL;
        medium.hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, part.size ? part.size : 1);
        if (!medium.hGlobal) return E_OUTOFMEMORY;
        void *data = GlobalLock(medium.hGlobal);
        if (!data) { GlobalFree(medium.hGlobal); return E_OUTOFMEMORY; }
        if (part.size) memcpy(data, part.bytes, part.size);
        GlobalUnlock(medium.hGlobal);
        FORMATETC format = {static_cast<CLIPFORMAT>(part.format), nullptr,
                            DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        hr = object->SetData(&format, &medium, TRUE);
        if (FAILED(hr)) { ReleaseStgMedium(&medium); return hr; }
    }
    hr = OleSetClipboard(object.Get());
    if (FAILED(hr)) return hr;
    return OleFlushClipboard();
}

// A foreign IDataObject may offer an exact stream length, independently of
// any native HGLOBAL allocation padding. Call after closing the clipboard.
extern "C" HRESULT ghostty_clipboard_stream_read(UINT id, size_t budget, HGLOBAL *result, size_t *size) {
    OleApartment apartment;
    if (FAILED(apartment.result)) return apartment.result;
    ComPtr<IDataObject> object;
    HRESULT hr = OleGetClipboard(&object);
    if (FAILED(hr)) return hr;
    FORMATETC type = {static_cast<CLIPFORMAT>(id), nullptr, DVASPECT_CONTENT, -1, TYMED_ISTREAM};
    STGMEDIUM medium = {};
    hr = object->GetData(&type, &medium);
    if (FAILED(hr)) return hr;
    struct Release { STGMEDIUM *m; ~Release() { ReleaseStgMedium(m); } } release{&medium};
    if (medium.tymed != TYMED_ISTREAM || !medium.pstm) return DV_E_TYMED;
    STATSTG stat = {};
    hr = medium.pstm->Stat(&stat, STATFLAG_NONAME);
    if (FAILED(hr)) return hr;
    if (stat.cbSize.QuadPart > budget || stat.cbSize.QuadPart > MAXDWORD) return STG_E_MEDIUMFULL;
    const ULONG n = stat.cbSize.LowPart;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, n ? n : 1);
    if (!memory) return E_OUTOFMEMORY;
    void *dst = GlobalLock(memory);
    if (!dst) { GlobalFree(memory); return E_OUTOFMEMORY; }
    LARGE_INTEGER zero = {};
    hr = medium.pstm->Seek(zero, STREAM_SEEK_SET, nullptr);
    ULONG received = 0;
    if (SUCCEEDED(hr) && n) hr = medium.pstm->Read(dst, n, &received);
    GlobalUnlock(memory);
    if (FAILED(hr) || received != n) {
        GlobalFree(memory);
        return FAILED(hr) ? hr : STG_E_READFAULT;
    }
    *result = memory;
    *size = n;
    return S_OK;
}

// WIC's BMP decoder accepts a file header followed by a packed clipboard DIB.
static HRESULT dib_source(IWICImagingFactory *factory, HGLOBAL handle, IWICBitmapSource **result) {
    const SIZE_T n = GlobalSize(handle);
    if (n < sizeof(BITMAPCOREHEADER) || n > 256ULL * 1024 * 1024) return E_INVALIDARG;
    const auto *data = static_cast<const BYTE *>(GlobalLock(handle));
    if (!data) return E_INVALIDARG;
    struct Unlock { HGLOBAL handle; ~Unlock() { GlobalUnlock(handle); } } unlock{handle};
    DWORD header = 0;
    memcpy(&header, data, sizeof(header));
    if (header > n) return E_INVALIDARG;
    UINT64 offset = header;
    if (header == sizeof(BITMAPCOREHEADER)) {
        BITMAPCOREHEADER h;
        memcpy(&h, data, sizeof(h));
        if (h.bcBitCount <= 8) offset += (1U << h.bcBitCount) * sizeof(RGBTRIPLE);
    } else if (header >= sizeof(BITMAPINFOHEADER)) {
        BITMAPINFOHEADER h;
        memcpy(&h, data, sizeof(h));
        UINT colors = h.biClrUsed;
        if (colors == 0 && h.biBitCount <= 8) colors = 1U << h.biBitCount;
        offset += UINT64(colors) * sizeof(RGBQUAD);
        if (header == sizeof(BITMAPINFOHEADER)) {
            if (h.biCompression == BI_BITFIELDS) offset += 3 * sizeof(DWORD);
            if (h.biCompression == 6 /* BI_ALPHABITFIELDS */) offset += 4 * sizeof(DWORD);
        }
    } else return E_INVALIDARG;
    if (offset >= n) return E_INVALIDARG;

    BITMAPFILEHEADER file = {};
    file.bfType = 0x4d42;
    file.bfSize = static_cast<DWORD>(sizeof(file) + n);
    file.bfOffBits = static_cast<DWORD>(sizeof(file) + offset);
    ComPtr<IStream> stream;
    HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (FAILED(hr)) return hr;
    hr = stream->Write(&file, sizeof(file), nullptr);
    if (FAILED(hr)) return hr;
    hr = stream->Write(data, static_cast<ULONG>(n), nullptr);
    if (FAILED(hr)) return hr;
    LARGE_INTEGER zero = {};
    hr = stream->Seek(zero, STREAM_SEEK_SET, nullptr);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapDecoder> decoder;
    hr = factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapFrameDecode> frame;
    hr = decoder->GetFrame(0, &frame);
    if (FAILED(hr)) return hr;
    return frame.CopyTo(result);
}

// Export a native bitmap as PNG. The caller owns the returned HGLOBAL.
extern "C" HRESULT ghostty_clipboard_bitmap_png(UINT format, HANDLE handle, HGLOBAL *result, size_t *size) {
    OleApartment apartment;
    if (FAILED(apartment.result)) return apartment.result;
    ComPtr<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapSource> bitmap;
    if (format == CF_BITMAP) {
        ComPtr<IWICBitmap> native;
        hr = factory->CreateBitmapFromHBITMAP(static_cast<HBITMAP>(handle), nullptr, WICBitmapIgnoreAlpha, &native);
        if (SUCCEEDED(hr)) hr = native.As(&bitmap);
    } else hr = dib_source(factory.Get(), static_cast<HGLOBAL>(handle), &bitmap);
    if (FAILED(hr)) return hr;
    UINT width, height;
    hr = bitmap->GetSize(&width, &height);
    if (FAILED(hr)) return hr;
    if (!width || !height || static_cast<ULONGLONG>(width) * height > 64ULL * 1024 * 1024) return E_INVALIDARG;
    ComPtr<IStream> stream;
    hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapEncoder> encoder;
    hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (FAILED(hr)) return hr;
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapFrameEncode> frame;
    hr = encoder->CreateNewFrame(&frame, nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Initialize(nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->WriteSource(bitmap.Get(), nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Commit();
    if (FAILED(hr)) return hr;
    hr = encoder->Commit();
    if (FAILED(hr)) return hr;
    STATSTG stat = {};
    hr = stream->Stat(&stat, STATFLAG_NONAME);
    if (FAILED(hr)) return hr;
    HGLOBAL memory;
    hr = GetHGlobalFromStream(stream.Get(), &memory);
    if (FAILED(hr)) return hr;
    // The stream owns memory; duplicate it while the stream is alive.
    *result = static_cast<HGLOBAL>(OleDuplicateData(memory, CF_PRIVATEFIRST, GMEM_MOVEABLE));
    if (!*result) return E_OUTOFMEMORY;
    *size = static_cast<size_t>(stat.cbSize.QuadPart);
    return S_OK;
}

extern "C" int ghostty_clipboard_confirm(HWND owner, const wchar_t *title,
                                         const wchar_t *details, const wchar_t *extra, int remember_kind,
                                         const BYTE *pixels, int width, int height,
                                         BOOL *remember) {
    TASKDIALOGCONFIG config = {};
    config.cbSize = sizeof(config);
    config.hwndParent = owner;
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW | TDF_SIZE_TO_CONTENT;
    config.dwCommonButtons = TDCBF_YES_BUTTON | TDCBF_NO_BUTTON | TDCBF_CANCEL_BUTTON;
    config.pszWindowTitle = L"Ghostty";
    config.pszMainIcon = TD_WARNING_ICON;
    HICON thumbnail = nullptr;
    if (pixels && width > 0 && height > 0 && width <= 64 && height <= 64) {
        const BYTE mask[64 * 8] = {};
        thumbnail = CreateIcon(nullptr, width, height, 1, 32, mask, pixels);
        if (thumbnail) {
            config.dwFlags |= TDF_USE_HICON_MAIN;
            config.hMainIcon = thumbnail;
        }
    }
    config.pszMainInstruction = title;
    config.pszContent = details;
    config.pszExpandedInformation = extra;
    if (extra) config.pszExpandedControlText = L"Hide additional formats";
    if (extra) config.pszCollapsedControlText = L"Show additional formats";
    config.nDefaultButton = IDNO;
    if (remember_kind == 1) config.pszVerificationText = L"Remember an approval for this application in this session";
    if (remember_kind == 2) config.pszVerificationText = L"Remember this decision for this session";
    int button = IDCANCEL;
    HRESULT hr = TaskDialogIndirect(&config, &button, nullptr, remember);
    if (thumbnail) DestroyIcon(thumbnail);
    if (FAILED(hr)) return IDCANCEL;
    return button;
}
