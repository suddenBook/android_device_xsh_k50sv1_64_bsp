
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>

typedef void VOID;
typedef int32_t INT32;
typedef uint32_t UINT32;
typedef uint8_t UINT8;
typedef uint8_t *PUINT8;
typedef bool MTK_WCN_BOOL;
#define MTK_WCN_BOOL_TRUE true
#define MTK_WCN_BOOL_FALSE false
#define __user
#define WMT_STAT_CMD 6
#define WMT_DBG_FUNC(...) ((void)0)
#define WMT_WARN_FUNC(...) ((void)0)
#define WMT_ERR_FUNC(...) ((void)0)
#define WMT_LOUD_FUNC(...) ((void)0)
#define osal_strlen(s) strlen((const char *)(s))
#define osal_strncpy(d, s, n) strncpy((char *)(d), (const char *)(s), (n))
#define osal_memcpy memcpy
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define DEFINE_MUTEX(name) pthread_mutex_t name = PTHREAD_MUTEX_INITIALIZER
struct file { unsigned long delivered_generation; };
typedef struct { atomic_int done; unsigned int timeoutValue; } OSAL_SIGNAL, *P_OSAL_SIGNAL;
typedef struct { int unused; } OSAL_EVENT, *P_OSAL_EVENT;
typedef struct {
    unsigned long state;
    UINT8 cCmd[NAME_MAX + 1];
    INT32 cmdResult;
    OSAL_SIGNAL cmdResp;
    OSAL_EVENT cmdReq;
} DEV_WMT, *P_DEV_WMT;
static DEV_WMT gDevWmt;
static atomic_int fail_copy, read_copies, event_calls;
static int scenario;
static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t signal_cv = PTHREAD_COND_INITIALIZER;
static int early_ready, early_read;
static char received[NAME_MAX + 1];
static const UINT8 command[] = "srh_patch";
static void on_copy(void);

static int osal_test_bit(unsigned int bit, const unsigned long *state)
{ return (__atomic_load_n(state, __ATOMIC_SEQ_CST) >> bit) & 1; }
static int osal_test_and_set_bit(unsigned int bit, unsigned long *state)
{ return (__atomic_fetch_or(state, 1UL << bit, __ATOMIC_SEQ_CST) >> bit) & 1; }
static int osal_test_and_clear_bit(unsigned int bit, unsigned long *state)
{ return (__atomic_fetch_and(state, ~(1UL << bit), __ATOMIC_SEQ_CST) >> bit) & 1; }
static void osal_set_bit(unsigned int bit, unsigned long *state)
{ (void)osal_test_and_set_bit(bit, state); }
static void osal_clear_bit(unsigned int bit, unsigned long *state)
{ (void)osal_test_and_clear_bit(bit, state); }
static unsigned long copy_to_user(void *dest, const void *source, size_t count)
{
    read_copies++;
    if (fail_copy) return count;
    on_copy();
    memcpy(dest, source, count);
    return 0;
}
static unsigned long copy_from_user(void *dest, const void *source, size_t count)
{
    if (fail_copy) return count;
    memcpy(dest, source, count);
    return 0;
}
ssize_t WMT_read(struct file *, char *, size_t, loff_t *);
ssize_t WMT_write(struct file *, const char *, size_t, loff_t *);
INT32 wmt_ctrl_ul_cmd(P_DEV_WMT, const PUINT8);
static void on_event(void);
static void on_wait(void);
static int osal_signal_init(P_OSAL_SIGNAL signal)
{
    if (scenario == 6 && osal_test_bit(WMT_STAT_CMD, &gDevWmt.state)) {
        early_ready++;
        early_read = WMT_read(NULL, received, sizeof(received), NULL);
        WMT_write(NULL, "ok", 2, NULL);
    }
    signal->done = 0;
    return 0;
}
static void osal_raise_signal(P_OSAL_SIGNAL signal)
{
    pthread_mutex_lock(&signal_lock);
    signal->done = 1;
    pthread_cond_broadcast(&signal_cv);
    pthread_mutex_unlock(&signal_lock);
}
static int osal_trigger_event(P_OSAL_EVENT event)
{ (void)event; event_calls++; on_event(); return 0; }
static int osal_wait_for_signal_timeout(P_OSAL_SIGNAL signal, void *thread)
{
    (void)thread;
    if (scenario >= 100) {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += 3;
        pthread_mutex_lock(&signal_lock);
        while (!signal->done) {
            if (pthread_cond_timedwait(&signal_cv, &signal_lock, &deadline) == ETIMEDOUT)
                break;
        }
        int done = signal->done;
        pthread_mutex_unlock(&signal_lock);
        return done;
    }
    on_wait();
    return signal->done;
}
static DEFINE_MUTEX(g_wmt_cmd_lock);
static bool g_wmt_cmd_in_progress;
static bool g_wmt_cmd_delivered;
static bool g_wmt_cmd_responded;
INT32 wmt_lib_trigger_cmd_signal(INT32 result)
{
	INT32 ret = -EINVAL;

	mutex_lock(&g_wmt_cmd_lock);
	if (g_wmt_cmd_in_progress && g_wmt_cmd_delivered &&
	    !g_wmt_cmd_responded) {
		gDevWmt.cmdResult = result;
		g_wmt_cmd_responded = true;
		osal_raise_signal(&gDevWmt.cmdResp);
		ret = 0;
	}
	mutex_unlock(&g_wmt_cmd_lock);
	return ret;
}

