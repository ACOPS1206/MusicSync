// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
// IAudioClock position units are defined by GetFrequency, not necessarily sample frames.
// Prefilled startup silence is outside the JVM's submitted-frame index.
inline double ms_stream_frame(std::uint64_t position,std::uint64_t frequency,std::uint64_t prefill) {
    return static_cast<double>(position)/static_cast<double>(frequency)*48000.0-static_cast<double>(prefill);
}
