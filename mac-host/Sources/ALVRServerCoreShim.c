#include "ALVRServerCoreShim.h"

#include <math.h>
#include <string.h>

#include "../Vendor/ALVRServerCore/alvr_server_core.h"

void vc_alvr_initialize_environment(const char *config_dir, const char *log_dir) {
    alvr_initialize_environment(config_dir, log_dir);
}

void vc_alvr_initialize_logging(const char *session_log_path, const char *crash_log_path) {
    alvr_initialize_logging(session_log_path, crash_log_path);
}

VCAlvrTargetConfig vc_alvr_initialize(void) {
    struct AlvrTargetConfig config = alvr_initialize();
    return (VCAlvrTargetConfig) {
        .game_render_width = config.game_render_width,
        .game_render_height = config.game_render_height,
        .stream_width = config.stream_width,
        .stream_height = config.stream_height,
    };
}

void vc_alvr_start_connection(void) {
    alvr_start_connection();
}

void vc_alvr_shutdown(void) {
    alvr_shutdown();
}

bool vc_alvr_poll_event(VCAlvrEvent *out_event, uint64_t timeout_ns) {
    if (out_event == NULL) {
        return false;
    }

    memset(out_event, 0, sizeof(*out_event));

    union AlvrEvent raw_event;
    if (!alvr_poll_event(&raw_event, timeout_ns)) {
        out_event->kind = VC_ALVR_EVENT_NONE;
        return false;
    }

    switch (raw_event.tag) {
        case ALVR_EVENT_CLIENT_CONNECTED:
            out_event->kind = VC_ALVR_EVENT_CLIENT_CONNECTED;
            break;
        case ALVR_EVENT_CLIENT_DISCONNECTED:
            out_event->kind = VC_ALVR_EVENT_CLIENT_DISCONNECTED;
            break;
        case ALVR_EVENT_VIEWS_CONFIG:
            out_event->kind = VC_ALVR_EVENT_VIEWS_CONFIG;
            float dx = raw_event.VIEWS_CONFIG.local_view_transform[0].position[0]
                - raw_event.VIEWS_CONFIG.local_view_transform[1].position[0];
            float dy = raw_event.VIEWS_CONFIG.local_view_transform[0].position[1]
                - raw_event.VIEWS_CONFIG.local_view_transform[1].position[1];
            float dz = raw_event.VIEWS_CONFIG.local_view_transform[0].position[2]
                - raw_event.VIEWS_CONFIG.local_view_transform[1].position[2];
            out_event->ipd_m = sqrtf(dx * dx + dy * dy + dz * dz);
            out_event->left_fov = (VCAlvrFov) {
                .left = raw_event.VIEWS_CONFIG.fov[0].left,
                .right = raw_event.VIEWS_CONFIG.fov[0].right,
                .up = raw_event.VIEWS_CONFIG.fov[0].up,
                .down = raw_event.VIEWS_CONFIG.fov[0].down,
            };
            out_event->right_fov = (VCAlvrFov) {
                .left = raw_event.VIEWS_CONFIG.fov[1].left,
                .right = raw_event.VIEWS_CONFIG.fov[1].right,
                .up = raw_event.VIEWS_CONFIG.fov[1].up,
                .down = raw_event.VIEWS_CONFIG.fov[1].down,
            };
            break;
        case ALVR_EVENT_TRACKING_UPDATED:
            out_event->kind = VC_ALVR_EVENT_TRACKING_UPDATED;
            out_event->sample_timestamp_ns = raw_event.TRACKING_UPDATED.sample_timestamp_ns;
            break;
        case ALVR_EVENT_RAW_BUTTONS_UPDATED:
            out_event->kind = VC_ALVR_EVENT_RAW_BUTTONS_UPDATED;
            break;
        case ALVR_EVENT_REQUEST_IDR:
            out_event->kind = VC_ALVR_EVENT_REQUEST_IDR;
            break;
        case ALVR_EVENT_RESTART_PENDING:
            out_event->kind = VC_ALVR_EVENT_RESTART_PENDING;
            break;
        case ALVR_EVENT_SHUTDOWN_PENDING:
            out_event->kind = VC_ALVR_EVENT_SHUTDOWN_PENDING;
            break;
        default:
            out_event->kind = VC_ALVR_EVENT_NONE;
            break;
    }

    return true;
}

uint64_t vc_alvr_path_to_id(const char *path_string) {
    return alvr_path_to_id(path_string);
}

uint64_t vc_alvr_head_device_id(void) {
    return alvr_path_to_id("/user/head");
}

uint64_t vc_alvr_left_hand_device_id(void) {
    return alvr_path_to_id("/user/hand/left");
}

uint64_t vc_alvr_right_hand_device_id(void) {
    return alvr_path_to_id("/user/hand/right");
}

bool vc_alvr_get_head_pose(uint64_t sample_timestamp_ns, VCAlvrPoseSample *out_pose) {
    return vc_alvr_get_device_pose(vc_alvr_head_device_id(), sample_timestamp_ns, out_pose);
}

