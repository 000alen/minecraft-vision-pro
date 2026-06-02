#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef uint8_t VCAlvrEventKind;
enum {
    VC_ALVR_EVENT_NONE = 0,
    VC_ALVR_EVENT_CLIENT_CONNECTED = 1,
    VC_ALVR_EVENT_CLIENT_DISCONNECTED = 2,
    VC_ALVR_EVENT_VIEWS_CONFIG = 3,
    VC_ALVR_EVENT_TRACKING_UPDATED = 4,
    VC_ALVR_EVENT_REQUEST_IDR = 5,
    VC_ALVR_EVENT_RESTART_PENDING = 6,
    VC_ALVR_EVENT_SHUTDOWN_PENDING = 7,
    VC_ALVR_EVENT_RAW_BUTTONS_UPDATED = 8,
};

typedef uint8_t VCAlvrHandKind;
enum {
    VC_ALVR_HAND_LEFT = 0,
    VC_ALVR_HAND_RIGHT = 1,
};

typedef uint8_t VCAlvrButtonValueKind;
enum {
    VC_ALVR_BUTTON_VALUE_NONE = 0,
    VC_ALVR_BUTTON_VALUE_BINARY = 1,
    VC_ALVR_BUTTON_VALUE_SCALAR = 2,
};

typedef struct VCAlvrTargetConfig {
    uint32_t game_render_width;
    uint32_t game_render_height;
    uint32_t stream_width;
    uint32_t stream_height;
} VCAlvrTargetConfig;

typedef struct VCAlvrFov {
    float left;
    float right;
    float up;
    float down;
} VCAlvrFov;

typedef struct VCAlvrEvent {
    VCAlvrEventKind kind;
    uint64_t sample_timestamp_ns;
    float ipd_m;
    VCAlvrFov left_fov;
    VCAlvrFov right_fov;
} VCAlvrEvent;

typedef struct VCAlvrPoseSample {
    uint64_t sample_timestamp_ns;
    float position_x;
    float position_y;
    float position_z;
    float orientation_x;
    float orientation_y;
    float orientation_z;
    float orientation_w;
    float linear_velocity_x;
    float linear_velocity_y;
    float linear_velocity_z;
    float angular_velocity_x;
    float angular_velocity_y;
    float angular_velocity_z;
} VCAlvrPoseSample;

typedef struct VCAlvrJointPose {
    float position_x;
    float position_y;
    float position_z;
    float orientation_x;
    float orientation_y;
    float orientation_z;
    float orientation_w;
} VCAlvrJointPose;

typedef struct VCAlvrButtonEntry {
    uint64_t id;
    VCAlvrButtonValueKind value_kind;
    bool bool_value;
    float scalar_value;
} VCAlvrButtonEntry;

typedef struct VCAlvrDynamicEncoderParams {
    float bitrate_bps;
    float framerate;
} VCAlvrDynamicEncoderParams;

void vc_alvr_initialize_environment(const char *config_dir, const char *log_dir);
void vc_alvr_initialize_logging(const char *session_log_path, const char *crash_log_path);
VCAlvrTargetConfig vc_alvr_initialize(void);
void vc_alvr_start_connection(void);
void vc_alvr_shutdown(void);
bool vc_alvr_poll_event(VCAlvrEvent *out_event, uint64_t timeout_ns);
uint64_t vc_alvr_path_to_id(const char *path_string);
uint64_t vc_alvr_head_device_id(void);
uint64_t vc_alvr_left_hand_device_id(void);
uint64_t vc_alvr_right_hand_device_id(void);
bool vc_alvr_get_head_pose(uint64_t sample_timestamp_ns, VCAlvrPoseSample *out_pose);
bool vc_alvr_get_device_pose(uint64_t device_id, uint64_t sample_timestamp_ns, VCAlvrPoseSample *out_pose);
bool vc_alvr_get_hand_skeleton(VCAlvrHandKind hand, uint64_t sample_timestamp_ns,
                               VCAlvrJointPose *out_skeleton, uint64_t capacity);
uint64_t vc_alvr_get_raw_buttons(VCAlvrButtonEntry *out_entries);
void vc_alvr_send_haptics(VCAlvrHandKind hand, float duration_s, float frequency, float amplitude);
void vc_alvr_set_video_config_hevc(const uint8_t *buffer_ptr, int32_t len);
void vc_alvr_send_video_nal(uint64_t timestamp_ns, uint8_t *buffer_ptr, int32_t len, bool is_idr);
bool vc_alvr_get_dynamic_encoder_params(VCAlvrDynamicEncoderParams *out_params);
void vc_alvr_report_composed(uint64_t timestamp_ns, uint64_t offset_ns);
void vc_alvr_report_present(uint64_t timestamp_ns, uint64_t offset_ns);
bool vc_alvr_duration_until_next_vsync(uint64_t *out_ns);
