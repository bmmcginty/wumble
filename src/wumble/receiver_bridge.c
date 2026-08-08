#define _GNU_SOURCE
#include <rtc/rtc.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <sys/uio.h>
#include <unistd.h>

/*
 * libdatachannel invokes media callbacks from its own threads. Crystal's GC
 * runtime cannot be entered from those threads, so callbacks only copy each
 * packet into this non-blocking pipe. Crystal consumes it from a normal fiber.
 */
typedef struct {
    int read_fd;
    int write_fd;
    pthread_mutex_t lock;
    _Atomic uint64_t received;
    _Atomic uint64_t queued;
} wumble_receiver;

/*
 * Timestamped logger for libdatachannel so its internal messages can be
 * correlated with the receiver_bridge diagnostics below.
 */
static void log_callback(rtcLogLevel level, const char *message) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    int64_t ms = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;

    const char *level_str = "?";
    switch (level) {
    case RTC_LOG_NONE:    level_str = "NONE";    break;
    case RTC_LOG_FATAL:   level_str = "FATAL";   break;
    case RTC_LOG_ERROR:   level_str = "ERROR";   break;
    case RTC_LOG_WARNING: level_str = "WARN";    break;
    case RTC_LOG_INFO:    level_str = "INFO";    break;
    case RTC_LOG_DEBUG:   level_str = "DEBUG";   break;
    case RTC_LOG_VERBOSE: level_str = "VERBOSE"; break;
    }
    fprintf(stderr, "[%lld] libdatachannel %-7s %s\n", (long long)ms, level_str, message);
}

void wumble_init_logger(void) {
    rtcInitLogger(RTC_LOG_VERBOSE, log_callback);
}

static void on_message(int track, const char *message, int size, void *ptr) {
    wumble_receiver *receiver = ptr;
    /* Keep the entire record within PIPE_BUF so concurrent callback writes are
     * atomic. The timestamp lets Crystal measure native-callback-to-forward
     * delay rather than merely counting queued packets. */
    if (!receiver || size <= 0 || size > 4090) return;
    atomic_fetch_add(&receiver->received, 1);
    /* Diagnostic: log first 8 bytes with a timestamp so we can correlate
     * with the libdatachannel debug stream above. */
    {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t ms = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
        char hex[17] = "";
        for (int i = 0; i < size && i < 8; i++)
            snprintf(hex + i * 2, 3, "%02x", (unsigned char)message[i]);
        fprintf(stderr, "[%lld] receiver_bridge track=%d size=%d first8=%s\n",
                (long long)ms, track, size, hex);
    }
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    uint16_t length = htons((uint16_t)size);
    uint32_t timestamp_ms = htonl((uint32_t)((uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000));
    struct iovec parts[] = {
        { .iov_base = &length, .iov_len = sizeof(length) },
        { .iov_base = &timestamp_ms, .iov_len = sizeof(timestamp_ms) },
        { .iov_base = (void *)message, .iov_len = (size_t)size },
    };

    pthread_mutex_lock(&receiver->lock);
    if (receiver->write_fd >= 0 && writev(receiver->write_fd, parts, 3) == size + 6) {
        atomic_fetch_add(&receiver->queued, 1);
    }
    pthread_mutex_unlock(&receiver->lock);
}

static void on_track(int pc, int track, void *ptr) {
    (void)pc;
    wumble_receiver *receiver = ptr;
    rtcSetUserPointer(track, receiver);
    rtcSetMessageCallback(track, on_message);

    /* Log the track's media description so we know what codecs and payload
     * types libdatachannel has negotiated for it. */
    char desc[4096] = "";
    char mid[64] = "";
    rtcDirection dir = RTC_DIRECTION_UNKNOWN;
    rtcGetTrackDescription(track, desc, sizeof(desc));
    rtcGetTrackMid(track, mid, sizeof(mid));
    rtcGetTrackDirection(track, &dir);

    int pt_buf[32];
    int pt_count = rtcGetTrackPayloadTypesForCodec(track, "opus", pt_buf, 32);
    fprintf(stderr, "receiver_bridge: track=%d mid=\"%s\" dir=%d payload_types_opus_count=%d desc=\"%s\"\n",
            track, mid, (int)dir, pt_count >= 0 ? pt_count : -1, desc);
    if (pt_count > 0) {
        fprintf(stderr, "receiver_bridge: track=%d opus_payload_types: ", track);
        for (int i = 0; i < pt_count; i++)
            fprintf(stderr, "%d ", pt_buf[i]);
        fprintf(stderr, "\n");
    }
}

int wumble_receiver_start(int pc) {
    wumble_receiver *receiver = calloc(1, sizeof(*receiver));
    if (!receiver) return -1;

    int fds[2];
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) {
        free(receiver);
        return -1;
    }
    receiver->read_fd = fds[0];
    receiver->write_fd = fds[1];
    pthread_mutex_init(&receiver->lock, NULL);
    rtcSetUserPointer(pc, receiver);
    if (rtcSetTrackCallback(pc, on_track) < 0) {
        close(fds[0]);
        close(fds[1]);
        pthread_mutex_destroy(&receiver->lock);
        free(receiver);
        return -1;
    }
    return receiver->read_fd;
}

uint64_t wumble_receiver_received(int pc) {
    wumble_receiver *receiver = rtcGetUserPointer(pc);
    return receiver ? atomic_load(&receiver->received) : 0;
}

uint64_t wumble_receiver_queued(int pc) {
    wumble_receiver *receiver = rtcGetUserPointer(pc);
    return receiver ? atomic_load(&receiver->queued) : 0;
}

void wumble_receiver_stop(int pc) {
    wumble_receiver *receiver = rtcGetUserPointer(pc);
    if (!receiver) return;
    pthread_mutex_lock(&receiver->lock);
    if (receiver->read_fd >= 0) close(receiver->read_fd);
    if (receiver->write_fd >= 0) close(receiver->write_fd);
    receiver->read_fd = -1;
    receiver->write_fd = -1;
    pthread_mutex_unlock(&receiver->lock);
    /* Keep receiver allocated: a libdatachannel callback can still hold ptr. */
}