VOID wmt_lib_cancel_cmd(VOID)
{
	mutex_lock(&g_wmt_cmd_lock);
	osal_clear_bit(WMT_STAT_CMD, &gDevWmt.state);
	g_wmt_cmd_delivered = false;
	if (g_wmt_cmd_in_progress && !g_wmt_cmd_responded) {
		gDevWmt.cmdResult = -ECANCELED;
		g_wmt_cmd_responded = true;
		osal_raise_signal(&gDevWmt.cmdResp);
	}
	mutex_unlock(&g_wmt_cmd_lock);
}

INT32 wmt_lib_send_cmd(const UINT8 *command)
{
	P_OSAL_SIGNAL signal = &gDevWmt.cmdResp;
	size_t length;
	INT32 wait_ret;
	INT32 result;

	if (!command)
		return -EINVAL;
	length = strnlen(command, NAME_MAX + 1);
	if (!length || length > NAME_MAX)
		return -EINVAL;

	mutex_lock(&g_wmt_cmd_lock);
	if (g_wmt_cmd_in_progress) {
		mutex_unlock(&g_wmt_cmd_lock);
		WMT_WARN_FUNC("command request is still pending\n");
		return -EBUSY;
	}
	g_wmt_cmd_in_progress = true;
	g_wmt_cmd_delivered = false;
	g_wmt_cmd_responded = false;
	gDevWmt.cmdResult = -ETIMEDOUT;
	osal_signal_init(signal);
	signal->timeoutValue = 6000;
	memcpy(gDevWmt.cCmd, command, length + 1);
	/* A poll/read must not observe the command before its completion is ready. */
	osal_set_bit(WMT_STAT_CMD, &gDevWmt.state);
	mutex_unlock(&g_wmt_cmd_lock);

	osal_trigger_event(&gDevWmt.cmdReq);
	wait_ret = osal_wait_for_signal_timeout(signal, NULL);
	WMT_DBG_FUNC("command wait result(%d)\n", wait_ret);

	mutex_lock(&g_wmt_cmd_lock);
	result = g_wmt_cmd_responded ? gDevWmt.cmdResult : -ETIMEDOUT;
	osal_clear_bit(WMT_STAT_CMD, &gDevWmt.state);
	g_wmt_cmd_in_progress = false;
	g_wmt_cmd_delivered = false;
	g_wmt_cmd_responded = false;
	mutex_unlock(&g_wmt_cmd_lock);
	if (result == -ETIMEDOUT)
		WMT_ERR_FUNC("command(%s) response timeout\n", command);
	WMT_DBG_FUNC("command(%s) result(%d)\n", command, result);
	return result;
}

