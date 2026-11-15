/* CanonScan hardware-button watcher. SPDX-License-Identifier: GPL-3.0-or-later */
#include <sane/sane.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t stopped;
static void stop_waiting(int signal_number) { (void)signal_number; stopped = 1; }

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("scanbutton 1 (SANE start-button watcher)");
        return 0;
    }
    if (argc != 3 || strcmp(argv[1], "--device-name") != 0 || !argv[2][0]) {
        fputs("Usage: scanbutton --device-name DEVICE\n", stderr);
        return SANE_STATUS_INVAL;
    }
    struct sigaction action = {0};
    action.sa_handler = stop_waiting;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) {
        perror("scanbutton: sigaction");
        return SANE_STATUS_IO_ERROR;
    }
    SANE_Handle handle = NULL;
    SANE_Status status = sane_init(NULL, NULL);
    if (status != SANE_STATUS_GOOD) {
        fprintf(stderr, "scanbutton: initialize: %s\n", sane_strstatus(status));
        return stopped ? SANE_STATUS_CANCELLED : status;
    }
    int triggered = 0;
    status = sane_open(argv[2], &handle);
    if (status != SANE_STATUS_GOOD) goto finished;
    SANE_Int count = 0;
    status = sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, NULL);
    if (status != SANE_STATUS_GOOD) goto finished;
    SANE_Int start_option = -1;
    for (SANE_Int index = 1; index < count && !stopped; ++index) {
        const SANE_Option_Descriptor *option = sane_get_option_descriptor(handle, index);
        if (option && option->name && strcmp(option->name, "start") == 0 &&
            option->type == SANE_TYPE_BOOL && option->size == sizeof(SANE_Bool) &&
            SANE_OPTION_IS_ACTIVE(option->cap) && (option->cap & SANE_CAP_SOFT_DETECT)) {
            start_option = index;
            break;
        }
    }
    if (start_option < 0) { status = SANE_STATUS_UNSUPPORTED; goto finished; }
    /* Consume the opening panel value. Do not arm until a released state was
       observed: canon_dr panel reads can report an earlier, latched press. */
    SANE_Bool pressed = SANE_FALSE;
    status = sane_control_option(handle, start_option, SANE_ACTION_GET_VALUE, &pressed, NULL);
    if (status != SANE_STATUS_GOOD || stopped) goto finished;
    int armed = !pressed;
    if (puts("READY") == EOF || fflush(stdout) == EOF) { status = SANE_STATUS_IO_ERROR; goto finished; }
    while (!stopped) {
        struct timespec delay = {0, 200000000};
        while (!stopped && nanosleep(&delay, &delay) != 0) {}
        if (stopped) break;
        status = sane_control_option(handle, start_option, SANE_ACTION_GET_VALUE, &pressed, NULL);
        if (status != SANE_STATUS_GOOD) break;
        if (!pressed) armed = 1;
        else if (armed) { triggered = 1; break; }
    }
finished:
    /* Release USB before announcing START so scanimage may acquire the device. */
    if (handle) sane_close(handle);
    sane_exit();
    if (stopped) return SANE_STATUS_CANCELLED;
    if (status != SANE_STATUS_GOOD) {
        fprintf(stderr, "scanbutton: %s\n", sane_strstatus(status));
        return status;
    }
    if (triggered && (puts("START") == EOF || fflush(stdout) == EOF)) return SANE_STATUS_IO_ERROR;
    return SANE_STATUS_GOOD;
}
