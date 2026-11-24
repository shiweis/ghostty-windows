// Independent native clipboard producer for the private-station integration test.
#include <windows.h>
#include <shlobj.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;

extern "C" HRESULT ghostty_test_clipboard_stream(UINT id, const void *data, ULONG size) {
    HRESULT hr = OleInitialize(nullptr);
    if (FAILED(hr)) return hr;
    ComPtr<IDataObject> object;
    hr = SHCreateDataObject(nullptr, 0, nullptr, nullptr, IID_PPV_ARGS(&object));
    ComPtr<IStream> stream;
    if (SUCCEEDED(hr)) hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (SUCCEEDED(hr)) hr = stream->Write(data, size, nullptr);
    if (SUCCEEDED(hr)) {
        FORMATETC type = {static_cast<CLIPFORMAT>(id), nullptr, DVASPECT_CONTENT, -1, TYMED_ISTREAM};
        STGMEDIUM medium = {};
        medium.tymed = TYMED_ISTREAM;
        medium.pstm = stream.Get();
        hr = object->SetData(&type, &medium, TRUE);
        if (SUCCEEDED(hr)) stream.Detach();
    }
    if (SUCCEEDED(hr)) hr = OleSetClipboard(object.Get());
    if (FAILED(hr)) OleUninitialize();
    return hr;
}

extern "C" void ghostty_test_clipboard_stream_close() {
    OleSetClipboard(nullptr);
    OleUninitialize();
}