bool vc_alvr_get_device_pose(uint64_t device_id, uint64_t sample_timestamp_ns, VCAlvrPoseSample *out_pose) {
    if (out_pose == NULL) {
        return false;
    }

    memset(out_pose, 0, sizeof(*out_pose));

    struct AlvrDeviceMotion motion;
    if (!alvr_get_device_motion(device_id, sample_timestamp_ns, &motion)) {
        return false;
    }

    out_pose->sample_timestamp_ns = sample_timestamp_ns;
    out_pose->position_x = motion.pose.position[0];
    out_pose->position_y = motion.pose.position[1];
    out_pose->position_z = motion.pose.position[2];
    out_pose->orientation_x = motion.pose.orientation.x;
    out_pose->orientation_y = motion.pose.orientation.y;
    out_pose->orientation_z = motion.pose.orientation.z;
    out_pose->orientation_w = motion.pose.orientation.w;
    out_pose->linear_velocity_x = motion.linear_velocity[0];
    out_pose->linear_velocity_y = motion.linear_velocity[1];
    out_pose->linear_velocity_z = motion.linear_velocity[2];
    out_pose->angular_velocity_x = motion.angular_velocity[0];
    out_pose->angular_velocity_y = motion.angular_velocity[1];
    out_pose->angular_velocity_z = motion.angular_velocity[2];

    return true;
}

bool vc_alvr_get_hand_skeleton(VCAlvrHandKind hand, uint64_t sample_timestamp_ns,
                               VCAlvrJointPose *out_skeleton, uint64_t capacity) {
    if (out_skeleton == NULL || capacity < 26) {
        return false;
    }

    struct AlvrPose raw_skeleton[26];
    AlvrHandType raw_hand = hand == VC_ALVR_HAND_LEFT ? ALVR_HAND_TYPE_LEFT : ALVR_HAND_TYPE_RIGHT;
    if (!alvr_get_hand_skeleton(raw_hand, sample_timestamp_ns, raw_skeleton)) {
        return false;
    }

    for (uint64_t i = 0; i < 26; i++) {
        out_skeleton[i] = (VCAlvrJointPose) {
            .position_x = raw_skeleton[i].position[0],
            .position_y = raw_skeleton[i].position[1],
            .position_z = raw_skeleton[i].position[2],
            .orientation_x = raw_skeleton[i].orientation.x,
            .orientation_y = raw_skeleton[i].orientation.y,
            .orientation_z = raw_skeleton[i].orientation.z,
            .orientation_w = raw_skeleton[i].orientation.w,
        };
    }

    return true;
}

static bool vc_alvr_is_scalar_button(uint64_t id) {
    static const char *paths[] = {
        "/user/hand/left/input/trigger/value",
        "/user/hand/left/input/trigger/sensor/value",
        "/user/hand/left/input/squeeze/value",
        "/user/hand/left/input/squeeze/force",
        "/user/hand/left/input/squeeze/sensor/value",
        "/user/hand/left/input/thumbstick/x",
        "/user/hand/left/input/thumbstick/y",
        "/user/hand/right/input/trigger/value",
        "/user/hand/right/input/trigger/sensor/value",
        "/user/hand/right/input/squeeze/value",
        "/user/hand/right/input/squeeze/force",
        "/user/hand/right/input/squeeze/sensor/value",
        "/user/hand/right/input/thumbstick/x",
        "/user/hand/right/input/thumbstick/y",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (id == alvr_path_to_id(paths[i])) {
            return true;
        }
    }
    return false;
}

uint64_t vc_alvr_get_raw_buttons(VCAlvrButtonEntry *out_entries) {
    uint64_t count = alvr_get_raw_buttons(NULL);
    if (out_entries == NULL || count == 0) {
        return count;
    }

    struct AlvrButtonEntry raw_entries[count];
    uint64_t written = alvr_get_raw_buttons(raw_entries);
    for (uint64_t i = 0; i < written; i++) {
        bool is_scalar = vc_alvr_is_scalar_button(raw_entries[i].id);
        out_entries[i].id = raw_entries[i].id;
        out_entries[i].value_kind = is_scalar ? VC_ALVR_BUTTON_VALUE_SCALAR : VC_ALVR_BUTTON_VALUE_BINARY;
        out_entries[i].bool_value = is_scalar ? false : raw_entries[i].value.scalar;
        out_entries[i].scalar_value = is_scalar ? raw_entries[i].value.float_value
            : (raw_entries[i].value.scalar ? 1.0f : 0.0f);
    }
    return written;
}

void vc_alvr_send_haptics(VCAlvrHandKind hand, float duration_s, float frequency, float amplitude) {
    uint64_t device_id = hand == VC_ALVR_HAND_LEFT ? vc_alvr_left_hand_device_id() : vc_alvr_right_hand_device_id();
    alvr_send_haptics(device_id, duration_s, frequency, amplitude);
}

void vc_alvr_set_video_config_hevc(const uint8_t *buffer_ptr, int32_t len) {
    alvr_set_video_config_nals(ALVR_CODEC_TYPE_HEVC, buffer_ptr, len);
}

void vc_alvr_send_video_nal(uint64_t timestamp_ns, uint8_t *buffer_ptr, int32_t len, bool is_idr) {
    alvr_send_video_nal(timestamp_ns, buffer_ptr, len, is_idr);
}

bool vc_alvr_get_dynamic_encoder_params(VCAlvrDynamicEncoderParams *out_params) {
    if (out_params == NULL) { return false; }
    struct AlvrDynamicEncoderParams raw_params;
    if (!alvr_get_dynamic_encoder_params(&raw_params)) { return false; }
    out_params->bitrate_bps = raw_params.bitrate_bps;
    out_params->framerate = raw_params.framerate;
    return true;
}

void vc_alvr_report_composed(uint64_t timestamp_ns, uint64_t offset_ns) {
    alvr_report_composed(timestamp_ns, offset_ns);
}

void vc_alvr_report_present(uint64_t timestamp_ns, uint64_t offset_ns) {
    alvr_report_present(timestamp_ns, offset_ns);
}

bool vc_alvr_duration_until_next_vsync(uint64_t *out_ns) {
    return alvr_duration_until_next_vsync(out_ns);
}
