extern "C" {
#include <rtc/rtc.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <stdlib.h>
#include <sys/uio.h>
#include <unistd.h>
}

#include <atomic>
#include <cstdio>
#include <cstring>

// Forward-declare the public API with C linkage.
extern "C" {
int wumble_receiver_start(int pc);
uint64_t wumble_receiver_received(int pc);
uint64_t wumble_receiver_queued(int pc);
void wumble_receiver_stop(int pc);
}

// Match the subset of Message::Type we can infer from the C API surface.
// Values must stay in sync with rtc::Message::Type in <rtc/message.hpp>.
enum {
    GUESS_BINARY  = 0,  // rtc::Message::Binary
    GUESS_STRING  = 1,  // rtc::Message::String
    GUESS_CONTROL = 2,  // rtc::Message::Control
    GUESS_RESET   = 3,  // rtc::Message::Reset
};

/*
 * libdatachannel invokes media callbacks from its own threads. Crystal's GC
 * runtime cannot be entered from those threads, so callbacks only copy each
 * packet into this non-blocking pipe. Crystal consumes it from a normal fiber.
 */
struct wumble_receiver {
    int read_fd;
    int write_fd;
    pthread_mutex_t lock;
    std::atomic<uint64_t> received;
    std::atomic<uint64_t> queued;
};

/*
 * Best-effort guess at the libdatachannel message type. The actual
 * rtc::Message::Type is stripped by the time the C callback fires, so we
 * infer it from the first byte of the payload combined with what we know
 * about the RTP/RTCP demux layer.
 *
 * Returns a GUESS_* enum value.
 */
static int guess_message_type(const char *message, int size) {
    (void)size;
    if (size <= 0) return GUESS_BINARY;

    unsigned char first = (unsigned char)message[0];
    unsigned int version = first >> 6;

    // Valid RTP: version == 2, and not an RTCP payload type in byte 1
    if (version == 2) {
        if (size >= 2) {
            unsigned char pt = (unsigned char)message[1];
            // RTCP packet types live in 192-213 (RFC 3550)
            if (pt >= 192 && pt <= 213)
                return GUESS_CONTROL;  // RTCP is folded into Control
        }
        return GUESS_BINARY;  // RTP media packet
    }

    // RTCP uses version 2 as well, so if version != 2 it is neither
    // standard RTP nor RTCP. Could be a data-channel message or a
    // libdatachannel-internal signal.
    return GUESS_BINARY;
}

static const char *guess_name(int type) {
    switch (type) {
    case GUESS_BINARY:  return "binary";
    case GUESS_STRING:  return "string";
    case GUESS_CONTROL: return "control(rtcp?)";
    case GUESS_RESET:   return "reset";
    default:            return "unknown";
    }
}

// These callbacks are 'static' (internal linkage). They are passed to the
// C API where the calling convention is compatible on all supported
// platforms; keeping them static avoids name-mangling complications.
static void on_message(int track, const char *message, int size, void *ptr) {
    wumble_receiver *receiver = (wumble_receiver *)ptr;
    if (!receiver || size <= 0 || size > 4090) return;

    receiver->received.fetch_add(1, std::memory_order_relaxed);

    /* --- diagnostic: identify the track and message type --- */
    char mid_buf[64] = "";
    rtcDirection dir = RTC_DIRECTION_UNKNOWN;
    rtcGetTrackMid(track, mid_buf, sizeof(mid_buf));
    rtcGetTrackDirection(track, &dir);

    int guessed = guess_message_type(message, size);
    const char *dir_str = "?";
    switch (dir) {
    case RTC_DIRECTION_SENDONLY:  dir_str = "sendonly"; break;
    case RTC_DIRECTION_RECVONLY:  dir_str = "recvonly"; break;
    case RTC_DIRECTION_SENDRECV:  dir_str = "sendrecv"; break;
    case RTC_DIRECTION_INACTIVE:  dir_str = "inactive"; break;
    case RTC_DIRECTION_UNKNOWN:   dir_str = "unknown"; break;
    }

    // Log first 16 bytes so we can correlate with tcpdump / opuslog data.
    char hex[33] = "";
    for (int i = 0; i < size && i < 16; i++)
        snprintf(hex + i * 2, 3, "%02x", (unsigned char)message[i]);

    fprintf(stderr, "receiver_bridge: track=%d mid=\"%s\" dir=%s guessed_type=%s(%d) size=%d first_bytes=%s\n",
            track, mid_buf, dir_str, guess_name(guessed), guessed, size, hex);
    /* --- end diagnostic --- */

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
        receiver->queued.fetch_add(1, std::memory_order_relaxed);
    }
    pthread_mutex_unlock(&receiver->lock);
}

static void on_track(int pc, int track, void *ptr) {
    (void)pc;
    wumble_receiver *receiver = (wumble_receiver *)ptr;

    char mid[64] = "";
    rtcDirection dir = RTC_DIRECTION_UNKNOWN;
    rtcGetTrackMid(track, mid, sizeof(mid));
    rtcGetTrackDirection(track, &dir);
    fprintf(stderr, "receiver_bridge: new track id=%d mid=\"%s\" direction=%d\n", track, mid, (int)dir);

    rtcSetUserPointer(track, receiver);
    rtcSetMessageCallback(track, on_message);
}

// Public API — C linkage so Crystal's @[Link] can resolve the symbols.
extern "C" {

int wumble_receiver_start(int pc) {
    wumble_receiver *receiver = new wumble_receiver();
    receiver->read_fd = -1;
    receiver->write_fd = -1;
    receiver->received.store(0, std::memory_order_relaxed);
    receiver->queued.store(0, std::memory_order_relaxed);

    int fds[2];
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) {
        delete receiver;
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
        delete receiver;
        return -1;
    }
    return receiver->read_fd;
}

uint64_t wumble_receiver_received(int pc) {
    wumble_receiver *receiver = (wumble_receiver *)rtcGetUserPointer(pc);
    return receiver ? receiver->received.load(std::memory_order_relaxed) : 0;
}

uint64_t wumble_receiver_queued(int pc) {
    wumble_receiver *receiver = (wumble_receiver *)rtcGetUserPointer(pc);
    return receiver ? receiver->queued.load(std::memory_order_relaxed) : 0;
}

void wumble_receiver_stop(int pc) {
    wumble_receiver *receiver = (wumble_receiver *)rtcGetUserPointer(pc);
    if (!receiver) return;
    pthread_mutex_lock(&receiver->lock);
    if (receiver->read_fd >= 0) close(receiver->read_fd);
    if (receiver->write_fd >= 0) close(receiver->write_fd);
    receiver->read_fd = -1;
    receiver->write_fd = -1;
    pthread_mutex_unlock(&receiver->lock);
    /* Keep receiver allocated: a libdatachannel callback can still hold ptr. */
}

} // extern "C"