ssize_t wmt_lib_read_cmd(char __user *buffer, size_t count)
{
	size_t length;
	ssize_t result = 0;

	if (!count)
		return 0;
	mutex_lock(&g_wmt_cmd_lock);
	if (!osal_test_bit(WMT_STAT_CMD, &gDevWmt.state))
		goto out;
	length = strlen(gDevWmt.cCmd);
	if (count < length) {
		result = -EMSGSIZE;
		goto out;
	}
	if (copy_to_user(buffer, gDevWmt.cCmd, length)) {
		result = -EFAULT;
		goto out;
	}
	/* Keep the request owned until its reply or the producer's timeout. */
	osal_clear_bit(WMT_STAT_CMD, &gDevWmt.state);
	g_wmt_cmd_delivered = true;
	result = length;
out:
	mutex_unlock(&g_wmt_cmd_lock);
	return result;
}

MTK_WCN_BOOL wmt_lib_get_cmd_status(VOID)
{
	return osal_test_bit(WMT_STAT_CMD, &gDevWmt.state) ? MTK_WCN_BOOL_TRUE : MTK_WCN_BOOL_FALSE;
}

INT32 wmt_ctrl_ul_cmd(P_DEV_WMT pWmtDev, const PUINT8 pCmdStr)
{
	if (pWmtDev != &gDevWmt)
		return -EINVAL;
	return wmt_lib_send_cmd(pCmdStr);
}

ssize_t WMT_write(struct file *filp, const char __user *buf, size_t count, loff_t *f_pos)
{
	INT32 iRet = 0;
	UINT8 wrBuf[NAME_MAX + 1] = { 0 };
	INT32 copySize = (count < NAME_MAX) ? count : NAME_MAX;

	WMT_LOUD_FUNC("count:%zu copySize:%d\n", count, copySize);

	if (copySize > 0) {
		if (copy_from_user(wrBuf, buf, copySize)) {
			iRet = -EFAULT;
			goto write_done;
		}
		wrBuf[NAME_MAX] = '\0';

		if (!strncasecmp(wrBuf, "ok", NAME_MAX)) {
			WMT_DBG_FUNC("resp str ok\n");
			iRet = wmt_lib_trigger_cmd_signal(0);
		} else {
			WMT_WARN_FUNC("warning resp str (%s)\n", wrBuf);
			iRet = wmt_lib_trigger_cmd_signal(-1);
		}
		if (!iRet)
			iRet = copySize;
	}

write_done:
	return iRet;
}

ssize_t WMT_read(struct file *filp, char __user *buf, size_t count, loff_t *f_pos)
{
	return wmt_lib_read_cmd(buf, count);
}

#define CHECK(value) do { if (!(value)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #value); abort(); \
} } while (0)
static struct file open_a, open_b;
static struct file *model_owner;
static unsigned long model_generation;
static int affinity_model, phase;
static int first_result, second_result = -999;
static int stale_reply_result = -999, genuine_reply_result = -999;
static bool stale_reply_accepted;

/* Test-only open affinity plus an implicit per-open generation. No production
 * function is patched. Updating this generation on read B cannot identify which
 * request an untagged write from the same open actually answers.
 */
static ssize_t model_read(struct file *file, char *buffer, size_t count)
{
    ssize_t result = WMT_read(file, buffer, count, NULL);
    if (affinity_model && result > 0) {
        model_owner = file;
        file->delivered_generation = model_generation;
    }
    return result;
}

static ssize_t model_write(struct file *file, const char *buffer, size_t count)
{
    if (affinity_model && (model_owner != file ||
        file->delivered_generation != model_generation))
        return -ESTALE;
    ssize_t result = WMT_write(file, buffer, count, NULL);
    if (affinity_model && result > 0) model_owner = NULL;
    return result;
}

static void on_event(void) { model_generation++; }
static void on_copy(void) {}

