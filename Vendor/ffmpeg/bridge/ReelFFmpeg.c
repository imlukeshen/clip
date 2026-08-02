#include "ReelFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <string.h>

typedef struct ReelVideoPipeline {
    AVFormatContext *input;
    AVFormatContext *output;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    AVStream *input_stream;
    AVStream *output_stream;
    struct SwsContext *scaler;
    AVFrame *decoded_frame;
    AVFrame *encoded_frame;
    AVPacket *packet;
    AVPacket *encoded_packet;
    int stream_index;
    int64_t next_pts;
    int64_t duration;
} ReelVideoPipeline;

typedef struct ReelAudioPipeline {
    AVFormatContext *input;
    AVFormatContext *output;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    AVStream *input_stream;
    AVStream *output_stream;
    AVAudioFifo *fifo;
    SwrContext *resampler;
    AVFrame *decoded_frame;
    AVPacket *packet;
    AVPacket *encoded_packet;
    int stream_index;
    int64_t next_pts;
    int64_t duration;
} ReelAudioPipeline;

static void reel_set_error(char *buffer, size_t size, const char *message, int code) {
    if (buffer == NULL || size == 0) {
        return;
    }
    if (code < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(code, detail, sizeof(detail));
        snprintf(buffer, size, "%s: %s", message, detail);
    } else {
        snprintf(buffer, size, "%s", message);
    }
}

static const char *reel_format_name(enum ReelFFmpegRecipe recipe) {
    switch (recipe) {
        case ReelFFmpegRecipeWebMVP9:
        case ReelFFmpegRecipeWebMAV1:
            return "webm";
        case ReelFFmpegRecipeAnimatedGIF:
            return "gif";
        case ReelFFmpegRecipeMatroska:
            return "matroska";
        case ReelFFmpegRecipeFLAC:
            return "flac";
    }
    return NULL;
}

static const char *reel_video_encoder_name(enum ReelFFmpegRecipe recipe) {
    switch (recipe) {
        case ReelFFmpegRecipeWebMVP9:
        case ReelFFmpegRecipeMatroska:
            return "libvpx-vp9";
        case ReelFFmpegRecipeWebMAV1:
            return "libaom-av1";
        case ReelFFmpegRecipeAnimatedGIF:
            return "gif";
        case ReelFFmpegRecipeFLAC:
            return NULL;
    }
    return NULL;
}

static enum AVPixelFormat reel_pixel_format(
    const AVCodec *encoder,
    enum ReelFFmpegRecipe recipe
) {
    enum AVPixelFormat preferred = AV_PIX_FMT_YUV420P;
    if (recipe == ReelFFmpegRecipeAnimatedGIF) {
        preferred = AV_PIX_FMT_RGB8;
    }
    if (encoder->pix_fmts == NULL) {
        return preferred;
    }
    for (const enum AVPixelFormat *format = encoder->pix_fmts;
         *format != AV_PIX_FMT_NONE;
         format++) {
        if (*format == preferred) {
            return preferred;
        }
    }
    return encoder->pix_fmts[0];
}

