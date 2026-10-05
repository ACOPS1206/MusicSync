// SPDX-License-Identifier: MIT
#include "render_timeline.h"
#include <cmath>
#include <cstdlib>
int main(){
    // Includes non-frame clock frequencies and negative startup positions.
    if(std::abs(ms_stream_frame(0,10000000,960)+960)>1e-9)return EXIT_FAILURE;
    if(std::abs(ms_stream_frame(200000,10000000,960))>1e-9)return EXIT_FAILURE;
    if(std::abs(ms_stream_frame(10200000,10000000,960)-48000)>1e-9)return EXIT_FAILURE;
    if(std::abs(ms_stream_frame(3840,384000,0)-480)>1e-9)return EXIT_FAILURE;
    return EXIT_SUCCESS;
}
