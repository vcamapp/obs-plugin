/*
 VCam OBS Plugin
 Copyright (C) 2023 Tatsuya Tanaka

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License along
 with this program. If not, see <https://www.gnu.org/licenses/>
 */

#include <obs-module.h>
#include <plugin-support.h>

#include "vcamcamera.hpp"

#define AV_FOURCC_STR(code)                                                             \
    (char[5])                                                                           \
    {                                                                                   \
        static_cast<char>((code >> 24) & 0xFF), static_cast<char>((code >> 16) & 0xFF), \
            static_cast<char>((code >> 8) & 0xFF), static_cast<char>(code & 0xFF), 0    \
    }

static bool init_device_input(vcam_data *vcam, AVCaptureDevice *dev)
{
    NSError *error = nil;
    AVCaptureDeviceInput *device_input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&error];
    if (!device_input) {
        obs_log(LOG_ERROR, "Error while initializing device input: %s", error.localizedFailureReason.UTF8String);
        return false;
    }

    [vcam->session addInput:device_input];

    vcam->output.videoSettings =
    @{(__bridge NSString *) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};

    vcam->device_input = device_input;

    return true;
}

static void start_capture(vcam_data *vcam)
{
    if (vcam->session && !vcam->session.running)
        [vcam->session startRunning];
}

static void clear_capture(vcam_data *vcam)
{
    if (vcam->session && vcam->session.running)
        [vcam->session stopRunning];

    obs_source_output_video(vcam->source, nullptr);
}

static void capture_device(vcam_data *vcam, AVCaptureDevice *dev, obs_data_t *settings)
{
    const char *name = dev.localizedName.UTF8String;
    obs_data_set_string(settings, "device_name", name);
    obs_data_set_string(settings, "device", dev.uniqueID.UTF8String);
    obs_log(LOG_INFO, "Selected device '%s'", name);

    vcam->session.sessionPreset = AVCaptureSessionPresetHigh;

    if (!init_device_input(vcam, dev))
        return;

    vcam->device = dev;
    start_capture(vcam);
    return;
}

static inline void handle_connect_capture(vcam_data *vcam, AVCaptureDevice *dev, obs_data_t *settings)
{
    if (![dev.uniqueID isEqualTo:vcam->uid])
        return;

    if (vcam->device) {
        obs_log(LOG_ERROR, "Received connect for in-use device '%s'", vcam->uid.UTF8String);
        return;
    }

    obs_log(LOG_INFO,
            "Device with unique ID '%s' connected, "
            "resuming capture",
            dev.uniqueID.UTF8String);

    capture_device(vcam, dev, settings);
}

static inline void handle_connect(vcam_data *vcam, AVCaptureDevice *dev, obs_data_t *settings)
{
    if (!dev)
        return;

    handle_connect_capture(vcam, dev, settings);
    obs_source_update_properties(vcam->source);
}

static void remove_device(vcam_data *vcam)
{
    clear_capture(vcam);

    [vcam->session removeInput:vcam->device_input];

    vcam->device_input = nullptr;
    vcam->device = nullptr;
}

static inline void handle_disconnect_capture(vcam_data *vcam, AVCaptureDevice *dev)
{
    if (![dev.uniqueID isEqualTo:vcam->uid])
        return;

    if (!vcam->device) {
        obs_log(LOG_INFO, "Received disconnect for inactive device '%s'", vcam->uid.UTF8String);
        return;
    }

    obs_log(LOG_WARNING, "Device with unique ID '%s' disconnected", dev.uniqueID.UTF8String);

    remove_device(vcam);
}

static inline void handle_disconnect(vcam_data *vcam, AVCaptureDevice *dev)
{
    if (!dev)
        return;

    handle_disconnect_capture(vcam, dev);
    obs_source_update_properties(vcam->source);
}

static bool init_session(vcam_data *vcam)
{
    auto session = [[AVCaptureSession alloc] init];
    if (!session) {
        obs_log(LOG_ERROR, "Could not create AVCaptureSession");
        return false;
    }

    auto delegate = [[VCamDelegate alloc] init];
    if (!delegate) {
        obs_log(LOG_ERROR, "Could not create VCamDelegate");
        return false;
    }

    delegate->vcam = vcam;

    auto output = [[AVCaptureVideoDataOutput alloc] init];
    if (!output) {
        obs_log(LOG_ERROR, "Could not create AVCaptureVideoDataOutput");
        return false;
    }

    auto queue = dispatch_queue_create(NULL, NULL);
    if (!queue) {
        obs_log(LOG_ERROR, "Could not create dispatch queue");
        return false;
    }

    vcam->session = session;
    vcam->delegate = delegate;
    vcam->output = output;
    vcam->queue = queue;

    [vcam->session addOutput:vcam->output];
    [vcam->output setSampleBufferDelegate:vcam->delegate queue:vcam->queue];

    return true;
}

bool vcam_init(vcam_data *vcam, obs_data_t *settings)
{
    if (!init_session(vcam))
        return false;

    vcam->uid = @(obs_data_get_string(settings, "device"));

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    vcam->disconnect_observer.reset([nc addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
        handle_disconnect(vcam, note.object);
    }]);

    vcam->connect_observer.reset([nc addObserverForName:AVCaptureDeviceWasConnectedNotification object:nil
                                                  queue:[NSOperationQueue mainQueue]
                                             usingBlock:^(NSNotification *note) {
        handle_connect(vcam, note.object, settings);
    }]);

    AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:vcam->uid];

    if (!dev) {
        if (vcam->uid.length < 1)
            obs_log(LOG_INFO, "No device selected");
        else
            obs_log(LOG_WARNING,
                    "Could not initialize device "
                    "with unique ID '%s'",
                    vcam->uid.UTF8String);
        return true;
    }

    capture_device(vcam, dev, settings);

    return true;
}