static int reel_write_packets(ReelVideoPipeline *pipeline) {
    int result = 0;
    while ((result = avcodec_receive_packet(pipeline->encoder, pipeline->encoded_packet)) >= 0) {
        av_packet_rescale_ts(
            pipeline->encoded_packet,
            pipeline->encoder->time_base,
            pipeline->output_stream->time_base
        );
        pipeline->encoded_packet->stream_index = pipeline->output_stream->index;
        result = av_interleaved_write_frame(pipeline->output, pipeline->encoded_packet);
        av_packet_unref(pipeline->encoded_packet);
        if (result < 0) {
            return result;
        }
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int reel_encode_frame(ReelVideoPipeline *pipeline, AVFrame *frame) {
    int result = avcodec_send_frame(pipeline->encoder, frame);
    if (result < 0) {
        return result;
    }
    return reel_write_packets(pipeline);
}

static int reel_convert_frame(ReelVideoPipeline *pipeline, AVFrame *source) {
    pipeline->scaler = sws_getCachedContext(
        pipeline->scaler,
        source->width,
        source->height,
        source->format,
        pipeline->encoder->width,
        pipeline->encoder->height,
        pipeline->encoder->pix_fmt,
        SWS_BICUBIC,
        NULL,
        NULL,
        NULL
    );
    if (pipeline->scaler == NULL) {
        return AVERROR(ENOMEM);
    }

    int result = av_frame_make_writable(pipeline->encoded_frame);
    if (result < 0) {
        return result;
    }
    sws_scale(
        pipeline->scaler,
        (const uint8_t *const *)source->data,
        source->linesize,
        0,
        source->height,
        pipeline->encoded_frame->data,
        pipeline->encoded_frame->linesize
    );

    int64_t source_pts = source->best_effort_timestamp;
    if (source_pts == AV_NOPTS_VALUE) {
        pipeline->encoded_frame->pts = pipeline->next_pts++;
    } else {
        pipeline->encoded_frame->pts = av_rescale_q(
            source_pts,
            pipeline->input_stream->time_base,
            pipeline->encoder->time_base
        );
        pipeline->next_pts = pipeline->encoded_frame->pts + 1;
    }
    return reel_encode_frame(pipeline, pipeline->encoded_frame);
}

static int reel_decode_packet(ReelVideoPipeline *pipeline, AVPacket *packet) {
    int result = avcodec_send_packet(pipeline->decoder, packet);
    if (result < 0) {
        return result;
    }
    while ((result = avcodec_receive_frame(pipeline->decoder, pipeline->decoded_frame)) >= 0) {
        result = reel_convert_frame(pipeline, pipeline->decoded_frame);
        av_frame_unref(pipeline->decoded_frame);
        if (result < 0) {
            return result;
        }
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static void reel_close_pipeline(ReelVideoPipeline *pipeline) {
    if (pipeline->output != NULL && !(pipeline->output->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&pipeline->output->pb);
    }
    av_packet_free(&pipeline->encoded_packet);
    av_packet_free(&pipeline->packet);
    av_frame_free(&pipeline->encoded_frame);
    av_frame_free(&pipeline->decoded_frame);
    sws_freeContext(pipeline->scaler);
    avcodec_free_context(&pipeline->encoder);
    avcodec_free_context(&pipeline->decoder);
    avformat_free_context(pipeline->output);
    avformat_close_input(&pipeline->input);
}

static int reel_open_video_pipeline(
    ReelVideoPipeline *pipeline,
    const char *input_path,
    const char *output_path,
    enum ReelFFmpegRecipe recipe,
    char *error_buffer,
    size_t error_buffer_size
) {
    int result = avformat_open_input(&pipeline->input, input_path, NULL, NULL);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open input", result);
        return result;
    }
    result = avformat_find_stream_info(pipeline->input, NULL);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not read input streams", result);
        return result;
    }
    pipeline->stream_index = av_find_best_stream(
        pipeline->input,
        AVMEDIA_TYPE_VIDEO,
        -1,
        -1,
        NULL,
        0
    );
    if (pipeline->stream_index < 0) {
        reel_set_error(error_buffer, error_buffer_size, "The input has no video stream", 0);
        return pipeline->stream_index;
    }
    pipeline->input_stream = pipeline->input->streams[pipeline->stream_index];
    pipeline->duration = pipeline->input->duration;

    const AVCodec *decoder = avcodec_find_decoder(pipeline->input_stream->codecpar->codec_id);
    if (decoder == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "No decoder is available", 0);
        return AVERROR_DECODER_NOT_FOUND;
    }
    pipeline->decoder = avcodec_alloc_context3(decoder);
    if (pipeline->decoder == NULL) {
        return AVERROR(ENOMEM);
    }
    result = avcodec_parameters_to_context(pipeline->decoder, pipeline->input_stream->codecpar);
    if (result < 0 || (result = avcodec_open2(pipeline->decoder, decoder, NULL)) < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open decoder", result);
        return result;
    }

    const char *format_name = reel_format_name(recipe);
    result = avformat_alloc_output_context2(&pipeline->output, NULL, format_name, output_path);
    if (result < 0 || pipeline->output == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "Could not create output container", result);
        return result < 0 ? result : AVERROR(EINVAL);
    }

    const char *encoder_name = reel_video_encoder_name(recipe);
    const AVCodec *encoder = encoder_name == NULL ? NULL : avcodec_find_encoder_by_name(encoder_name);
    if (encoder == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "Required LGPL encoder is unavailable", 0);
        return AVERROR_ENCODER_NOT_FOUND;
    }
    pipeline->encoder = avcodec_alloc_context3(encoder);
    pipeline->output_stream = avformat_new_stream(pipeline->output, NULL);
    if (pipeline->encoder == NULL || pipeline->output_stream == NULL) {
        return AVERROR(ENOMEM);
    }

    AVRational frame_rate = av_guess_frame_rate(
        pipeline->input,
        pipeline->input_stream,
        NULL
    );
    if (frame_rate.num <= 0 || frame_rate.den <= 0) {
        frame_rate = (AVRational){30, 1};
    }
    pipeline->encoder->width = pipeline->decoder->width;
    pipeline->encoder->height = pipeline->decoder->height;
    pipeline->encoder->sample_aspect_ratio = pipeline->decoder->sample_aspect_ratio;
    pipeline->encoder->framerate = frame_rate;
    pipeline->encoder->time_base = av_inv_q(frame_rate);
    pipeline->encoder->pix_fmt = reel_pixel_format(encoder, recipe);
    pipeline->encoder->bit_rate = 2 * 1000 * 1000;
    pipeline->encoder->gop_size = 120;
    pipeline->encoder->max_b_frames = 0;
    if (pipeline->output->oformat->flags & AVFMT_GLOBALHEADER) {
        pipeline->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    AVDictionary *options = NULL;
    if (recipe == ReelFFmpegRecipeWebMVP9 || recipe == ReelFFmpegRecipeMatroska) {
        av_dict_set(&options, "deadline", "good", 0);
        av_dict_set(&options, "cpu-used", "4", 0);
        av_dict_set(&options, "crf", "32", 0);
    } else if (recipe == ReelFFmpegRecipeWebMAV1) {
        av_dict_set(&options, "cpu-used", "6", 0);
        av_dict_set(&options, "crf", "34", 0);
    }
    result = avcodec_open2(pipeline->encoder, encoder, &options);
    av_dict_free(&options);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open encoder", result);
        return result;
    }
    pipeline->output_stream->time_base = pipeline->encoder->time_base;
    result = avcodec_parameters_from_context(
        pipeline->output_stream->codecpar,
        pipeline->encoder
    );
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not configure output stream", result);
        return result;
    }

    if (!(pipeline->output->oformat->flags & AVFMT_NOFILE)) {
        result = avio_open(&pipeline->output->pb, output_path, AVIO_FLAG_WRITE);
        if (result < 0) {
            reel_set_error(error_buffer, error_buffer_size, "Could not create output file", result);
            return result;
        }
    }
    result = avformat_write_header(pipeline->output, NULL);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not write output header", result);
        return result;
    }

    pipeline->decoded_frame = av_frame_alloc();
    pipeline->encoded_frame = av_frame_alloc();
    pipeline->packet = av_packet_alloc();
    pipeline->encoded_packet = av_packet_alloc();
    if (pipeline->decoded_frame == NULL || pipeline->encoded_frame == NULL
        || pipeline->packet == NULL || pipeline->encoded_packet == NULL) {
        return AVERROR(ENOMEM);
    }
    pipeline->encoded_frame->format = pipeline->encoder->pix_fmt;
    pipeline->encoded_frame->width = pipeline->encoder->width;
    pipeline->encoded_frame->height = pipeline->encoder->height;
    result = av_frame_get_buffer(pipeline->encoded_frame, 0);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not allocate video frame", result);
    }
    return result;
}

