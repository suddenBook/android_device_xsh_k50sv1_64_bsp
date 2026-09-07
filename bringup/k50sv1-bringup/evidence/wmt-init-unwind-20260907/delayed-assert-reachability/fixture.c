
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef void VOID;
typedef int INT32;
typedef unsigned int UINT32;
typedef char UINT8;
typedef char *PINT8, *PUINT8;
typedef uintptr_t SIZE_T;
typedef unsigned long ULONG;
typedef int ENUM_WMTDRV_TYPE_T;
#define ASSERT_KEYWORD_LENGTH 20
#define STP_DBG_KEYWORD_SIZE 256
#define WMTDRV_TYPE_WMT 4
#define WMT_CTRL_TRG_ASSERT 1
#define DRV_STS_FUNC_ON 1
#define WMT_ERR_FUNC(...) ((void)0)
#define WMT_INFO_FUNC(...) ((void)0)
#define STP_DBG_PR_INFO(...) ((void)0)
#define osal_assert assert
#define osal_strlen strlen
#define osal_strchr strchr
#define osal_strncat strncat
#define osal_lock_sleepable_lock pthread_mutex_lock
#define osal_unlock_sleepable_lock pthread_mutex_unlock
#define DEFINE_SPINLOCK(name) pthread_mutex_t name = PTHREAD_MUTEX_INITIALIZER
#define spin_lock_irqsave(lock, flags) do { (flags)=0; assert(pthread_mutex_lock(lock)==0); } while(0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(flags); assert(pthread_mutex_unlock(lock)==0); } while(0)
struct work_struct { bool pending, running; };
struct assert_work_st {
	struct work_struct work;
	ENUM_WMTDRV_TYPE_T type;
	UINT32 reason;
	UINT8 keyword[ASSERT_KEYWORD_LENGTH];
};
static struct assert_work_st wmt_assert_work;
static DEFINE_SPINLOCK(g_wmt_assert_work_lock);
static bool g_wmt_assert_work_initialized = true;
static pthread_mutex_t work_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t assert_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    pthread_mutex_t lock;
    struct { UINT32 assert_from_host, drv_type, reason; } host_assert_info;
    char keyword[STP_DBG_KEYWORD_SIZE];
} cpupcr = {.lock = PTHREAD_MUTEX_INITIALIZER};
static typeof(cpupcr) *g_stp_dbg_cpupcr = &cpupcr;
typedef struct { SIZE_T ctrlId, au4CtrlData[3]; } WMT_CTRL_DATA, *P_WMT_CTRL_DATA;
static int chip_reset_only;
struct gate { pthread_mutex_t lock; pthread_cond_t cond; bool arrived, released; };
static struct gate blocked = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, false, false};
static int scenario;
static _Thread_local bool second_producer;
static UINT32 request_type[2], request_reason[2];
static char *request_keyword[2];
static void pause_callback(void)
{
    pthread_mutex_lock(&blocked.lock);
    blocked.arrived = true;
    pthread_cond_broadcast(&blocked.cond);
    while (!blocked.released) pthread_cond_wait(&blocked.cond, &blocked.lock);
    pthread_mutex_unlock(&blocked.lock);
}
static void await_callback(void)
{
    pthread_mutex_lock(&blocked.lock);
    while (!blocked.arrived) pthread_cond_wait(&blocked.cond, &blocked.lock);
    pthread_mutex_unlock(&blocked.lock);
}
static void release_callback(void)
{
    pthread_mutex_lock(&blocked.lock);
    blocked.released = true;
    pthread_cond_broadcast(&blocked.cond);
    pthread_mutex_unlock(&blocked.lock);
}
static int host_snprintf(char *buf, size_t length, const char *format, ...)
{
    if (second_producer && !(scenario & 1)) pause_callback();
    va_list args;
    va_start(args, format);
    int ret = vsnprintf(buf, length, format, args);
    va_end(args);
    return ret;
}
#define snprintf host_snprintf
static bool schedule_work(struct work_struct *work)
{
    pthread_mutex_lock(&work_lock);
    bool accepted = !work->pending;
    if (accepted) work->pending = true;
    pthread_mutex_unlock(&work_lock);
    return accepted;
}
static int wmt_lib_assert_lock_trylock(void) { return pthread_mutex_trylock(&assert_lock)==0; }
static void wmt_lib_assert_lock_release(void) { pthread_mutex_unlock(&assert_lock); }
static void wmt_core_set_coredump_state(int state) {}
static int wmt_dev_is_close(void) { return 0; }
static int mtk_wcn_stp_get_wmt_trg_assert(void) { return 0; }
static void mtk_wcn_stp_dbg_dump_package(void) {}
static void mtk_wcn_stp_set_wmt_trg_assert(int value) {}
static void mtk_wcn_stp_assert_flow_ctrl(int value) {}
static int mtk_wcn_stp_wmt_trg_assert(void)
{
    if (scenario & 1) pause_callback();
    return 0;
}
static INT32 wmt_ctrl_trg_assert(P_WMT_CTRL_DATA ctrl);
static int wmt_ctrl(P_WMT_CTRL_DATA ctrl) { return wmt_ctrl_trg_assert(ctrl); }
INT32 stp_dbg_set_host_assert_info(UINT32 drv_type, UINT32 reason, UINT32 en)
{
	osal_lock_sleepable_lock(&g_stp_dbg_cpupcr->lock);

	g_stp_dbg_cpupcr->host_assert_info.assert_from_host = en;
	g_stp_dbg_cpupcr->host_assert_info.drv_type = drv_type;
	g_stp_dbg_cpupcr->host_assert_info.reason = reason;

	osal_unlock_sleepable_lock(&g_stp_dbg_cpupcr->lock);

	return 0;
}

