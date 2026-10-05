// SPDX-License-Identifier: MIT
// WASAPI shared-mode playback. No JavaSound/DirectSound mixer clock approximation.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <atomic>
#include <algorithm>
#include <cstring>
#include <cmath>
#include "render_timeline.h"
#define API extern "C" __declspec(dllexport)
static thread_local HRESULT lastError = S_OK;
struct Render {
    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioRenderClient* writer = nullptr;
    IAudioClock* clock = nullptr;
    HANDLE ready = nullptr;
    UINT32 capacity = 0;
    UINT64 frequency = 0;
    UINT64 initialSilence = 0;
    UINT64 submitted = 0;
    UINT64 skippedSilence = 0;
    double latency = 0;
    std::atomic<bool> stopped{false};
    bool com = false;
    ~Render() {
        if(client)client->Stop();
        if(clock)clock->Release();
        if(writer)writer->Release();
        if(client)client->Release();
        if(device)device->Release();
        if(enumerator)enumerator->Release();
        if(ready)CloseHandle(ready);
        if(com)CoUninitialize();
    }
};
API int ms_render_last_error(){return static_cast<int>(lastError);}
API void* ms_render_open() {
    auto* r = new Render;
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if(SUCCEEDED(result))r->com=true;
    else if(result!=RPC_E_CHANGED_MODE){lastError=result;delete r;return nullptr;}
    WAVEFORMATEX format{};
    format.wFormatTag=WAVE_FORMAT_IEEE_FLOAT;format.nChannels=2;format.nSamplesPerSec=48000;
    format.wBitsPerSample=32;format.nBlockAlign=8;format.nAvgBytesPerSec=384000;
    REFERENCE_TIME streamLatency=0;
    BYTE* initial = nullptr;
#define CHECK(call) do { result=(call);if(FAILED(result)){lastError=result;delete r;return nullptr;} } while(0)
    CHECK(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,__uuidof(IMMDeviceEnumerator),reinterpret_cast<void**>(&r->enumerator)));
    CHECK(r->enumerator->GetDefaultAudioEndpoint(eRender,eConsole,&r->device));
    CHECK(r->device->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(&r->client)));
    // The engine converts fixed 48 kHz float stereo to the selected hardware mix format.
    CHECK(r->client->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_EVENTCALLBACK|AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM|AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,200000,0,&format,nullptr));
    r->ready=CreateEvent(nullptr,FALSE,FALSE,nullptr);
    if(!r->ready){lastError=HRESULT_FROM_WIN32(GetLastError());delete r;return nullptr;}
    CHECK(r->client->SetEventHandle(r->ready));
    CHECK(r->client->GetBufferSize(&r->capacity));
    CHECK(r->client->GetService(__uuidof(IAudioRenderClient),reinterpret_cast<void**>(&r->writer)));
    CHECK(r->client->GetService(__uuidof(IAudioClock),reinterpret_cast<void**>(&r->clock)));
    CHECK(r->clock->GetFrequency(&r->frequency));
    CHECK(r->client->GetStreamLatency(&streamLatency));
    if(!r->frequency||!r->capacity){lastError=E_FAIL;delete r;return nullptr;}
    r->initialSilence=r->capacity;
    r->latency=streamLatency/10000000.0+r->capacity/48000.0;
    CHECK(r->writer->GetBuffer(r->capacity,&initial));
    CHECK(r->writer->ReleaseBuffer(r->capacity,AUDCLNT_BUFFERFLAGS_SILENT));
    CHECK(r->client->Start());
#undef CHECK
    lastError=S_OK;return r;
}
API double ms_render_latency(void* context){return static_cast<Render*>(context)->latency;}
// Results: submitted-stream frame at hardware position, age of QPC sample (seconds),
// native call midpoint QPC correction. JVM maps age to its own nanoTime epoch.
API int ms_render_position(void* context, double* out) {
    auto* r=static_cast<Render*>(context);UINT64 position=0,qpc=0;LARGE_INTEGER before{},after{},frequency{};
    QueryPerformanceFrequency(&frequency);QueryPerformanceCounter(&before);
    HRESULT result=r->clock->GetPosition(&position,&qpc);
    QueryPerformanceCounter(&after);
    if(result!=S_OK||frequency.QuadPart<=0){lastError=result;return 0;}
    const double midpoint=(before.QuadPart/2.0+after.QuadPart/2.0)/frequency.QuadPart;
    out[0]=ms_stream_frame(position,r->frequency,r->initialSilence+r->skippedSilence);
    out[1]=qpc/10000000.0-midpoint;
    return std::isfinite(out[0])&&std::isfinite(out[1])?1:0;
}
API int ms_render_write(void* context,const float* samples,int frames) {
    auto* r=static_cast<Render*>(context);
    if(!samples||frames<=0||frames>4800)return 0;
    int copied=0;
    while(copied<frames&&!r->stopped.load()) {
        UINT32 padding=0;HRESULT result=r->client->GetCurrentPadding(&padding);
        if(FAILED(result)){lastError=result;return 0;}
        const UINT32 freeFrames=r->capacity-std::min(padding,r->capacity);
        if(!freeFrames){if(WaitForSingleObject(r->ready,100)==WAIT_FAILED){lastError=HRESULT_FROM_WIN32(GetLastError());return 0;}continue;}
        // Underflow can advance the endpoint clock through silence not written by the JVM.
        // Keep its submitted-frame coordinate consistent after a CPU stall.
        if(padding==0){
            UINT64 raw=0,qpc=0;
            if(r->clock->GetPosition(&raw,&qpc)==S_OK){
                const auto played=static_cast<UINT64>(raw/static_cast<double>(r->frequency)*48000.0);
                const auto accounted=r->initialSilence+r->submitted+r->skippedSilence;
                if(played>accounted)r->skippedSilence+=played-accounted;
            }
        }
        const UINT32 count=std::min(freeFrames,static_cast<UINT32>(frames-copied));
        BYTE* buffer=nullptr;result=r->writer->GetBuffer(count,&buffer);
        if(FAILED(result)){lastError=result;return 0;}
        std::memcpy(buffer,samples+copied*2,count*8);
        result=r->writer->ReleaseBuffer(count,0);
        if(FAILED(result)){lastError=result;return 0;}
        copied+=count;r->submitted+=count;
    }
    return copied;
}
// Stop is cross-thread safe; dispose must run on the owning audio/COM thread after write exits.
API void ms_render_stop(void* context){auto* r=static_cast<Render*>(context);r->stopped.store(true);SetEvent(r->ready);}
API void ms_render_dispose(void* context){delete static_cast<Render*>(context);}