static int reel_transcode_video(
    const char *input_path,
    const char *output_path,
    enum ReelFFmpegRecipe recipe,
    ReelFFmpegProgressCallback callback,
    void *context,
    char *error_buffer,
    size_t error_buffer_size
) {
    ReelVideoPipeline pipeline = {0};
    int result = reel_open_video_pipeline(
        &pipeline,
        input_path,
        output_path,
        recipe,
        error_buffer,
        error_buffer_size
    );
    if (result < 0) {
        reel_close_pipeline(&pipeline);
        return result;
    }
    if (callback != NULL && callback(0.0, context) == 0) {
        reel_close_pipeline(&pipeline);
        return AVERROR_EXIT;
    }

    while ((result = av_read_frame(pipeline.input, pipeline.packet)) >= 0) {
        if (pipeline.packet->stream_index == pipeline.stream_index) {
            result = reel_decode_packet(&pipeline, pipeline.packet);
            if (result < 0) {
                reel_set_error(error_buffer, error_buffer_size, "Video conversion failed", result);
                break;
            }
            if (callback != NULL && pipeline.duration > 0
                && pipeline.packet->pts != AV_NOPTS_VALUE) {
                int64_t timestamp = av_rescale_q(
                    pipeline.packet->pts,
                    pipeline.input_stream->time_base,
                    AV_TIME_BASE_Q
                );
                double progress = av_clipd((double)timestamp / (double)pipeline.duration, 0.0, 0.99);
                if (callback(progress, context) == 0) {
                    result = AVERROR_EXIT;
                    av_packet_unref(pipeline.packet);
                    break;
                }
            }
        }
        av_packet_unref(pipeline.packet);
    }

    if (result == AVERROR_EOF) {
        result = reel_decode_packet(&pipeline, NULL);
    }
    if (result >= 0) {
        result = reel_encode_frame(&pipeline, NULL);
    }
    if (result >= 0) {
        result = av_write_trailer(pipeline.output);
    }
    if (result < 0 && result != AVERROR_EXIT) {
        reel_set_error(error_buffer, error_buffer_size, "Video conversion failed", result);
    }
    if (result >= 0 && callback != NULL) {
        callback(1.0, context);
    }
    reel_close_pipeline(&pipeline);
    return result;
}

