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
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
struct Capture {
    ma_device device{};
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
API void* ms_capture_open() {
    auto* c = new Capture;
    auto config = ma_device_config_init(ma_device_type_loopback);
    config.capture.format = ma_format_f32; config.capture.channels = 2; config.sampleRate = 48000;
    config.dataCallback = callback; config.pUserData = c;
    if(ma_device_init(nullptr,&config,&c->device)!=MA_SUCCESS){delete c;return nullptr;}
    if(ma_device_start(&c->device)!=MA_SUCCESS){ma_device_uninit(&c->device);delete c;return nullptr;}
    return c;
}
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
    auto* c=static_cast<Capture*>(context);ma_device_uninit(&c->device);delete c;
}
