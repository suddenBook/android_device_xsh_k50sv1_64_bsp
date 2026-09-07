
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
struct file { int unused; };
typedef struct { atomic_int done; unsigned int timeoutValue; } OSAL_SIGNAL, *P_OSAL_SIGNAL;
typedef struct { int unused; } OSAL_EVENT, *P_OSAL_EVENT;
typedef struct {
	UINT32 dowloadSeq;
	UINT8 addRess[4];
	UINT8 patchName[256];
} WMT_PATCH_INFO, *P_WMT_PATCH_INFO;
struct wmt_rom_patch_info {
	UINT32 type;
	UINT8 addRess[4];
	UINT8 patchName[256];
};
typedef struct {
    unsigned long state;
    UINT8 cCmd[NAME_MAX + 1];
    INT32 cmdResult;
    OSAL_SIGNAL cmdResp;
    OSAL_EVENT cmdReq;
    UINT32 patchNum;
    P_WMT_PATCH_INFO pWmtPatchInfo;
    struct wmt_rom_patch_info *pWmtRomPatchInfo[5];
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

typedef int ENUM_WMTDRV_TYPE_T; typedef size_t SIZE_T; typedef unsigned long ULONG;
#define WMTDRV_TYPE_ANT 5
#define MAX_PATCH_NUM 10
#define GFP_KERNEL 0
#define BIT(i) (1UL << (i))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define kcalloc(n,s,f) calloc((n),(s))
#define kfree free
static DEFINE_MUTEX(g_wmt_cmd_lock);
static bool g_wmt_cmd_in_progress;
static bool g_wmt_cmd_delivered;
static bool g_wmt_cmd_responded;
static P_WMT_PATCH_INFO pPatchInfo;
static UINT32 pAtchNum;
static DEFINE_MUTEX(g_patch_info_lock);
static unsigned long g_patch_info_seen;
static bool g_patch_info_ready;
static DEFINE_MUTEX(g_rom_patch_info_lock);
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

VOID wmt_lib_set_patch_num(UINT32 num)
{
	P_DEV_WMT pWmtDev = &gDevWmt;

	WRITE_ONCE(pWmtDev->patchNum, num);
}

VOID wmt_lib_set_patch_info(P_WMT_PATCH_INFO pPatchinfo)
{
	P_DEV_WMT pWmtDev = &gDevWmt;

	WRITE_ONCE(pWmtDev->pWmtPatchInfo, pPatchinfo);
}

P_WMT_PATCH_INFO wmt_lib_get_patch_info(VOID)
{
	/* Only a readiness marker; record readers use wmt_dev_get_patch_info(). */
	return READ_ONCE(gDevWmt.pWmtPatchInfo);
}

INT32 wmt_lib_set_rom_patch_info(struct wmt_rom_patch_info *PatchInfo, ENUM_WMTDRV_TYPE_T type)
{
	P_DEV_WMT pWmtDev = &gDevWmt;
	struct wmt_rom_patch_info *info;
	INT32 ret = 0;

	if (!PatchInfo || (UINT32)type >= WMTDRV_TYPE_ANT ||
	    !memchr(PatchInfo->patchName, '\0', sizeof(PatchInfo->patchName)))
		return -EINVAL;

	mutex_lock(&g_rom_patch_info_lock);
	/* Keep the first valid record for each ROM patch type. */
	if (pWmtDev->pWmtRomPatchInfo[type])
		goto out;

	info = kcalloc(1, sizeof(*info), GFP_KERNEL);
	if (!info) {
		ret = -ENOMEM;
		goto out;
	}

	osal_memcpy(info, PatchInfo, sizeof(*info));
	WRITE_ONCE(pWmtDev->pWmtRomPatchInfo[type], info);
out:
	mutex_unlock(&g_rom_patch_info_lock);
	return ret;
}

INT32 wmt_lib_get_rom_patch_info(SIZE_T type, PUINT8 name, PUINT8 address)
{
	struct wmt_rom_patch_info *info;
	INT32 ret = 0;

	if (type >= WMTDRV_TYPE_ANT || !name || !address)
		return -EINVAL;

	mutex_lock(&g_rom_patch_info_lock);
	info = gDevWmt.pWmtRomPatchInfo[type];
	if (!info) {
		ret = -ENOENT;
		goto out;
	}
	osal_memcpy(name, info->patchName, sizeof(info->patchName));
	osal_memcpy(address, info->addRess, sizeof(info->addRess));
out:
	mutex_unlock(&g_rom_patch_info_lock);
	return ret;
}

static VOID wmt_lib_rom_patch_info_free(VOID)
{
	INT32 i;

	mutex_lock(&g_rom_patch_info_lock);
	for (i = 0; i < WMTDRV_TYPE_ANT; i++) {
		kfree(gDevWmt.pWmtRomPatchInfo[i]);
		WRITE_ONCE(gDevWmt.pWmtRomPatchInfo[i], NULL);
	}
	mutex_unlock(&g_rom_patch_info_lock);
}

VOID wmt_dev_patch_info_free(VOID)
{
	mutex_lock(&g_patch_info_lock);
	wmt_lib_set_patch_info(NULL);
	wmt_lib_set_patch_num(0);
	g_patch_info_ready = false;
	g_patch_info_seen = 0;
	pAtchNum = 0;
	kfree(pPatchInfo);
	pPatchInfo = NULL;
	mutex_unlock(&g_patch_info_lock);
}

static INT32 wmt_dev_set_patch_num(ULONG num)
{
	INT32 ret = 0;
	P_WMT_PATCH_INFO info;

	if (!num || num > MAX_PATCH_NUM)
		return -EINVAL;

	mutex_lock(&g_patch_info_lock);
	if (pAtchNum) {
		ret = -EBUSY;
		goto out;
	}

	info = kcalloc(num, sizeof(*info), GFP_KERNEL);
	if (!info) {
		ret = -ENOMEM;
		goto out;
	}

	pPatchInfo = info;
	pAtchNum = num;
	wmt_lib_set_patch_num(pAtchNum);
out:
	mutex_unlock(&g_patch_info_lock);
	return ret;
}

static INT32 wmt_dev_set_patch_info(const WMT_PATCH_INFO *info)
{
	INT32 ret = 0;
	UINT32 seq = info->dowloadSeq;

	if (!memchr(info->patchName, '\0', sizeof(info->patchName)))
		return -EINVAL;

	mutex_lock(&g_patch_info_lock);
	if (!pPatchInfo) {
		ret = -ENOENT;
		goto out;
	}
	if (!seq || seq > pAtchNum) {
		ret = -EINVAL;
		goto out;
	}

	memcpy(&pPatchInfo[seq - 1], info, sizeof(*info));
	g_patch_info_seen |= BIT(seq - 1);
	/* Repeated records may update a slot, but cannot fill a missing slot. */
	if (g_patch_info_seen == BIT(pAtchNum) - 1) {
		g_patch_info_ready = true;
		wmt_lib_set_patch_info(pPatchInfo);
	}
out:
	mutex_unlock(&g_patch_info_lock);
	return ret;
}

INT32 wmt_dev_get_patch_info(SIZE_T sequence, PUINT8 name, PUINT8 address)
{
	INT32 ret = 0;
	P_WMT_PATCH_INFO info;

	if (!name || !address)
		return -EINVAL;

	mutex_lock(&g_patch_info_lock);
	if (!g_patch_info_ready) {
		ret = -ENOENT;
		goto out;
	}
	if (!sequence || sequence > pAtchNum) {
		ret = -EINVAL;
		goto out;
	}

	info = &pPatchInfo[sequence - 1];
	osal_memcpy(name, info->patchName, sizeof(info->patchName));
	osal_memcpy(address, info->addRess, sizeof(info->addRess));
out:
	mutex_unlock(&g_patch_info_lock);
	return ret;
}

static int legacy_startup_would_search(void)
{
UINT32 patch_num = gDevWmt.patchNum;
if (patch_num == 0 || wmt_lib_get_patch_info() == NULL)
    return 1;
return 0;
}

#define CHECK(value) do { if (!(value)) { \
    fprintf(stderr, "line %d: %s (case %d phase %d)\n", __LINE__, #value, scenario, phase); abort(); \
} } while (0)
static int phase;
static struct file owner;
static void on_event(void) {}
static void on_copy(void) {}
static void read_command(void)
{
    char buffer[256] = {0};
    CHECK(WMT_read(&owner, buffer, sizeof(buffer), NULL) > 0);
}
static void put_patch(unsigned sequence, const char *prefix)
{
    WMT_PATCH_INFO patch = {.dowloadSeq = sequence};
    snprintf((char *)patch.patchName, sizeof(patch.patchName), "%s%u.bin", prefix, sequence);
    CHECK(wmt_dev_set_patch_info(&patch) == 0);
}
static void put_rom(unsigned type, const char *prefix)
{
    struct wmt_rom_patch_info patch = {.type = type};
    snprintf((char *)patch.patchName, sizeof(patch.patchName), "%s%u.bin", prefix, type);
    CHECK(wmt_lib_set_rom_patch_info(&patch, type) == 0);
}
static void on_wait(void)
{
    if (phase && scenario == 0) {
        /* A's serial handler finishes after B queues, before reading B. */
        put_patch(2, "A");
        CHECK(wmt_lib_get_patch_info() != NULL);
        CHECK(wmt_dev_set_patch_num(2) == -EBUSY);
    }
    if (phase && scenario == 3) put_rom(4, "A");
    read_command();
    if (!phase) {
        if (scenario == 0 || scenario == 1 || scenario == 5) {
            CHECK(wmt_dev_set_patch_num(2) == 0);
            put_patch(1, "A");
            if (scenario != 0) put_patch(2, "A");
        }
        if (scenario == 3 || scenario == 4) put_rom(0, "A");
        if (scenario == 1 || scenario == 4) CHECK(WMT_write(&owner, "fail", 4, NULL) == 4);
        return;
    }
    if (scenario == 2) {
        CHECK(wmt_dev_set_patch_num(2) == 0);
        put_patch(1, "B"); put_patch(2, "B");
        /* A's old per-record setter has no identity and replaces B's slot. */
        put_patch(1, "A");
    }
    if (scenario == 4) put_rom(0, "B");
    CHECK(WMT_write(&owner, scenario == 0 ? "fail" : "ok", scenario == 0 ? 4 : 2, NULL) > 0);
}
int main(int argc, char **argv)
{
    CHECK(argc == 2); scenario = atoi(argv[1]); CHECK(scenario >= 0 && scenario <= 5);
    const char *request = scenario == 3 || scenario == 4 ? "srh_rom_patch" : (const char *)command;
    int result = wmt_ctrl_ul_cmd(&gDevWmt, (PUINT8)request);
    CHECK(result == (scenario == 1 || scenario == 4 ? -1 : -ETIMEDOUT));
    if (scenario == 1 || scenario == 5) {
        /* This is the exact selected-SoC startup cache gate from its source. */
        CHECK(legacy_startup_would_search() == 0);
    } else {
        phase = 1;
        CHECK(wmt_ctrl_ul_cmd(&gDevWmt, (PUINT8)request) == (scenario == 0 ? -1 : 0));
    }
    unsigned char name[256], address[4];
    if (scenario <= 2 || scenario == 5) {
        CHECK(wmt_dev_get_patch_info(1, name, address) == 0 && !strcmp((char *)name, "A1.bin"));
        CHECK(wmt_dev_get_patch_info(2, name, address) == 0);
        CHECK(!strcmp((char *)name, scenario == 2 ? "B2.bin" : "A2.bin"));
    } else {
        CHECK(wmt_lib_get_rom_patch_info(scenario == 3 ? 4 : 0, name, address) == 0);
        CHECK(!strcmp((char *)name, scenario == 3 ? "A4.bin" : "A0.bin"));
    }
    wmt_dev_patch_info_free(); wmt_lib_rom_patch_info_free();
    printf("{\"scenario\":%d,\"legacy_metadata_issue_observed\":true}\n", scenario);
    return 0;
}