static int reel_write_audio_packets(ReelAudioPipeline *pipeline) {
    int result = 0;
    while ((result = avcodec_receive_packet(pipeline->encoder, pipeline->encoded_packet)) >= 0) {
        av_packet_rescale_ts(
            pipeline->encoded_packet,
            pipeline->encoder->time_base,
            pipeline->output_stream->time_base
        );
        pipeline->encoded_packet->stream_index = pipeline->output_stream->index;
        result = av_interleaved_write_frame(pipeline->output, pipeline->encoded_packet);
        av_packet_unref(pipeline->encoded_packet);
        if (result < 0) {
            return result;
        }
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int reel_encode_audio_frame(ReelAudioPipeline *pipeline, AVFrame *frame) {
    int result = avcodec_send_frame(pipeline->encoder, frame);
    if (result < 0) {
        return result;
    }
    return reel_write_audio_packets(pipeline);
}

static int reel_encode_audio_from_fifo(ReelAudioPipeline *pipeline, int sample_count) {
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL) {
        return AVERROR(ENOMEM);
    }
    frame->format = pipeline->encoder->sample_fmt;
    frame->sample_rate = pipeline->encoder->sample_rate;
    frame->nb_samples = sample_count;
    int result = av_channel_layout_copy(&frame->ch_layout, &pipeline->encoder->ch_layout);
    if (result >= 0) {
        result = av_frame_get_buffer(frame, 0);
    }
    if (result >= 0) {
        int read_count = av_audio_fifo_read(
            pipeline->fifo,
            (void **)frame->extended_data,
            sample_count
        );
        result = read_count == sample_count ? 0 : AVERROR(EIO);
    }
    if (result >= 0) {
        frame->pts = pipeline->next_pts;
        pipeline->next_pts += sample_count;
        result = reel_encode_audio_frame(pipeline, frame);
    }
    av_frame_free(&frame);
    return result;
}

static int reel_convert_audio_frame(ReelAudioPipeline *pipeline, AVFrame *source) {
    int output_samples = (int)av_rescale_rnd(
        swr_get_delay(pipeline->resampler, pipeline->decoder->sample_rate)
            + source->nb_samples,
        pipeline->encoder->sample_rate,
        pipeline->decoder->sample_rate,
        AV_ROUND_UP
    );
    AVFrame *converted = av_frame_alloc();
    if (converted == NULL) {
        return AVERROR(ENOMEM);
    }
    converted->format = pipeline->encoder->sample_fmt;
    converted->sample_rate = pipeline->encoder->sample_rate;
    converted->nb_samples = output_samples;
    int result = av_channel_layout_copy(
        &converted->ch_layout,
        &pipeline->encoder->ch_layout
    );
    if (result >= 0) {
        result = av_frame_get_buffer(converted, 0);
    }
    if (result >= 0) {
        result = swr_convert(
            pipeline->resampler,
            converted->data,
            output_samples,
            (const uint8_t **)source->extended_data,
            source->nb_samples
        );
    }
    if (result >= 0) {
        converted->nb_samples = result;
        int required_size = av_audio_fifo_size(pipeline->fifo) + result;
        result = av_audio_fifo_realloc(pipeline->fifo, required_size);
        if (result >= 0) {
            int written = av_audio_fifo_write(
                pipeline->fifo,
                (void **)converted->extended_data,
                converted->nb_samples
            );
            result = written == converted->nb_samples ? 0 : AVERROR(EIO);
        }
    }
    int frame_size = pipeline->encoder->frame_size > 0
        ? pipeline->encoder->frame_size : av_audio_fifo_size(pipeline->fifo);
    while (result >= 0 && frame_size > 0
        && av_audio_fifo_size(pipeline->fifo) >= frame_size) {
        result = reel_encode_audio_from_fifo(pipeline, frame_size);
    }
    av_frame_free(&converted);
    return result;
}

static int reel_decode_audio_packet(ReelAudioPipeline *pipeline, AVPacket *packet) {
    int result = avcodec_send_packet(pipeline->decoder, packet);
    if (result < 0) {
        return result;
    }
    while ((result = avcodec_receive_frame(pipeline->decoder, pipeline->decoded_frame)) >= 0) {
        result = reel_convert_audio_frame(pipeline, pipeline->decoded_frame);
        av_frame_unref(pipeline->decoded_frame);
        if (result < 0) {
            return result;
        }
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static void reel_close_audio_pipeline(ReelAudioPipeline *pipeline) {
    if (pipeline->output != NULL && !(pipeline->output->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&pipeline->output->pb);
    }
    av_packet_free(&pipeline->encoded_packet);
    av_packet_free(&pipeline->packet);
    av_frame_free(&pipeline->decoded_frame);
    av_audio_fifo_free(pipeline->fifo);
    swr_free(&pipeline->resampler);
    avcodec_free_context(&pipeline->encoder);
    avcodec_free_context(&pipeline->decoder);
    avformat_free_context(pipeline->output);
    avformat_close_input(&pipeline->input);
}

static int reel_open_audio_pipeline(
    ReelAudioPipeline *pipeline,
    const char *input_path,
    const char *output_path,
    char *error_buffer,
    size_t error_buffer_size
) {
    int result = avformat_open_input(&pipeline->input, input_path, NULL, NULL);
    if (result < 0 || (result = avformat_find_stream_info(pipeline->input, NULL)) < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open audio input", result);
        return result;
    }
    pipeline->stream_index = av_find_best_stream(
        pipeline->input,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    );
    if (pipeline->stream_index < 0) {
        reel_set_error(error_buffer, error_buffer_size, "The input has no audio stream", 0);
        return pipeline->stream_index;
    }
    pipeline->input_stream = pipeline->input->streams[pipeline->stream_index];
    pipeline->duration = pipeline->input->duration;

    const AVCodec *decoder = avcodec_find_decoder(pipeline->input_stream->codecpar->codec_id);
    if (decoder == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "No audio decoder is available", 0);
        return AVERROR_DECODER_NOT_FOUND;
    }
    pipeline->decoder = avcodec_alloc_context3(decoder);
    if (pipeline->decoder == NULL) {
        return AVERROR(ENOMEM);
    }
    result = avcodec_parameters_to_context(pipeline->decoder, pipeline->input_stream->codecpar);
    if (result < 0 || (result = avcodec_open2(pipeline->decoder, decoder, NULL)) < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open audio decoder", result);
        return result;
    }

    result = avformat_alloc_output_context2(&pipeline->output, NULL, "flac", output_path);
    if (result < 0 || pipeline->output == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "Could not create FLAC output", result);
        return result < 0 ? result : AVERROR(EINVAL);
    }
    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_FLAC);
    pipeline->encoder = encoder == NULL ? NULL : avcodec_alloc_context3(encoder);
    pipeline->output_stream = avformat_new_stream(pipeline->output, NULL);
    if (pipeline->encoder == NULL || pipeline->output_stream == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "FLAC encoder is unavailable", 0);
        return encoder == NULL ? AVERROR_ENCODER_NOT_FOUND : AVERROR(ENOMEM);
    }
    pipeline->encoder->sample_rate = pipeline->decoder->sample_rate > 0
        ? pipeline->decoder->sample_rate : 48000;
    pipeline->encoder->sample_fmt = encoder->sample_fmts != NULL
        ? encoder->sample_fmts[0] : AV_SAMPLE_FMT_S16;
    if (pipeline->decoder->ch_layout.nb_channels > 0) {
        result = av_channel_layout_copy(
            &pipeline->encoder->ch_layout,
            &pipeline->decoder->ch_layout
        );
    } else {
        av_channel_layout_default(&pipeline->encoder->ch_layout, 2);
        result = 0;
    }
    if (result < 0) {
        return result;
    }
    pipeline->encoder->time_base = (AVRational){1, pipeline->encoder->sample_rate};
    if (pipeline->output->oformat->flags & AVFMT_GLOBALHEADER) {
        pipeline->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    result = avcodec_open2(pipeline->encoder, encoder, NULL);
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not open FLAC encoder", result);
        return result;
    }
    pipeline->output_stream->time_base = pipeline->encoder->time_base;
    result = avcodec_parameters_from_context(
        pipeline->output_stream->codecpar,
        pipeline->encoder
    );
    if (result < 0) {
        return result;
    }
    result = swr_alloc_set_opts2(
        &pipeline->resampler,
        &pipeline->encoder->ch_layout,
        pipeline->encoder->sample_fmt,
        pipeline->encoder->sample_rate,
        &pipeline->decoder->ch_layout,
        pipeline->decoder->sample_fmt,
        pipeline->decoder->sample_rate,
        0,
        NULL
    );
    if (result < 0 || (result = swr_init(pipeline->resampler)) < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not configure audio conversion", result);
        return result;
    }
    pipeline->fifo = av_audio_fifo_alloc(
        pipeline->encoder->sample_fmt,
        pipeline->encoder->ch_layout.nb_channels,
        pipeline->encoder->frame_size > 0 ? pipeline->encoder->frame_size : 1024
    );
    if (pipeline->fifo == NULL) {
        return AVERROR(ENOMEM);
    }
    if (!(pipeline->output->oformat->flags & AVFMT_NOFILE)) {
        result = avio_open(&pipeline->output->pb, output_path, AVIO_FLAG_WRITE);
    }
    if (result >= 0) {
        result = avformat_write_header(pipeline->output, NULL);
    }
    if (result < 0) {
        reel_set_error(error_buffer, error_buffer_size, "Could not write FLAC output", result);
        return result;
    }
    pipeline->decoded_frame = av_frame_alloc();
    pipeline->packet = av_packet_alloc();
    pipeline->encoded_packet = av_packet_alloc();
    if (pipeline->decoded_frame == NULL || pipeline->packet == NULL
        || pipeline->encoded_packet == NULL) {
        return AVERROR(ENOMEM);
    }
    return 0;
}

