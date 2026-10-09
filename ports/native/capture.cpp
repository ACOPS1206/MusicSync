// SPDX-License-Identifier: MIT
// Windows WASAPI output monitor. No local replay of this captured source (prevents feedback).
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#include "miniaudio.h"
#include <mutex>
#include <condition_variable>
#include <deque>
#include <algorithm>
#include <string>
#include <cwchar>
#include <cstring>
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
struct Capture {
    ma_device device{};
    ma_context* context = nullptr;
    std::mutex lock;
    std::condition_variable available;
    std::deque<float> samples;
    bool stopped = false;
};
static void callback(ma_device* device, void*, const void* input, ma_uint32 frames) {
    auto* c = static_cast<Capture*>(device->pUserData);
    const auto* pcm = static_cast<const float*>(input);
    if (!pcm) return;
    std::lock_guard<std::mutex> guard(c->lock);
    c->samples.insert(c->samples.end(), pcm, pcm+frames*2);
    while(c->samples.size()>48000*2) c->samples.pop_front();
    c->available.notify_one();
}
static void* capture_open(const ma_device_id* id, ma_context* context = nullptr) {
    auto* c = new Capture;
    auto config = ma_device_config_init(ma_device_type_loopback);
    config.capture.pDeviceID = id;
    config.capture.format = ma_format_f32; config.capture.channels = 2; config.sampleRate = 48000;
    config.dataCallback = callback; config.pUserData = c;
    if(ma_device_init(context,&config,&c->device)!=MA_SUCCESS){delete c;return nullptr;}
    if(ma_device_start(&c->device)!=MA_SUCCESS){ma_device_uninit(&c->device);delete c;return nullptr;}
    return c;
}
API void* ms_capture_open() { return capture_open(nullptr); }
#ifdef _WIN32
static std::string utf8(const wchar_t* value) {
    if (!value) return {};
    int length=WideCharToMultiByte(CP_UTF8,0,value,-1,nullptr,0,nullptr,nullptr);
    if (length<=1) return {};
    std::string out(length,'\0'); WideCharToMultiByte(CP_UTF8,0,value,-1,out.data(),length,nullptr,nullptr);
    out.pop_back(); return out;
}
static bool select_device(ma_context* context,const wchar_t* name,ma_device_id& id) {
    ma_device_info* outputs=nullptr;ma_uint32 count=0;
    if(ma_context_get_devices(context,&outputs,&count,nullptr,nullptr)!=MA_SUCCESS)return false;
    const auto wanted=utf8(name);int matches=0;
    for(ma_uint32 i=0;i<count;++i)if(wanted.empty()?outputs[i].isDefault:wanted==outputs[i].name){id=outputs[i].id;++matches;}
    return matches==1;
}
// Shared with the renderer: exact friendly names must select one unambiguous endpoint.
API int ms_lookup_render_device(const wchar_t* name,wchar_t* id,int capacity) {
    ma_context context{};ma_backend backend=ma_backend_wasapi;
    if(ma_context_init(&backend,1,nullptr,&context)!=MA_SUCCESS)return 0;
    ma_device_id found{};const bool ok=select_device(&context,name,found);
    if(ok&&capacity>static_cast<int>(std::wcslen(found.wasapi))){std::wcscpy(id,found.wasapi);ma_context_uninit(&context);return 1;}
    ma_context_uninit(&context);return 0;
}
API void* ms_capture_open_device(const wchar_t* captureName,const wchar_t* outputName) {
    // Keep this explicit: capturing the same endpoint we replay into produces feedback.
    if(!captureName||!*captureName)return nullptr;
    auto* context=new ma_context{};ma_backend backend=ma_backend_wasapi;
    if(ma_context_init(&backend,1,nullptr,context)!=MA_SUCCESS){delete context;return nullptr;}
    ma_device_id capture{},output{};
    if(!select_device(context,captureName,capture)||!select_device(context,outputName,output)||std::wcscmp(capture.wasapi,output.wasapi)==0){ma_context_uninit(context);delete context;return nullptr;}
    auto* c=static_cast<Capture*>(capture_open(&capture,context));
    if(!c){ma_context_uninit(context);delete context;return nullptr;}
    // The initialized context cannot be copied: retain its original address until disposal.
    c->context=context;return c;
}
#endif
API int ms_capture_read(void* context, float* pcm, int frames) {
    auto* c = static_cast<Capture*>(context);
    std::unique_lock<std::mutex> guard(c->lock);
    c->available.wait(guard,[&]{return c->stopped || c->samples.size()>=static_cast<size_t>(frames*2);});
    if(c->stopped)return 0;
    for(int i=0;i<frames*2;++i){pcm[i]=c->samples.front();c->samples.pop_front();}
    return frames;
}
// Caller joins its read thread before disposing. Stop first to release a blocked read.
API void ms_capture_stop(void* context) {
    auto* c = static_cast<Capture*>(context);
    ma_device_stop(&c->device);
    std::lock_guard<std::mutex> guard(c->lock); c->stopped=true;c->available.notify_all();
}
API void ms_capture_dispose(void* context) {
    auto* c=static_cast<Capture*>(context);ma_device_uninit(&c->device);
    if(c->context){ma_context_uninit(c->context);delete c->context;}delete c;
}