VOID stp_dbg_set_keyword(PINT8 keyword)
{
	osal_lock_sleepable_lock(&g_stp_dbg_cpupcr->lock);
	if (keyword != NULL) {
		if (osal_strlen(keyword) >= STP_DBG_KEYWORD_SIZE)
			STP_DBG_PR_INFO("Keyword over max size(%d)\n", STP_DBG_KEYWORD_SIZE);
		else if (osal_strchr(keyword, '<') != NULL || osal_strchr(keyword, '>') != NULL)
			STP_DBG_PR_INFO("Keyword has < or >, keywrod: %s\n", keyword);
		else
			osal_strncat(&g_stp_dbg_cpupcr->keyword[0], keyword, osal_strlen(keyword));
	} else {
		g_stp_dbg_cpupcr->keyword[0] = '\0';
	}
	osal_unlock_sleepable_lock(&g_stp_dbg_cpupcr->lock);
}

UINT32 wmt_lib_set_host_assert_info(UINT32 type, UINT32 reason, UINT32 en)
{
	return stp_dbg_set_host_assert_info(type, reason, en);
}

static INT32 wmt_ctrl_trg_assert(P_WMT_CTRL_DATA pWmtCtrlData)
{
	INT32 iRet = -1;

	ENUM_WMTDRV_TYPE_T drv_type;
	UINT32 reason = 0;
	PUINT8 keyword;

	drv_type = pWmtCtrlData->au4CtrlData[0];
	reason = pWmtCtrlData->au4CtrlData[1];
	keyword = (PUINT8) pWmtCtrlData->au4CtrlData[2];
	WMT_INFO_FUNC("wmt-ctrl:drv_type(%d),reason(%d),keyword(%s)\n", drv_type, reason, keyword);

	if (wmt_dev_is_close())
		WMT_INFO_FUNC("WMT is closing, don't trigger assert\n");
	else if (chip_reset_only == 1)
		WMT_INFO_FUNC("Do chip reset only, don't trigger assert\n");
	else if (mtk_wcn_stp_get_wmt_trg_assert() == 0) {
		mtk_wcn_stp_dbg_dump_package();
		mtk_wcn_stp_set_wmt_trg_assert(1);
		mtk_wcn_stp_assert_flow_ctrl(1);

		iRet = mtk_wcn_stp_wmt_trg_assert();
		if (iRet == 0) {
			wmt_lib_set_host_assert_info(drv_type, reason, 1);
			stp_dbg_set_keyword(keyword);
		}
	} else
		WMT_INFO_FUNC("do trigger assert & chip reset in stp noack\n");

	return 0;
}

INT32 wmt_lib_trigger_assert_keyword(ENUM_WMTDRV_TYPE_T type, UINT32 reason, PUINT8 keyword)
{
	INT32 iRet = -1;
	WMT_CTRL_DATA ctrlData;

	if (wmt_lib_assert_lock_trylock() == 0) {
		WMT_INFO_FUNC("Can't lock assert mutex which might be held by another trigger assert procedure.\n");
		return iRet;
	}

	wmt_core_set_coredump_state(DRV_STS_FUNC_ON);

	ctrlData.ctrlId = (SIZE_T) WMT_CTRL_TRG_ASSERT;
	ctrlData.au4CtrlData[0] = (SIZE_T) type;
	ctrlData.au4CtrlData[1] = (SIZE_T) reason;
	ctrlData.au4CtrlData[2] = (SIZE_T) keyword;

	iRet = wmt_ctrl(&ctrlData);
	if (iRet) {
		/* ERROR */
		WMT_ERR_FUNC
		    ("WMT-CORE: wmt_core_ctrl failed: type(%d), reason(%d), keyword(%s), iRet(%d)\n",
		     type, reason, keyword, iRet);
		osal_assert(0);
	}
	wmt_lib_assert_lock_release();

	return iRet;
}

