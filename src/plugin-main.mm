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

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

static const char *image_source_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return obs_module_text("VCam");
}

static void *vcam_source_create(obs_data_t *settings, obs_source_t *source)
{
    UNUSED_PARAMETER(settings);

    unique_ptr<vcam_data> vcam;

    try {
        vcam.reset(new vcam_data());
    } catch (...) {
        return vcam.release();
    }

    vcam->source = source;

    if (!vcam_init(vcam.get(), settings)) {
        obs_log(LOG_ERROR, "av_capture_init failed");
        return nullptr;
    }

    // TODO: Consider whether this is necessary
    // obs_source_set_async_unbuffered(vcam->source, false);

    return vcam.release();
}

static void vcam_source_destroy(void *data)
{
    auto vcam = static_cast<vcam_data *>(data);
    delete vcam;
}

static void vcam_source_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "uid", "");
    obs_data_set_default_string(settings, "device", "B44FD7BA-D1DC-4899-9759-ED370864E2C0");

    obs_data_set_default_int(settings, "input_format", -1);
    obs_data_set_default_int(settings, "color_space", -1);
    obs_data_set_default_int(settings, "video_range", -1);
}

static obs_properties_t *vcam_source_properties(void *data)
{
    UNUSED_PARAMETER(data);
    obs_properties_t *props = obs_properties_create();
    // TODO: Support some options
    return props;
}

static struct obs_source_info image_source_info = {
    .id = "vcam_source",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
    .get_name = image_source_get_name,
    .create = vcam_source_create,
    .destroy = vcam_source_destroy,
    .get_defaults = vcam_source_defaults,
    .get_properties = vcam_source_properties,
    .icon_type = OBS_ICON_TYPE_CAMERA,
};

bool obs_module_load(void)
{
    obs_log(LOG_INFO, "plugin loaded successfully (version %s)",
            PLUGIN_VERSION);
    obs_register_source(&image_source_info);
    return true;
}

void obs_module_unload(void)
{
    obs_log(LOG_INFO, "plugin unloaded");
}
