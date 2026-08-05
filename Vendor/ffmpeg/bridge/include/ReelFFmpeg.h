#ifndef REEL_FFMPEG_H
#define REEL_FFMPEG_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*ReelFFmpegProgressCallback)(double progress, void *context);

enum ReelFFmpegRecipe {
    ReelFFmpegRecipeWebMVP9 = 0,
    ReelFFmpegRecipeWebMAV1 = 1,
    ReelFFmpegRecipeAnimatedGIF = 2,
    ReelFFmpegRecipeMatroska = 3,
    ReelFFmpegRecipeFLAC = 4,
    ReelFFmpegRecipeWebP = 5,
};

/// Returns zero on success and a negative value on failure.
int reel_ffmpeg_transcode(
    const char *input_path,
    const char *output_path,
    enum ReelFFmpegRecipe recipe,
    ReelFFmpegProgressCallback progress_callback,
    void *progress_context,
    char *error_buffer,
    size_t error_buffer_size
);

const char *reel_ffmpeg_configuration(void);

#ifdef __cplusplus
}
#endif

#endif
