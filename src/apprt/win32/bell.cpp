// MCI's digital-video device uses the system codecs for local audio files
// and supports per-device volume, including for PCM WAV files.
#include <windows.h>
#include <mmsystem.h>
#include <digitalv.h>
#include <wchar.h>

extern "C" DWORD ghostty_bell_open(const wchar_t *path, const void *owner, UINT *device) {
    // Without an alias MCI uses the filename as the device name. Two
    // panes using the same sound must be able to play at different volumes.
    wchar_t alias[40];
    swprintf(alias, 40, L"GhosttyBell%p", owner);
    MCI_OPEN_PARMSW args{};
    args.lpstrDeviceType = L"mpegvideo";
    args.lpstrElementName = path;
    args.lpstrAlias = alias;
    DWORD err = mciSendCommandW(0, MCI_OPEN, MCI_OPEN_TYPE | MCI_OPEN_ELEMENT | MCI_OPEN_ALIAS,
                                reinterpret_cast<DWORD_PTR>(&args));
    if (!err) *device = args.wDeviceID;
    return err;
}

extern "C" DWORD ghostty_bell_play(UINT device, DWORD volume) {
    MCI_DGV_SETAUDIO_PARMSW audio{};
    audio.dwItem = MCI_DGV_SETAUDIO_VOLUME;
    audio.dwValue = volume;
    DWORD err = mciSendCommandW(device, MCI_SETAUDIO, MCI_DGV_SETAUDIO_ITEM | MCI_DGV_SETAUDIO_VALUE,
                                reinterpret_cast<DWORD_PTR>(&audio));
    if (err) return err;
    MCI_PLAY_PARMS play{};
    return mciSendCommandW(device, MCI_PLAY, MCI_FROM, reinterpret_cast<DWORD_PTR>(&play));
}

extern "C" void ghostty_bell_close(UINT device) {
    mciSendCommandW(device, MCI_CLOSE, MCI_WAIT, 0);
}