static void read_command(struct file *file, const char *expected)
{
    char buffer[NAME_MAX + 1] = {0};
    CHECK(model_read(file, buffer, sizeof(buffer)) == (ssize_t)strlen(expected));
    CHECK(!strcmp(buffer, expected));
}

static void on_wait(void)
{
    if (scenario >= 11 && scenario <= 15) {
        if (!phase) {
            read_command(&open_a, "srh_patch");
            if (scenario == 13) CHECK(model_write(&open_a, "ok", 2) == 2);
            else if (scenario == 14 || scenario == 15) wmt_lib_cancel_cmd();
            /* Other first requests expire without a response. */
            return;
        }
        /* Existing guards correctly reject stale replies before B is read. */
        CHECK(model_write(&open_a, "ok", 2) < 0);
        bool cross_open = scenario == 11 || scenario == 14;
        struct file *reader = cross_open ? &open_b : &open_a;
        read_command(reader, "update_patch_version");
        stale_reply_result = model_write(&open_a, "ok", 2);
        stale_reply_accepted = stale_reply_result == 2;
        /* B's real handler failed. A's stale success must not replace that. */
        genuine_reply_result = model_write(reader, "fail", 4);
        CHECK(stale_reply_accepted == !(cross_open && affinity_model));
        CHECK(stale_reply_accepted ? genuine_reply_result < 0 : genuine_reply_result == 4);
        return;
    }

    if (scenario == 16) {
        char buffer[NAME_MAX + 1] = {0};
        CHECK(model_read(&open_a, buffer, 0) == 0);
        CHECK(model_read(&open_a, buffer, 2) == -EMSGSIZE);
        CHECK(wmt_lib_get_cmd_status());
        CHECK(model_write(&open_a, "ok", 2) < 0);
        fail_copy = 1;
        CHECK(model_read(&open_a, buffer, sizeof(buffer)) == -EFAULT);
        fail_copy = 0;
        CHECK(wmt_lib_get_cmd_status());
        CHECK(model_write(&open_a, "ok", 2) < 0);
    }
    read_command(&open_a, "srh_patch");
    if (scenario == 17) {
        fail_copy = 1;
        CHECK(model_write(&open_a, "ok", 2) == -EFAULT);
        fail_copy = 0;
    }
    genuine_reply_result = scenario == 18 ? model_write(&open_a, "fail", 4) :
                                          model_write(&open_a, "ok", 2);
    CHECK(genuine_reply_result == (scenario == 18 ? 4 : 2));
    if (scenario == 19) CHECK(model_write(&open_a, "ok", 2) < 0);
}

int main(int argc, char **argv)
{
    CHECK(argc == 3);
    affinity_model = atoi(argv[1]); scenario = atoi(argv[2]);
    CHECK(scenario >= 10 && scenario <= 19);
    first_result = wmt_ctrl_ul_cmd(&gDevWmt, (PUINT8)command);
    if (scenario >= 11 && scenario <= 15) {
        CHECK(first_result == (scenario == 13 ? 0 :
              (scenario == 14 || scenario == 15 ? -ECANCELED : -ETIMEDOUT)));
        phase = 1;
        second_result = wmt_ctrl_ul_cmd(&gDevWmt, (PUINT8)"update_patch_version");
        CHECK(second_result == (stale_reply_accepted ? 0 : -1));
        CHECK(event_calls == 2);
    } else {
        CHECK(first_result == (scenario == 18 ? -1 : 0));
        CHECK(event_calls == 1);
    }
    CHECK(!wmt_lib_get_cmd_status());
    CHECK(model_write(&open_a, "ok", 2) < 0);
    printf("{\"affinity_model\":%s,\"scenario\":%d,\"first_result\":%d,"
           "\"second_result\":%d,\"stale_reply_result\":%d,"
           "\"genuine_reply_result\":%d,\"stale_reply_accepted\":%s}\n",
           affinity_model ? "true" : "false", scenario, first_result, second_result,
           stale_reply_result, genuine_reply_result, stale_reply_accepted ? "true" : "false");
    return 0;
}