static int reel_transcode_audio(
    const char *input_path,
    const char *output_path,
    ReelFFmpegProgressCallback callback,
    void *context,
    char *error_buffer,
    size_t error_buffer_size
) {
    ReelAudioPipeline pipeline = {0};
    int result = reel_open_audio_pipeline(
        &pipeline,
        input_path,
        output_path,
        error_buffer,
        error_buffer_size
    );
    if (result < 0) {
        reel_close_audio_pipeline(&pipeline);
        return result;
    }
    if (callback != NULL && callback(0.0, context) == 0) {
        reel_close_audio_pipeline(&pipeline);
        return AVERROR_EXIT;
    }
    while ((result = av_read_frame(pipeline.input, pipeline.packet)) >= 0) {
        if (pipeline.packet->stream_index == pipeline.stream_index) {
            result = reel_decode_audio_packet(&pipeline, pipeline.packet);
            if (result < 0) {
                break;
            }
            if (callback != NULL && pipeline.duration > 0
                && pipeline.packet->pts != AV_NOPTS_VALUE) {
                int64_t timestamp = av_rescale_q(
                    pipeline.packet->pts,
                    pipeline.input_stream->time_base,
                    AV_TIME_BASE_Q
                );
                if (callback(
                        av_clipd((double)timestamp / (double)pipeline.duration, 0.0, 0.99),
                        context
                    ) == 0) {
                    result = AVERROR_EXIT;
                    av_packet_unref(pipeline.packet);
                    break;
                }
            }
        }
        av_packet_unref(pipeline.packet);
    }
    if (result == AVERROR_EOF) {
        result = reel_decode_audio_packet(&pipeline, NULL);
    }
    if (result >= 0 && av_audio_fifo_size(pipeline.fifo) > 0) {
        result = reel_encode_audio_from_fifo(
            &pipeline,
            av_audio_fifo_size(pipeline.fifo)
        );
    }
    if (result >= 0) {
        result = reel_encode_audio_frame(&pipeline, NULL);
    }
    if (result >= 0) {
        result = av_write_trailer(pipeline.output);
    }
    if (result < 0 && result != AVERROR_EXIT) {
        reel_set_error(error_buffer, error_buffer_size, "Audio conversion failed", result);
    }
    if (result >= 0 && callback != NULL) {
        callback(1.0, context);
    }
    reel_close_audio_pipeline(&pipeline);
    return result;
}

int reel_ffmpeg_transcode(
    const char *input_path,
    const char *output_path,
    enum ReelFFmpegRecipe recipe,
    ReelFFmpegProgressCallback progress_callback,
    void *progress_context,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (input_path == NULL || output_path == NULL) {
        reel_set_error(error_buffer, error_buffer_size, "Input and output paths are required", 0);
        return AVERROR(EINVAL);
    }
    if (recipe == ReelFFmpegRecipeFLAC) {
        return reel_transcode_audio(
            input_path,
            output_path,
            progress_callback,
            progress_context,
            error_buffer,
            error_buffer_size
        );
    }
    return reel_transcode_video(
        input_path,
        output_path,
        recipe,
        progress_callback,
        progress_context,
        error_buffer,
        error_buffer_size
    );
}

const char *reel_ffmpeg_configuration(void) {
    return avcodec_configuration();
}