static inline video_colorspace get_colorspace(CMFormatDescriptionRef desc)
{
    CFPropertyListRef matrix = CMFormatDescriptionGetExtension(desc, kCMFormatDescriptionExtension_YCbCrMatrix);

    if (!matrix)
        return VIDEO_CS_DEFAULT;

    if (CFStringCompare(static_cast<CFStringRef>(matrix), kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) ==
        kCFCompareEqualTo)
        return VIDEO_CS_601;

    return VIDEO_CS_709;
}

static inline bool update_colorspace(vcam_data *vcam, obs_source_frame *frame, CMFormatDescriptionRef desc,
                                     bool full_range, video_info &vi)
{
    video_colorspace colorspace = get_colorspace(desc);
    video_range_type range = full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;

    bool cs_matches = colorspace == vi.colorspace;
    bool vr_matches = range == vi.video_range;

    if (cs_matches && vr_matches) {
        if (!vi.video_params_valid)
            vcam->video_info.video_params_valid = vi.video_params_valid = true;
        return true;
    }

    frame->full_range = full_range;

    if (!video_format_get_parameters_for_format(colorspace, range, frame->format, frame->color_matrix,
                                                frame->color_range_min, frame->color_range_max)) {
        obs_log(LOG_ERROR,
                "Failed to get colorspace parameters for "
                "colorspace %u range %u",
                colorspace, range);

        if (vi.video_params_valid)
            vcam->video_info.video_params_valid = vi.video_params_valid = false;

        return false;
    }

    vcam->video_info.colorspace = colorspace;
    vcam->video_info.video_range = range;
    vcam->video_info.video_params_valid = vi.video_params_valid = true;

    return true;
}

static inline video_format format_from_subtype(FourCharCode subtype)
{
    switch (subtype) {
        case kCVPixelFormatType_422YpCbCr8:
            return VIDEO_FORMAT_UYVY;
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            return VIDEO_FORMAT_YUY2;
        case kCVPixelFormatType_32BGRA:
            return VIDEO_FORMAT_BGRA;
        default:
            return VIDEO_FORMAT_NONE;
    }
}

static inline bool is_fullrange_yuv(FourCharCode pixel_format)
{
    switch (pixel_format) {
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_422YpCbCr8FullRange:
            return true;

        default:
            return false;
    }
}

static inline bool update_frame(vcam_data *vcam, obs_source_frame *frame, CMSampleBufferRef sample_buffer)
{
    CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sample_buffer);

    FourCharCode fourcc = CMFormatDescriptionGetMediaSubType(desc);
    video_format format = format_from_subtype(fourcc);
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);

    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sample_buffer);

    bool video_params_were_valid = vcam->video_info.video_params_valid;
    shared_ptr<void> _(nullptr, [&](...) {
        if (video_params_were_valid != vcam->video_info.video_params_valid)
            obs_source_update_properties(vcam->source);
    });

    if (format == VIDEO_FORMAT_NONE) {
        if (vcam->fourcc == fourcc)
            return false;

        vcam->fourcc = fourcc;
        obs_log(LOG_ERROR, "Unhandled fourcc: %s (0x%x) (%zu planes)", AV_FOURCC_STR(fourcc), fourcc,
                CVPixelBufferGetPlaneCount(img));
        return false;
    }

    if (frame->format != format)
        obs_log(LOG_DEBUG,
                "Switching fourcc: "
                "'%s' (0x%x) -> '%s' (0x%x)",
                AV_FOURCC_STR(vcam->fourcc), vcam->fourcc, AV_FOURCC_STR(fourcc), fourcc);

    bool was_yuv = format_is_yuv(frame->format);

    vcam->fourcc = fourcc;
    frame->format = format;
    frame->width = dims.width;
    frame->height = dims.height;

    if (format_is_yuv(format) && !update_colorspace(vcam, frame, desc, is_fullrange_yuv(fourcc), vcam->video_info)) {
        return false;
    } else if (was_yuv == format_is_yuv(format)) {
        vcam->video_info.video_params_valid = true;
    }

    CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);

    if (!CVPixelBufferIsPlanar(img)) {
        frame->linesize[0] = (uint32_t) CVPixelBufferGetBytesPerRow(img);
        frame->data[0] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(img));
        return true;
    }

    size_t count = CVPixelBufferGetPlaneCount(img);
    for (size_t i = 0; i < count; i++) {
        frame->linesize[i] = (uint32_t) CVPixelBufferGetBytesPerRowOfPlane(img, i);
        frame->data[i] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(img, i));
    }
    return true;
}

@implementation VCamDelegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    UNUSED_PARAMETER(captureOutput);
    UNUSED_PARAMETER(connection);

    CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
    if (count < 1 || !vcam)
        return;

    CMTime target_pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    CMTime target_pts_nano = CMTimeConvertScale(target_pts, NSEC_PER_SEC, kCMTimeRoundingMethod_Default);

    CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType type = CMFormatDescriptionGetMediaType(desc);
    if (type == kCMMediaType_Video) {
        obs_source_frame *frame = &vcam->frame;
        frame->timestamp = target_pts_nano.value;

        if (!update_frame(vcam, frame, sampleBuffer)) {
            obs_source_output_video(vcam->source, nullptr);
            return;
        }

        obs_source_output_video(vcam->source, frame);

        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
        CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    }
}
@end