static VOID wmt_lib_assert_work_cb(struct work_struct *work)
{
	struct assert_work_st *a = &wmt_assert_work;

	wmt_lib_trigger_assert_keyword(a->type, a->reason, a->keyword);
}

VOID wmt_lib_trigger_assert_keyword_delay(ENUM_WMTDRV_TYPE_T type, UINT32 reason, PUINT8 keyword)
{
	struct assert_work_st *a = &wmt_assert_work;
	ULONG flags;

	spin_lock_irqsave(&g_wmt_assert_work_lock, flags);
	if (!g_wmt_assert_work_initialized) {
		spin_unlock_irqrestore(&g_wmt_assert_work_lock, flags);
		return;
	}
	a->type = type;
	a->reason = reason;
	snprintf(a->keyword, sizeof(a->keyword), "%s", keyword);
	WMT_ERR_FUNC("Assert: type = %d, reason = %d, keyword = %s", type, reason, keyword);
	schedule_work(&(a->work));
	spin_unlock_irqrestore(&g_wmt_assert_work_lock, flags);
}

static void *publish_second(void *unused)
{
    second_producer = true;
    wmt_lib_trigger_assert_keyword_delay(request_type[1], request_reason[1], request_keyword[1]);
    return NULL;
}
static void *run_first(void *unused)
{
    pthread_mutex_lock(&work_lock);
    assert(wmt_assert_work.work.pending && !wmt_assert_work.work.running);
    /* process_one_work clears PENDING before invoking the callback. */
    wmt_assert_work.work.pending = false;
    wmt_assert_work.work.running = true;
    pthread_mutex_unlock(&work_lock);
    wmt_lib_assert_work_cb(&wmt_assert_work.work);
    pthread_mutex_lock(&work_lock);
    wmt_assert_work.work.running = false;
    pthread_mutex_unlock(&work_lock);
    return NULL;
}
int main(int argc, char **argv)
{
    assert(argc==2);
    scenario=atoi(argv[1]);
    if (scenario >= 2) {
        request_type[0]=request_type[1]=WMTDRV_TYPE_WMT;
        request_reason[0]=request_reason[1]=46;
        request_keyword[0]=request_keyword[1]="DEVAPC Violation";
    } else {
        request_type[0]=0; request_type[1]=3;
        request_reason[0]=111; request_reason[1]=222;
        request_keyword[0]="first-assert"; request_keyword[1]="second-assert";
    }
    wmt_lib_trigger_assert_keyword_delay(request_type[0], request_reason[0], request_keyword[0]);
    pthread_t worker, producer;
    if (!(scenario & 1)) {
        assert(pthread_create(&producer, NULL, publish_second, NULL)==0);
        await_callback();
        assert(pthread_create(&worker, NULL, run_first, NULL)==0);
        assert(pthread_join(worker, NULL)==0);
        release_callback();
        assert(pthread_join(producer, NULL)==0);
    } else {
        assert(pthread_create(&worker, NULL, run_first, NULL)==0);
        await_callback();
        assert(pthread_create(&producer, NULL, publish_second, NULL)==0);
        assert(pthread_join(producer, NULL)==0);
        release_callback();
        assert(pthread_join(worker, NULL)==0);
    }
    assert(wmt_assert_work.work.pending && !wmt_assert_work.work.running);
    bool coherent=false;
    for (unsigned int i=0; i<2; i++)
        coherent |= cpupcr.host_assert_info.drv_type==request_type[i]
            && cpupcr.host_assert_info.reason==request_reason[i]
            && strcmp(cpupcr.keyword,request_keyword[i])==0;
    printf("{\"scenario\":%d,\"actual_call_arguments\":%s,\"type\":%u,\"reason\":%u,\"keyword\":\"%s\",\"coherent_request\":%s,\"second_work_pending\":true}\n",
           scenario,scenario>=2?"true":"false",cpupcr.host_assert_info.drv_type,
           cpupcr.host_assert_info.reason,cpupcr.keyword,coherent?"true":"false");
    return coherent?0:1;
}
