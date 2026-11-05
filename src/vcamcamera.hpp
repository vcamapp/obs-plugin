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

#pragma once

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <memory>

using namespace std;

@interface VCamDelegate: NSObject<AVCaptureVideoDataOutputSampleBufferDelegate> {
    @public
    struct vcam_data *vcam;
}
- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
fromConnection:(AVCaptureConnection *)connection;
@end

static auto remove_observer = [](id observer) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
};

struct observer_handle : unique_ptr<remove_pointer<id>::type, decltype(remove_observer)> {
    using base = unique_ptr<remove_pointer<id>::type, decltype(remove_observer)>;

    explicit observer_handle(id observer = nullptr) : base(observer, remove_observer)
    {}
};

struct video_info {
    atomic<video_colorspace> colorspace;
    atomic<video_range_type> video_range;
    atomic<bool> video_params_valid = false;
};

enum class vcam_status {
    receiving,
    waiting_for_video,
    app_not_running,
    virtual_camera_unavailable,
    camera_access_denied,
};

struct vcam_data {
    obs_source_t *source;
    VCamDelegate *delegate;
    video_info video_info;
    FourCharCode fourcc;

    observer_handle connect_observer;
    observer_handle disconnect_observer;

    NSString *uid;
    AVCaptureDevice *device;
    AVCaptureDeviceInput *device_input;
    AVCaptureSession *session;
    AVCaptureVideoDataOutput *output;
    dispatch_queue_t queue;

    // Owns the session and device state. Starting a session blocks, and OBS calls show and hide on its graphics thread.
    dispatch_queue_t session_queue;
    NSOperationQueue *session_operations;
    dispatch_source_t status_timer;

    atomic<bool> showing = false;
    atomic<bool> deactivate_when_not_showing = true;
    atomic<uint64_t> last_frame_time_ns = 0;
    atomic<vcam_status> status = vcam_status::waiting_for_video;

    obs_source_frame frame;
};

// MARK: - Functions

bool vcam_init(vcam_data *vcam, obs_data_t *settings);
void vcam_shutdown(vcam_data *vcam);
void vcam_set_showing(vcam_data *vcam, bool showing);
void vcam_set_deactivate_when_not_showing(vcam_data *vcam, bool deactivate);
void vcam_add_open_app_buttons(obs_properties_t *props);
