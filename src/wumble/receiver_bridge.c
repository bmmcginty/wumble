#define _GNU_SOURCE
#include <rtc/rtc.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
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

static void on_message(int track, const char *message, int size, void *ptr) {
    (void)track;
    wumble_receiver *receiver = ptr;
    if (!receiver || size <= 0 || size > 4093) return;
    atomic_fetch_add(&receiver->received, 1);

    uint16_t length = htons((uint16_t)size);
    struct iovec parts[] = {
        { .iov_base = &length, .iov_len = sizeof(length) },
        { .iov_base = (void *)message, .iov_len = (size_t)size },
    };

    pthread_mutex_lock(&receiver->lock);
    if (receiver->write_fd >= 0 && writev(receiver->write_fd, parts, 2) == size + 2) {
        atomic_fetch_add(&receiver->queued, 1);
    }
    pthread_mutex_unlock(&receiver->lock);
}

static void on_track(int pc, int track, void *ptr) {
    (void)pc;
    wumble_receiver *receiver = ptr;
    rtcSetUserPointer(track, receiver);
    rtcSetMessageCallback(track, on_message);
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
