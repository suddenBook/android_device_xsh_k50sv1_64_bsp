/* Host scheduling and allocator substitutes; pool, workers and teardown are extracted verbatim. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef void VOID;
typedef void *PVOID;
typedef int32_t INT32;
typedef uint32_t UINT32;
typedef unsigned long ULONG;
typedef size_t SIZE_T;
typedef atomic_int atomic_t;
typedef bool MTK_WCN_BOOL;
#define MTK_WCN_BOOL_FALSE false
#define MTK_WCN_BOOL_TRUE true
#define ATOMIC_INIT(value) (value)
#define atomic_set(p, value) atomic_store(p, value)
#define atomic_inc(p) ((void)atomic_fetch_add(p, 1))
#define atomic_dec(p) ((void)atomic_fetch_sub(p, 1))
#define atomic_read(p) atomic_load(p)
#define atomic_dec_and_test(p) (atomic_fetch_sub(p, 1) == 1)
#define READ_ONCE(value) __atomic_load_n(&(value), __ATOMIC_RELAXED)
#define WRITE_ONCE(value, data) __atomic_store_n(&(value), (data), __ATOMIC_RELAXED)
#define WMT_ERR_FUNC(...) ((void)0)
#define WMT_WARN_FUNC(...) ((void)0)
#define WMT_DBG_FUNC(...) ((void)0)
#define WMT_INFO_FUNC(...) ((void)0)
#define osal_assert assert
#define osal_sizeof sizeof
#define osal_strncpy strncpy
#define WMTDRV_TYPE_WIFI 3
#define WMT_STAT_RST_ON 0
#define WMTHWVER_MAX 8
#define WMT_CHIP_TYPE_SOC 1
#define UTC_SYNC_TIME 1000
#define MAX_FUNC_ON_TIME 1000
#define CFG_WMT_PS_SUPPORT 0
#define CFG_WMT_LTE_COEX_HANDLING 0
#define MTK_WCN_WMT_STP_EXP_SYMBOL_ABSTRACT 1
typedef int ENUM_WMT_CHIP_TYPE;

struct mutex { pthread_mutex_t native; bool initialized; };
#define DEFINE_MUTEX(name) struct mutex name = {PTHREAD_MUTEX_INITIALIZER, true}
#define DEFINE_SPINLOCK(name) DEFINE_MUTEX(name)
typedef struct { struct mutex lock; } OSAL_SLEEPABLE_LOCK, *P_OSAL_SLEEPABLE_LOCK;
typedef struct { pthread_mutex_t lock; pthread_cond_t cond; } wait_queue_head_t;
#define DECLARE_WAIT_QUEUE_HEAD(name) wait_queue_head_t name = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER}
typedef struct { UINT32 timeoutValue; atomic_int done; } OSAL_SIGNAL, *P_OSAL_SIGNAL;
typedef struct { wait_queue_head_t waitQueue; UINT32 timeoutValue; bool initialized; } OSAL_EVENT, *P_OSAL_EVENT;
struct work_struct { bool initialized, cancelled; };
typedef struct { PVOID timeoutHandler; ULONG timeroutHandlerData; bool initialized, stopped; } OSAL_TIMER;
struct host_task { pthread_t thread; pthread_mutex_t lock; pthread_cond_t cond; bool run, joined; atomic_int stop; };
typedef struct {
    struct host_task *pThread;
    PVOID pThreadFunc, pThreadData;
    char threadName[32];
} OSAL_THREAD, *P_OSAL_THREAD;

#define OSAL_OP_DATA_SIZE   8
#define OSAL_OP_BUF_SIZE    64
#define WMT_OP_BUF_SIZE (16)
typedef struct _OSAL_OP_DAT {
	UINT32 opId;		/* Event ID */
	UINT32 u4InfoBit;	/* Reserved */
	SIZE_T au4OpData[OSAL_OP_DATA_SIZE];	/* OP Data */
} OSAL_OP_DAT, *P_OSAL_OP_DAT;
typedef struct _OSAL_LXOP_ {
	OSAL_OP_DAT op;
	OSAL_SIGNAL signal;
	INT32 result;
	atomic_t ref_count;
	UINT32 wmt_state; /* WMT terminal state, protected by g_wmt_op_lock. */
	PVOID wmt_payload; /* Freed when the last WMT operation reference is dropped. */
} OSAL_OP, *P_OSAL_OP;
typedef struct _OSAL_LXOP_Q {
	OSAL_SLEEPABLE_LOCK sLock;
	UINT32 write;
	UINT32 read;
	UINT32 size;
	P_OSAL_OP queue[OSAL_OP_BUF_SIZE];
} OSAL_OP_Q, *P_OSAL_OP_Q;
typedef enum _ENUM_WMT_OPID_T {
	WMT_OPID_HIF_CONF = 0,
	WMT_OPID_PWR_ON = 1,
	WMT_OPID_PWR_OFF = 2,
	WMT_OPID_FUNC_ON = 3,
	WMT_OPID_FUNC_OFF = 4,
	WMT_OPID_REG_RW = 5,	/* TODO:[ChangeFeature][George] is this OP obsoleted? */
	WMT_OPID_EXIT = 6,
	WMT_OPID_PWR_SV = 7,
	WMT_OPID_DSNS = 8,
	WMT_OPID_LPBK = 9,
	WMT_OPID_CMD_TEST = 10,
	WMT_OPID_HW_RST = 11,
	WMT_OPID_SW_RST = 12,
	WMT_OPID_BAUD_RST = 13,
	WMT_OPID_STP_RST = 14,
	WMT_OPID_THERM_CTRL = 15,
	WMT_OPID_EFUSE_RW = 16,
	WMT_OPID_GPIO_CTRL = 17,
	WMT_OPID_SDIO_CTRL = 18,
	WMT_OPID_FW_COREDMP = 19,
	WMT_OPID_GPIO_STATE = 20,
	WMT_OPID_BGW_DS = 21,
	WMT_OPID_SET_MCU_CLK = 22,
	WMT_OPID_ADIE_LPBK_TEST = 23,
#ifdef CONFIG_MTK_COMBO_ANT
	WMT_OPID_ANT_RAM_DOWN = 24,
	WMT_OPID_ANT_RAM_STA_GET = 25,
#endif
#if CFG_WMT_LTE_COEX_HANDLING
	WMT_OPID_IDC_MSG_HANDLING = 26,
#endif
	WMT_OPID_TRIGGER_STP_ASSERT = 27,
	WMT_OPID_FLASH_PATCH_DOWN = 28,
	WMT_OPID_FLASH_PATCH_VER_GET = 29,
	WMT_OPID_UTC_TIME_SYNC = 30,
	WMT_OPID_FW_LOG_CTRL = 31,
	WMT_OPID_WLAN_PROBE = 32,
	WMT_OPID_WLAN_REMOVE = 33,
	WMT_OPID_GPS_MCU_CTRL = 34,
	WMT_OPID_TRY_PWR_OFF = 35,
	WMT_OPID_BLANK_STATUS_CTRL = 36,
	WMT_OPID_MET_CTRL = 37,
	WMT_OPID_GPS_SUSPEND = 38,
	WMT_OPID_RESUME_DUMP_INFO = 39,
	WMT_OPID_MAX
} ENUM_WMT_OPID_T, *P_ENUM_WMT_OPID_T;
enum wmt_op_state {
	WMT_OP_PENDING,
	WMT_OP_COMPLETED,
	WMT_OP_CANCELLED,
};

#define RB_LATEST(prb) ((prb)->write - 1)
#define RB_SIZE(prb) ((prb)->size)
#define RB_MASK(prb) (RB_SIZE(prb) - 1)
#define RB_COUNT(prb) ((prb)->write - (prb)->read)
#define RB_FULL(prb) (RB_COUNT(prb) >= RB_SIZE(prb))
#define RB_EMPTY(prb) ((prb)->write == (prb)->read)

#define RB_INIT(prb, qsize) \
do { \
	(prb)->read = (prb)->write = 0; \
	(prb)->size = (qsize); \
} while (0)

#define RB_PUT(prb, value) \
do { \
	if (!RB_FULL(prb)) { \
		(prb)->queue[(prb)->write & RB_MASK(prb)] = value; \
		++((prb)->write); \
	} \
	else { \
		osal_assert(!RB_FULL(prb)); \
	} \
} while (0)

#define RB_GET(prb, value) \
do { \
	if (!RB_EMPTY(prb)) { \
		value = (prb)->queue[(prb)->read & RB_MASK(prb)]; \
		++((prb)->read); \
		if (RB_EMPTY(prb)) { \
			(prb)->read = (prb)->write = 0; \
		} \
	} \
	else { \
		value = NULL; \
		osal_assert(!RB_EMPTY(prb)); \
	} \
} while (0)


static DEFINE_SPINLOCK(g_wmt_op_lock);
static DEFINE_MUTEX(g_wmt_op_pool_lock);
static DECLARE_WAIT_QUEUE_HEAD(g_wmt_op_pool_idle);
static atomic_t g_wmt_ops_checked_out = ATOMIC_INIT(0);
static bool g_wmt_op_pool_stopping = true;
static bool g_wmt_op_pool_initialized;
static bool g_wmt_worker_timer_initialized;
static bool g_wmt_utc_timer_initialized;
static bool g_wmt_core_initialized;
static bool g_wmt_resources_initialized;
static bool g_wmt_platform_initialized;
static bool g_wmt_ps_initialized;
static bool g_wmt_idc_initialized;
static DEFINE_SPINLOCK(g_wmt_assert_work_lock);
static bool g_wmt_assert_work_initialized;

typedef struct { int ldoStableTime, rstStableTime, onStableTime, offStableTime, rtcStableTime; } PWR_SEQ_TIME;
struct vendor_patch_table { char **active_version; void *patch; int num; };
typedef struct {
    OSAL_THREAD thread, worker_thread;
    OSAL_TIMER worker_timer, utc_sync_timer;
    struct work_struct wmtd_worker_thread_work, utcSyncWorker;
    int wmtd_op_history, worker_op_history, hw_ver;
    OSAL_EVENT rWmtdWq, rWmtdWorkerWq, rWmtRxWq, cmdReq;
    OSAL_SIGNAL cmdResp;
    OSAL_SLEEPABLE_LOCK psm_lock, idc_lock, wlan_lock, assert_lock, mpu_lock;
    OSAL_OP_Q rFreeOpQ, rActiveOpQ, rWorkerOpQ;
    OSAL_OP arQue[WMT_OP_BUF_SIZE];
    P_OSAL_OP pCurOP, pWorkerOP;
    struct { unsigned long data; } state;
    struct { void *fDrvRst[WMTDRV_TYPE_WIFI]; } rFdrvCb;
    struct { int cfgExist, co_clock_flag, pwr_on_ldo_slot, pwr_on_rst_slot,
                 pwr_on_on_slot, pwr_on_off_slot, pwr_on_rtc_slot; } rWmtGenConf;
    struct vendor_patch_table patch_table;
} DEV_WMT, *P_DEV_WMT;
static DEV_WMT gDevWmt;
static struct { struct work_struct work; } wmt_assert_work;
INT32 wmt_lib_init(VOID);
INT32 wmt_lib_deinit(VOID);
P_OSAL_OP wmt_lib_get_free_op(VOID);
static P_OSAL_OP wmt_lib_get_op(P_OSAL_OP_Q pOpQ);
static MTK_WCN_BOOL wmt_lib_put_op(P_OSAL_OP_Q pOpQ, P_OSAL_OP pOp);
static VOID wmt_lib_drain_op_queue(P_OSAL_OP_Q pOpQ);
static MTK_WCN_BOOL wmt_lib_queue_op(P_OSAL_OP pOp, bool worker);
INT32 wmt_lib_put_op_to_free_queue(P_OSAL_OP pOp);
PVOID wmt_lib_alloc_op_data(P_OSAL_OP pOp, SIZE_T size);
VOID wmt_lib_put_op_ref(P_OSAL_OP pOp);
MTK_WCN_BOOL wmt_lib_submit_op_result(P_OSAL_OP pOp, P_OSAL_OP_DAT result);
MTK_WCN_BOOL wmt_lib_put_act_op_result(P_OSAL_OP pOp, P_OSAL_OP_DAT result);
MTK_WCN_BOOL wmt_lib_put_act_op(P_OSAL_OP pOp);
MTK_WCN_BOOL wmt_lib_put_worker_op(P_OSAL_OP pOp);
static VOID wmt_lib_complete_op(P_OSAL_OP pOp, INT32 result);
static VOID wmt_lib_cancel_current_op(P_DEV_WMT pWmtDev);
static UINT32 wmt_lib_active_op_id(P_DEV_WMT pWmtDev, bool worker);
P_OSAL_OP wmt_lib_get_current_op(P_DEV_WMT pWmtDev);
INT32 wmt_lib_set_current_op(P_DEV_WMT pWmtDev, P_OSAL_OP pOp);
INT32 wmt_lib_set_worker_op(P_DEV_WMT pWmtDev, P_OSAL_OP pOp);
VOID wmt_lib_state_init(VOID);
UINT32 wmt_lib_wait_event_checker(P_OSAL_THREAD pThread);
UINT32 wmt_lib_worker_wait_event_checker(P_OSAL_THREAD pThread);
static INT32 wmtd_thread(void *pvData);
static INT32 wmtd_worker_thread(void *pvData);

/* The concurrent callback barrier is exercised by test_wmt_callback_lifetime.py. */
static void wmt_export_platform_bridge_unregister(void) {}

struct gate {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    bool enabled, arrived, released;
};
#define GATE_INIT {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, false, false, false}
static struct gate enqueue_gate = GATE_INIT, handler_gate = GATE_INIT, recycle_gate = GATE_INIT;
static struct gate idle_entered = GATE_INIT, stop_entered = GATE_INIT, pool_contended = GATE_INIT;
static struct gate worker_queued = GATE_INIT;
static atomic_int allow_regular, allow_worker, live_allocations, allocation_frees, clears;
static atomic_int worker_wakeups, signal_calls, destroyed_pool_locks;
static int fail_core_init, fail_plat_init, fail_worker_run;
static bool pause_wifi_dispatch, pause_worker;
static _Thread_local bool teardown_thread;

static void mark(struct gate *gate)
{
    pthread_mutex_lock(&gate->lock);
    gate->arrived = true;
    pthread_cond_broadcast(&gate->cond);
    pthread_mutex_unlock(&gate->lock);
}
static void await(struct gate *gate)
{
    pthread_mutex_lock(&gate->lock);
    while (!gate->arrived) pthread_cond_wait(&gate->cond, &gate->lock);
    pthread_mutex_unlock(&gate->lock);
}
static void release(struct gate *gate)
{
    pthread_mutex_lock(&gate->lock);
    gate->released = true;
    pthread_cond_broadcast(&gate->cond);
    pthread_mutex_unlock(&gate->lock);
}
static void pause_at(struct gate *gate)
{
    if (!gate->enabled) return;
    pthread_mutex_lock(&gate->lock);
    gate->arrived = true;
    pthread_cond_broadcast(&gate->cond);
    while (!gate->released) pthread_cond_wait(&gate->cond, &gate->lock);
    pthread_mutex_unlock(&gate->lock);
}
static void mutex_lock(struct mutex *lock)
{
    assert(lock->initialized);
    if (teardown_thread && lock == &g_wmt_op_pool_lock) {
        int ret = pthread_mutex_trylock(&lock->native);
        if (!ret) return;
        assert(ret == EBUSY);
        mark(&pool_contended);
    }
    assert(pthread_mutex_lock(&lock->native) == 0);
}
static void mutex_unlock(struct mutex *lock) { assert(pthread_mutex_unlock(&lock->native) == 0); }
#define spin_lock_irqsave(lock, flags) do { (flags) = 0; mutex_lock(lock); } while (0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(flags); mutex_unlock(lock); } while (0)
static void wake_up(wait_queue_head_t *queue)
{
    pthread_mutex_lock(&queue->lock);
    pthread_cond_broadcast(&queue->cond);
    pthread_mutex_unlock(&queue->lock);
}
#define wait_event(queue, condition) do { \
    pthread_mutex_lock(&(queue).lock); mark(&idle_entered); \
    while (!(condition)) pthread_cond_wait(&(queue).cond, &(queue).lock); \
    pthread_mutex_unlock(&(queue).lock); \
} while (0)
static void *osal_malloc(SIZE_T size)
{
    void *pointer = malloc(size);
    assert(pointer);
    atomic_inc(&live_allocations);
    return pointer;
}
static void osal_free(PVOID pointer)
{
    if (!pointer) return;
    assert(atomic_fetch_sub(&live_allocations, 1) > 0);
    atomic_inc(&allocation_frees);
    free(pointer);
}
static void *osal_memset(void *dest, int byte, size_t size)
{
    if (dest == &gDevWmt) {
        assert(size == sizeof(gDevWmt));
        assert(atomic_read(&g_wmt_ops_checked_out) == 0);
        assert(atomic_read(&live_allocations) == 0);
        atomic_inc(&clears);
    }
    return memset(dest, byte, size);
}
static void osal_sleepable_lock_init(P_OSAL_SLEEPABLE_LOCK lock)
{ assert(pthread_mutex_init(&lock->lock.native, NULL) == 0); lock->lock.initialized = true; }
static void osal_sleepable_lock_deinit(P_OSAL_SLEEPABLE_LOCK lock)
{
    bool pool = lock == &gDevWmt.rFreeOpQ.sLock || lock == &gDevWmt.rActiveOpQ.sLock ||
                lock == &gDevWmt.rWorkerOpQ.sLock;
    if (pool) {
        assert(lock->lock.initialized);
        assert(atomic_read(&g_wmt_ops_checked_out) == 0);
        atomic_inc(&destroyed_pool_locks);
    }
    assert(lock->lock.initialized);
    assert(pthread_mutex_destroy(&lock->lock.native) == 0);
    lock->lock.initialized = false;
}
static int osal_unlock_sleepable_lock(P_OSAL_SLEEPABLE_LOCK lock)
{
    mutex_unlock(&lock->lock);
    if (lock == &gDevWmt.rFreeOpQ.sLock) pause_at(&recycle_gate);
    return 0;
}
static void osal_event_init(P_OSAL_EVENT event)
{
    pthread_mutex_init(&event->waitQueue.lock, NULL);
    pthread_cond_init(&event->waitQueue.cond, NULL);
    event->initialized = true;
}
static void osal_event_deinit(P_OSAL_EVENT event)
{
    if (!event->initialized) return;
    assert(pthread_mutex_destroy(&event->waitQueue.lock) == 0);
    assert(pthread_cond_destroy(&event->waitQueue.cond) == 0);
    event->initialized = false;
}
static void osal_trigger_event(P_OSAL_EVENT event)
{
    assert(event->initialized);
    if (event == &gDevWmt.rWmtdWq) pause_at(&enqueue_gate);
    else if (event == &gDevWmt.rWmtdWorkerWq) {
        atomic_inc(&worker_wakeups);
        mark(&worker_queued);
    }
    wake_up(&event->waitQueue);
}
static void *thread_start(void *input)
{
    P_OSAL_THREAD thread = input;
    struct host_task *task = thread->pThread;
    pthread_mutex_lock(&task->lock);
    while (!task->run && !atomic_read(&task->stop)) pthread_cond_wait(&task->cond, &task->lock);
    bool run = task->run;
    pthread_mutex_unlock(&task->lock);
    if (run) ((INT32 (*)(PVOID))thread->pThreadFunc)(thread->pThreadData);
    return NULL;
}
static int osal_thread_create(P_OSAL_THREAD thread)
{
    struct host_task *task = calloc(1, sizeof(*task));
    assert(task);
    pthread_mutex_init(&task->lock, NULL);
    pthread_cond_init(&task->cond, NULL);
    thread->pThread = task;
    return pthread_create(&task->thread, NULL, thread_start, thread);
}
static int osal_thread_run(P_OSAL_THREAD thread)
{
    if (fail_worker_run && thread == &gDevWmt.worker_thread) return -1;
    pthread_mutex_lock(&thread->pThread->lock);
    thread->pThread->run = true;
    pthread_cond_broadcast(&thread->pThread->cond);
    pthread_mutex_unlock(&thread->pThread->lock);
    return 0;
}
static int osal_thread_should_stop(P_OSAL_THREAD thread) { return atomic_read(&thread->pThread->stop); }
static int osal_thread_wait_for_event(P_OSAL_THREAD thread, P_OSAL_EVENT event,
                                    UINT32 (*checker)(P_OSAL_THREAD))
{
    bool worker = thread == &gDevWmt.worker_thread;
    P_OSAL_OP_Q queue = worker ? &gDevWmt.rWorkerOpQ : &gDevWmt.rActiveOpQ;
    pthread_mutex_lock(&event->waitQueue.lock);
    while (!osal_thread_should_stop(thread)) {
        bool ready = false;
        if (atomic_read(worker ? &allow_worker : &allow_regular)) {
            /* Serialize the host predicate with ring mutation to model a kernel waitqueue read. */
            mutex_lock(&queue->sLock.lock);
            ready = checker(thread);
            mutex_unlock(&queue->sLock.lock);
        }
        if (ready) break;
        pthread_cond_wait(&event->waitQueue.cond, &event->waitQueue.lock);
    }
    pthread_mutex_unlock(&event->waitQueue.lock);
    return 0;
}
static int osal_thread_stop(P_OSAL_THREAD thread)
{
    struct host_task *task = thread->pThread;
    mark(&stop_entered);
    if (!task) return 0;
    assert(!task->joined);
    atomic_set(&task->stop, 1);
    pthread_mutex_lock(&task->lock);
    pthread_cond_broadcast(&task->cond);
    pthread_mutex_unlock(&task->lock);
    OSAL_EVENT *event = thread == &gDevWmt.thread ? &gDevWmt.rWmtdWq : &gDevWmt.rWmtdWorkerWq;
    if (event->initialized) wake_up(&event->waitQueue);
    assert(pthread_join(task->thread, NULL) == 0);
    task->joined = true;
    return 0;
}
static int osal_thread_destroy(P_OSAL_THREAD thread)
{
    if (!thread->pThread) return 0;
    /* Production destroy performs the single join and clears the handle. */
    assert(osal_thread_stop(thread) == 0);
    pthread_mutex_destroy(&thread->pThread->lock);
    pthread_cond_destroy(&thread->pThread->cond);
    free(thread->pThread);
    thread->pThread = NULL;
    return 0;
}
static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t signal_cond = PTHREAD_COND_INITIALIZER;
static void osal_signal_init(P_OSAL_SIGNAL signal) { atomic_set(&signal->done, 0); }
static void osal_signal_deinit(P_OSAL_SIGNAL signal) { signal->timeoutValue = 0; }
static int osal_op_is_wait_for_signal(P_OSAL_OP operation) { return operation->signal.timeoutValue != 0; }
static void osal_op_raise_signal(P_OSAL_OP operation, int result)
{
    operation->result = result;
    pthread_mutex_lock(&signal_lock);
    atomic_set(&operation->signal.done, 1);
    atomic_inc(&signal_calls);
    pthread_cond_broadcast(&signal_cond);
    pthread_mutex_unlock(&signal_lock);
}
static int osal_wait_for_signal_timeout(P_OSAL_SIGNAL signal, P_OSAL_THREAD thread)
{
    struct timespec end;
    clock_gettime(CLOCK_REALTIME, &end);
    end.tv_nsec += (long)signal->timeoutValue * 1000000;
    end.tv_sec += end.tv_nsec / 1000000000;
    end.tv_nsec %= 1000000000;
    pthread_mutex_lock(&signal_lock);
    while (!atomic_read(&signal->done)) {
        int ret = pthread_cond_timedwait(&signal_cond, &signal_lock, &end);
        if (ret == ETIMEDOUT) break;
        assert(ret == 0);
    }
    int done = atomic_read(&signal->done);
    pthread_mutex_unlock(&signal_lock);
    return done;
}
static int wmt_core_opid(P_OSAL_OP_DAT data)
{
    if (data->opId == WMT_OPID_FUNC_ON) {
        if (pause_wifi_dispatch) pause_at(&handler_gate);
        P_OSAL_OP operation = wmt_lib_get_current_op(&gDevWmt);
        WRITE_ONCE(data->opId, WMT_OPID_WLAN_PROBE);
        return wmt_lib_put_worker_op(operation) ? 0 : -4;
    }
    if (pause_worker && data->opId == WMT_OPID_WLAN_PROBE) pause_at(&handler_gate);
    memset((void *)data->au4OpData[0], 0x6b, 32);
    return 0;
}
static int mtk_wcn_stp_coredump_start_get(void) { return 0; }
static int wmt_detect_get_chip_type(void) { return WMT_CHIP_TYPE_SOC; }
static int wmt_conf_read_file(void) { return 0; }
static int wmt_conf_deinit(void) { return 0; }
static int wmt_core_init(void) { return fail_core_init ? -1 : 0; }
static int wmt_core_deinit(void) { return 0; }
static int wmt_plat_init(PWR_SEQ_TIME *sequence, int flags) { return fail_plat_init ? -1 : 0; }
static int wmt_plat_deinit(void) { return 0; }
static int wmt_plat_soc_co_clock_flag_get(void) { return 0; }
static void osal_op_history_init(int *history, int count) { *history = count; }
static void osal_op_history_deinit(int *history) { *history = 0; }
static void osal_op_history_save(int *history, P_OSAL_OP operation) { (void)history; }
static void osal_opq_dump(char *name, P_OSAL_OP_Q queue) { (void)name; }
static void wmt_lib_print_wmtd_op_history(void) {}
static void wmt_lib_print_worker_op_history(void) {}
static void wmt_lib_rom_patch_info_free(void) {}
/* Broker behavior is covered by test_wmt_command_v2.py. */
static void wmt_lib_cmd_start(void) {}
static void wmt_lib_cmd_shutdown(void) {}
static void wmt_dev_patch_info_free(void)
{
    assert(!gDevWmt.thread.pThread && !gDevWmt.worker_thread.pThread);
    assert(atomic_read(&g_wmt_ops_checked_out) == 0);
}
static void mtk_wcn_wmt_system_state_reset(void) {}
#define osal_test_bit(bit, state) (((state)->data >> (bit)) & 1)
#define wmt_plat_irq_cb_reg(callback) ((void)0)
#define wmt_plat_aif_cb_reg(callback) ((void)0)
#define wmt_plat_func_ctrl_cb_reg(callback) ((void)0)
#define wmt_plat_deep_idle_ctrl_cb_reg(callback) ((void)0)
#define WMT_STEP_DEINIT_FUNC() ((void)0)
#define INIT_WORK(work, callback) ((work)->initialized = true)
static void wmt_lib_wmtd_worker_thread_timeout_handler(ULONG data) {}
static void wmt_lib_utc_sync_timeout_handler(ULONG data) {}
static void osal_timer_create(OSAL_TIMER *timer) { timer->initialized = true; }
static void osal_timer_start(OSAL_TIMER *timer, UINT32 duration) { assert(timer->initialized); }
static void osal_timer_stop(OSAL_TIMER *timer) { assert(timer->initialized); }
static void osal_timer_stop_sync(OSAL_TIMER *timer) { assert(timer->initialized); timer->stopped = true; }
static void cancel_work_sync(struct work_struct *work)
{
    assert(work->initialized);
    OSAL_TIMER *timer = work == &gDevWmt.utcSyncWorker ? &gDevWmt.utc_sync_timer : &gDevWmt.worker_timer;
    if (work != &wmt_assert_work.work) assert(timer->stopped);
    work->cancelled = true;
}

INT32 wmt_lib_init(VOID)
{
	INT32 iRet;
	UINT32 i;
	P_DEV_WMT pDevWmt;
	P_OSAL_THREAD pThread;
	P_OSAL_THREAD pWorkerThread;
	ENUM_WMT_CHIP_TYPE chip_type;
	ULONG flags;

	/* create->init->start */
	/* 1. create: static allocation with zero initialization */
	pDevWmt = &gDevWmt;
	osal_memset(&gDevWmt, 0, sizeof(gDevWmt));
	if (wmt_detect_get_chip_type() == WMT_CHIP_TYPE_SOC) {
		iRet = wmt_conf_read_file();
		if (iRet) {
			WMT_ERR_FUNC("read wmt config file fail(%d)\n", iRet);
			return -1;
		}
	}
	osal_op_history_init(&pDevWmt->wmtd_op_history, 16);
	osal_op_history_init(&pDevWmt->worker_op_history, 8);

	pThread = &gDevWmt.thread;

	/* Create mtk_wmtd thread */
	osal_strncpy(pThread->threadName, "mtk_wmtd", sizeof(pThread->threadName));
	pThread->pThreadData = (PVOID) pDevWmt;
	pThread->pThreadFunc = (PVOID) wmtd_thread;
	iRet = osal_thread_create(pThread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_create(0x%p) fail(%d)\n", pThread, iRet);
		return -2;
	}

	/* create worker timer */
	gDevWmt.worker_timer.timeoutHandler = wmt_lib_wmtd_worker_thread_timeout_handler;
	gDevWmt.worker_timer.timeroutHandlerData = 0;
	osal_timer_create(&gDevWmt.worker_timer);
	pWorkerThread = &gDevWmt.worker_thread;
	INIT_WORK(&pDevWmt->wmtd_worker_thread_work, wmt_lib_wmtd_worker_thread_work_handler);
	g_wmt_worker_timer_initialized = true;

	/* Create wmtd_worker thread */
	osal_strncpy(pWorkerThread->threadName, "mtk_wmtd_worker", sizeof(pWorkerThread->threadName));
	pWorkerThread->pThreadData = (PVOID) pDevWmt;
	pWorkerThread->pThreadFunc = (PVOID) wmtd_worker_thread;
	iRet = osal_thread_create(pWorkerThread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_create(0x%p) fail(%d)\n", pWorkerThread, iRet);
		return -2;
	}

	/* init timer */
	pDevWmt->utc_sync_timer.timeoutHandler = wmt_lib_utc_sync_timeout_handler;
	osal_timer_create(&pDevWmt->utc_sync_timer);
	INIT_WORK(&pDevWmt->utcSyncWorker, wmt_lib_utc_sync_worker_handler);
	g_wmt_utc_timer_initialized = true;
	osal_timer_start(&pDevWmt->utc_sync_timer, UTC_SYNC_TIME);

	/* 2. initialize */
	/* Initialize wmt_core */

	iRet = wmt_core_init();
	if (iRet) {
		WMT_ERR_FUNC("wmt_core_init() fail(%d)\n", iRet);
		return -1;
	}

	g_wmt_core_initialized = true;

	/* Initialize WMTd Thread Information: Thread */
	osal_event_init(&pDevWmt->rWmtdWq);
	osal_event_init(&pDevWmt->rWmtdWorkerWq);
	osal_sleepable_lock_init(&pDevWmt->psm_lock);
	osal_sleepable_lock_init(&pDevWmt->idc_lock);
	osal_sleepable_lock_init(&pDevWmt->wlan_lock);
	osal_sleepable_lock_init(&pDevWmt->assert_lock);
	osal_sleepable_lock_init(&pDevWmt->mpu_lock);
	osal_sleepable_lock_init(&pDevWmt->rActiveOpQ.sLock);
	osal_sleepable_lock_init(&pDevWmt->rWorkerOpQ.sLock);
	osal_sleepable_lock_init(&pDevWmt->rFreeOpQ.sLock);
	pDevWmt->state.data = 0;

	/* Initialize op queue */
	RB_INIT(&pDevWmt->rFreeOpQ, WMT_OP_BUF_SIZE);
	RB_INIT(&pDevWmt->rActiveOpQ, WMT_OP_BUF_SIZE);
	RB_INIT(&pDevWmt->rWorkerOpQ, WMT_OP_BUF_SIZE);
	/* Put all to free Q */
	for (i = 0; i < WMT_OP_BUF_SIZE; i++) {
		osal_signal_init(&(pDevWmt->arQue[i].signal));
		wmt_lib_put_op(&pDevWmt->rFreeOpQ, &(pDevWmt->arQue[i]));
	}
	mutex_lock(&g_wmt_op_pool_lock);
	g_wmt_op_pool_initialized = true;
	mutex_unlock(&g_wmt_op_pool_lock);

	/* initialize stp resources */
	osal_event_init(&pDevWmt->rWmtRxWq);

	/*function driver callback */
	for (i = 0; i < WMTDRV_TYPE_WIFI; i++)
		pDevWmt->rFdrvCb.fDrvRst[i] = NULL;

	pDevWmt->hw_ver = WMTHWVER_MAX;
	WMT_DBG_FUNC("***********Init, hw->ver = %x\n", pDevWmt->hw_ver);

	/* TODO:[FixMe][GeorgeKuo]: wmt_lib_conf_init */
	/* initialize default configurations */
	/* i4Result = wmt_lib_conf_init(VOID); */
	/* WMT_WARN_FUNC("wmt_drv_conf_init(%d)\n", i4Result); */

	osal_signal_init(&pDevWmt->cmdResp);
	osal_event_init(&pDevWmt->cmdReq);
	/* Embedded OSAL primitives cannot fail for these non-NULL arguments. */
	g_wmt_resources_initialized = true;
	/* initialize platform resources */

	if (gDevWmt.rWmtGenConf.cfgExist != 0) {
		PWR_SEQ_TIME pwrSeqTime;

		pwrSeqTime.ldoStableTime = gDevWmt.rWmtGenConf.pwr_on_ldo_slot;
		pwrSeqTime.rstStableTime = gDevWmt.rWmtGenConf.pwr_on_rst_slot;
		pwrSeqTime.onStableTime = gDevWmt.rWmtGenConf.pwr_on_on_slot;
		pwrSeqTime.offStableTime = gDevWmt.rWmtGenConf.pwr_on_off_slot;
		pwrSeqTime.rtcStableTime = gDevWmt.rWmtGenConf.pwr_on_rtc_slot;
		WMT_INFO_FUNC("set pwr on seq par to hw conf\n");
		WMT_INFO_FUNC("ldo(%d)rst(%d)on(%d)off(%d)rtc(%d)\n", pwrSeqTime.ldoStableTime,
				pwrSeqTime.rstStableTime, pwrSeqTime.onStableTime,
				pwrSeqTime.offStableTime, pwrSeqTime.rtcStableTime);
		iRet = wmt_plat_init(&pwrSeqTime, gDevWmt.rWmtGenConf.co_clock_flag & 0x0f);
	} else {
		WMT_ERR_FUNC("no pwr on seq and clk par found\n");
		iRet = wmt_plat_init(NULL, 0);
	}
	chip_type = wmt_detect_get_chip_type();
	if (chip_type == WMT_CHIP_TYPE_SOC)
		gDevWmt.rWmtGenConf.co_clock_flag = wmt_plat_soc_co_clock_flag_get();

	if (iRet) {
		WMT_ERR_FUNC("wmt_plat_init() fail(%d)\n", iRet);
		return -3;
	}
	g_wmt_platform_initialized = true;

#if CFG_WMT_PS_SUPPORT
	iRet = wmt_lib_ps_init();
	if (iRet) {
		WMT_ERR_FUNC("wmt_lib_ps_init() fail(%d)\n", iRet);
		return -4;
	}
	g_wmt_ps_initialized = true;
#endif

	/* 3. start: start running mtk_wmtd */
	iRet = osal_thread_run(pThread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_run(wmtd 0x%p) fail(%d)\n", pThread, iRet);
		return -5;
	}

	iRet = osal_thread_run(pWorkerThread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_run(worker 0x%p) fail(%d)\n", pWorkerThread, iRet);
		return -5;
	}
	/*4. register irq callback to WMT-PLAT */
	wmt_plat_irq_cb_reg(wmt_lib_ps_irq_cb);
	/*5. register audio if control callback to WMT-PLAT */
	wmt_plat_aif_cb_reg(wmt_lib_set_aif);
	/*6. register function control callback to WMT-PLAT */
	wmt_plat_func_ctrl_cb_reg(mtk_wcn_wmt_func_ctrl_for_plat);

	wmt_plat_deep_idle_ctrl_cb_reg(mtk_wcn_consys_stp_btif_dpidle_ctrl);
	/*7 reset gps/bt state */

	mtk_wcn_wmt_system_state_reset();

#ifndef MTK_WCN_WMT_STP_EXP_SYMBOL_ABSTRACT
	mtk_wcn_wmt_exp_init();
#endif

#if CFG_WMT_LTE_COEX_HANDLING
	/* IDC registration is optional; only unregister a successful registration. */
	g_wmt_idc_initialized = wmt_idc_init() == 0;
#endif

	INIT_WORK(&(wmt_assert_work.work), wmt_lib_assert_work_cb);
	spin_lock_irqsave(&g_wmt_assert_work_lock, flags);
	g_wmt_assert_work_initialized = true;
	spin_unlock_irqrestore(&g_wmt_assert_work_lock, flags);

	wmt_lib_cmd_start();
	/* Failed initialization never exposes partially initialized queue storage. */
	mutex_lock(&g_wmt_op_pool_lock);
	g_wmt_op_pool_stopping = false;
	mutex_unlock(&g_wmt_op_pool_lock);
	WMT_DBG_FUNC("init success\n");
	return 0;
}

INT32 wmt_lib_deinit(VOID)
{
	INT32 iRet;
	P_DEV_WMT pDevWmt;
	INT32 i;
	INT32 iResult;
	ULONG flags;
	bool op_pool_initialized;
	bool assert_work_initialized;
	struct vendor_patch_table *table = &(gDevWmt.patch_table);

	/* Also covers cleanup after a partially completed wmt_lib_init. */
	wmt_export_platform_bridge_unregister();
	wmt_lib_cmd_shutdown();

	pDevWmt = &gDevWmt;
	iResult = 0;

	/* Serialize closure with checkout, enqueue and its worker wakeup. */
	mutex_lock(&g_wmt_op_pool_lock);
	g_wmt_op_pool_stopping = true;
	op_pool_initialized = g_wmt_op_pool_initialized;
	mutex_unlock(&g_wmt_op_pool_lock);

	/* No delayed assertion can be published after its work is joined. */
	spin_lock_irqsave(&g_wmt_assert_work_lock, flags);
	assert_work_initialized = g_wmt_assert_work_initialized;
	g_wmt_assert_work_initialized = false;
	spin_unlock_irqrestore(&g_wmt_assert_work_lock, flags);

	/*
	 * destroy joins even a created-but-not-started thread and clears its handle.
	 * Calling stop first would leave a stale handle for a second kthread_stop.
	 */
	iRet = osal_thread_destroy(&pDevWmt->thread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_destroy(wmtd) fail(%d)\n", iRet);
		iResult += 16;
	}
	iRet = osal_thread_destroy(&pDevWmt->worker_thread);
	if (iRet) {
		WMT_ERR_FUNC("osal_thread_destroy(worker) fail(%d)\n", iRet);
		iResult += 32;
	}

	/* Neither timer may schedule work against gDevWmt after it is cleared. */
	if (g_wmt_worker_timer_initialized)
		osal_timer_stop_sync(&pDevWmt->worker_timer);
	if (g_wmt_utc_timer_initialized)
		osal_timer_stop_sync(&pDevWmt->utc_sync_timer);

	/* Stopped workers leave their queued references for teardown to finish. */
	wmt_lib_drain_op_queue(&pDevWmt->rActiveOpQ);
	wmt_lib_drain_op_queue(&pDevWmt->rWorkerOpQ);
	if (g_wmt_worker_timer_initialized) {
		cancel_work_sync(&pDevWmt->wmtd_worker_thread_work);
		g_wmt_worker_timer_initialized = false;
	}
	if (g_wmt_utc_timer_initialized) {
		cancel_work_sync(&pDevWmt->utcSyncWorker);
		g_wmt_utc_timer_initialized = false;
	}
	if (assert_work_initialized)
		cancel_work_sync(&wmt_assert_work.work);

	/* Includes pre-submit borrowers and senders still copying completed data. */
	wait_event(g_wmt_op_pool_idle, atomic_read(&g_wmt_ops_checked_out) == 0);
	mutex_lock(&g_wmt_op_pool_lock);
	g_wmt_op_pool_initialized = false;
	mutex_unlock(&g_wmt_op_pool_lock);

	osal_op_history_deinit(&pDevWmt->wmtd_op_history);
	osal_op_history_deinit(&pDevWmt->worker_op_history);

#if CFG_WMT_LTE_COEX_HANDLING
	if (g_wmt_idc_initialized) {
		wmt_idc_deinit();
		g_wmt_idc_initialized = false;
	}
#endif
#if CFG_WMT_PS_SUPPORT
	if (g_wmt_ps_initialized) {
		iRet = wmt_lib_ps_deinit();
		if (iRet) {
			WMT_ERR_FUNC("wmt_lib_ps_deinit fail(%d)\n", iRet);
			iResult += 2;
		}
		g_wmt_ps_initialized = false;
	}
#endif
	if (g_wmt_platform_initialized) {
		iRet = wmt_plat_deinit();
		if (iRet) {
			WMT_ERR_FUNC("wmt_plat_deinit fail(%d)\n", iRet);
			iResult += 4;
		}
		g_wmt_platform_initialized = false;
	}

	if (g_wmt_resources_initialized) {
		osal_event_deinit(&pDevWmt->cmdReq);
		osal_signal_deinit(&pDevWmt->cmdResp);
		osal_event_deinit(&pDevWmt->rWmtRxWq);
		osal_sleepable_lock_deinit(&pDevWmt->mpu_lock);
		osal_sleepable_lock_deinit(&pDevWmt->idc_lock);
		osal_sleepable_lock_deinit(&pDevWmt->wlan_lock);
		osal_sleepable_lock_deinit(&pDevWmt->assert_lock);
		osal_sleepable_lock_deinit(&pDevWmt->psm_lock);
		osal_event_deinit(&pDevWmt->rWmtdWq);
		osal_event_deinit(&pDevWmt->rWmtdWorkerWq);
		g_wmt_resources_initialized = false;
	}
	if (op_pool_initialized) {
		for (i = 0; i < WMT_OP_BUF_SIZE; i++)
			osal_signal_deinit(&(pDevWmt->arQue[i].signal));
		osal_sleepable_lock_deinit(&pDevWmt->rFreeOpQ.sLock);
		osal_sleepable_lock_deinit(&pDevWmt->rActiveOpQ.sLock);
		osal_sleepable_lock_deinit(&pDevWmt->rWorkerOpQ.sLock);
	}

	/* The consuming wmtd operation has returned before its metadata is freed. */
	wmt_dev_patch_info_free();
	wmt_lib_rom_patch_info_free();
	if (g_wmt_core_initialized) {
		iRet = wmt_core_deinit();
		if (iRet) {
			WMT_ERR_FUNC("wmt_core_deinit fail(%d)\n", iRet);
			iResult += 8;
		}
		g_wmt_core_initialized = false;
	}
	if (pDevWmt->rWmtGenConf.cfgExist) {
		iRet = wmt_conf_deinit();
		if (iRet) {
			WMT_ERR_FUNC("wmt_conf_deinit fail(%d)\n", iRet);
			iResult += 64;
		}
	}

	/* These allocations belong to gDevWmt and must be freed before clearing it. */
	if (table->active_version != NULL) {
		for (i = 0; i < table->num; i++) {
			if (table->active_version[i])
				osal_free(table->active_version[i]);
		}
		osal_free(table->active_version);
	}
	osal_free(table->patch);
	osal_memset(&gDevWmt, 0, sizeof(gDevWmt));

	return iResult;
}

P_OSAL_OP wmt_lib_get_free_op(VOID)
{
	P_OSAL_OP pOp = NULL;
	P_DEV_WMT pDevWmt = &gDevWmt;

	osal_assert(pDevWmt);
	mutex_lock(&g_wmt_op_pool_lock);
	if (!g_wmt_op_pool_stopping) {
		pOp = wmt_lib_get_op(&pDevWmt->rFreeOpQ);
		if (pOp) {
			osal_memset(pOp, 0, osal_sizeof(OSAL_OP));
			atomic_inc(&g_wmt_ops_checked_out);
		}
	}
	mutex_unlock(&g_wmt_op_pool_lock);
	return pOp;
}

static P_OSAL_OP wmt_lib_get_op(P_OSAL_OP_Q pOpQ)
{
	P_OSAL_OP pOp;

	if (pOpQ == NULL) {
		WMT_ERR_FUNC("pOpQ = NULL\n");
		osal_assert(pOpQ);
		return NULL;
	}

	mutex_lock(&pOpQ->sLock.lock);

	/* acquire lock success */
	RB_GET(pOpQ, pOp);
	osal_unlock_sleepable_lock(&pOpQ->sLock);

	if (pOp == NULL) {
		UINT32 opId = wmt_lib_active_op_id(&gDevWmt, false);

		WMT_WARN_FUNC("RB_GET(%p) return NULL\n", pOpQ);
		if (opId != (UINT32)-1)
			WMT_WARN_FUNC("Current opId (%d)\n", opId);

		wmt_lib_print_wmtd_op_history();
		wmt_lib_print_worker_op_history();
		osal_opq_dump("FreeOpQ", &gDevWmt.rFreeOpQ);
		osal_opq_dump("ActiveOpQ", &gDevWmt.rActiveOpQ);
		osal_assert(pOp);
	}

	return pOp;
}

static MTK_WCN_BOOL wmt_lib_put_op(P_OSAL_OP_Q pOpQ, P_OSAL_OP pOp)
{
	INT32 iRet = 0;

	if (!pOpQ || !pOp) {
		WMT_WARN_FUNC("invalid input param: pOpQ(0x%p), pLxOp(0x%p)\n", pOpQ, pOp);
		osal_assert(pOpQ);
		osal_assert(pOp);
		return MTK_WCN_BOOL_FALSE;
	}

	/* Ownership transfer must not fail just because the caller was signalled. */
	mutex_lock(&pOpQ->sLock.lock);

#if defined(CONFIG_MTK_ENG_BUILD) || defined(CONFIG_MT_ENG_BUILD)
	if (osal_opq_has_op(pOpQ, pOp)) {
		WMT_ERR_FUNC("Op(%p) already exists in queue(%p)\n", pOp, pOpQ);
		iRet = -2;
	}
#endif

	/* acquire lock success */
	if (!RB_FULL(pOpQ))
		RB_PUT(pOpQ, pOp);
	else {
		WMT_WARN_FUNC("RB_FULL(%p -> %p)\n", pOp, pOpQ);
		iRet = -1;
	}

	osal_unlock_sleepable_lock(&pOpQ->sLock);

	if (iRet) {
		osal_opq_dump("FreeOpQ", &gDevWmt.rFreeOpQ);
		osal_opq_dump("ActiveOpQ", &gDevWmt.rActiveOpQ);
		return MTK_WCN_BOOL_FALSE;
	}
	return MTK_WCN_BOOL_TRUE;
}

static VOID wmt_lib_drain_op_queue(P_OSAL_OP_Q pOpQ)
{
	P_OSAL_OP pending[WMT_OP_BUF_SIZE];
	UINT32 count = 0;
	UINT32 i;

	/* A late reset may still call this helper after shutdown has closed admission. */
	mutex_lock(&g_wmt_op_pool_lock);
	if (g_wmt_op_pool_initialized) {
		mutex_lock(&pOpQ->sLock.lock);
		while (!RB_EMPTY(pOpQ)) {
			RB_GET(pOpQ, pending[count]);
			count++;
		}
		osal_unlock_sleepable_lock(&pOpQ->sLock);
	}
	mutex_unlock(&g_wmt_op_pool_lock);

	/* Completion and final recycling do not hold the admission or queue locks. */
	for (i = 0; i < count; i++)
		wmt_lib_complete_op(pending[i], -1);
}

static MTK_WCN_BOOL wmt_lib_queue_op(P_OSAL_OP pOp, bool worker)
{
	P_DEV_WMT pWmtDev = &gDevWmt;
	MTK_WCN_BOOL ret = MTK_WCN_BOOL_FALSE;

	mutex_lock(&g_wmt_op_pool_lock);
	if (!g_wmt_op_pool_stopping) {
		/* The caller keeps its own reference until enqueue and wakeup finish. */
		atomic_inc(&pOp->ref_count);
		ret = wmt_lib_put_op(worker ? &pWmtDev->rWorkerOpQ :
				    &pWmtDev->rActiveOpQ, pOp);
		if (!ret)
			atomic_dec(&pOp->ref_count);
		else
			osal_trigger_event(worker ? &pWmtDev->rWmtdWorkerWq :
					   &pWmtDev->rWmtdWq);
	}
	mutex_unlock(&g_wmt_op_pool_lock);
	return ret;
}

INT32 wmt_lib_put_op_to_free_queue(P_OSAL_OP pOp)
{
	P_DEV_WMT pWmtDev = &gDevWmt;
	INT32 ret;

	if (!pOp)
		return -1;
	osal_free(pOp->wmt_payload);
	pOp->wmt_payload = NULL;
	ret = wmt_lib_put_op(&pWmtDev->rFreeOpQ, pOp) ? 0 : -1;
	/* Do not touch pOp or queue storage after releasing the checkout. */
	if (atomic_dec_and_test(&g_wmt_ops_checked_out))
		wake_up(&g_wmt_op_pool_idle);
	return ret;
}

PVOID wmt_lib_alloc_op_data(P_OSAL_OP pOp, SIZE_T size)
{
	if (!pOp || !size || size > (UINT32)-1 || pOp->wmt_payload)
		return NULL;
	pOp->wmt_payload = osal_malloc(size);
	if (pOp->wmt_payload)
		osal_memset(pOp->wmt_payload, 0, size);
	return pOp->wmt_payload;
}

VOID wmt_lib_put_op_ref(P_OSAL_OP pOp)
{
	if (pOp && atomic_dec_and_test(&pOp->ref_count))
		wmt_lib_put_op_to_free_queue(pOp);
}

MTK_WCN_BOOL wmt_lib_submit_op_result(P_OSAL_OP pOp, P_OSAL_OP_DAT result)
{
	P_DEV_WMT pWmtDev = &gDevWmt;
	MTK_WCN_BOOL bRet = MTK_WCN_BOOL_FALSE;
	P_OSAL_SIGNAL pSignal = NULL;
	INT32 waitRet = -1;
	MTK_WCN_BOOL waitWorker = MTK_WCN_BOOL_FALSE;
	UINT32 opId = 0;
	INT32 opResult = -1;
	unsigned long flags;

	osal_assert(pWmtDev);
	osal_assert(pOp);

	do {
		if (!pWmtDev || !pOp) {
			WMT_ERR_FUNC("pWmtDev(0x%p), pOp(0x%p)\n", pWmtDev, pOp);
			break;
		}

		/* Until completion, the caller receives only its submitted fields. */
		if (result)
			*result = pOp->op;
		opId = pOp->op.opId;
		waitWorker = (opId == WMT_OPID_FUNC_ON &&
			pOp->op.au4OpData[0] == WMTDRV_TYPE_WIFI);

		/* Init ref_count to 1 indicating that current thread holds a ref to it */
		atomic_set(&pOp->ref_count, 1);
		pOp->wmt_state = WMT_OP_PENDING;

		if ((mtk_wcn_stp_coredump_start_get() != 0) &&
		    (pOp->op.opId != WMT_OPID_HW_RST) &&
		    (pOp->op.opId != WMT_OPID_SW_RST) && (pOp->op.opId != WMT_OPID_GPIO_STATE)) {
			WMT_WARN_FUNC("block tx flag is set\n");
			break;
		}
		pSignal = &pOp->signal;
/* pOp->u4WaitMs = u4WaitMs; */
		if (pSignal->timeoutValue) {
			pOp->result = -9;
			osal_signal_init(pSignal);
		}

		/* put to active Q */
		bRet = wmt_lib_queue_op(pOp, false);
		if (bRet == MTK_WCN_BOOL_FALSE) {
			WMT_WARN_FUNC("put to active queue fail\n");
			break;
		}

		if (pSignal->timeoutValue == 0) {
			bRet = MTK_WCN_BOOL_TRUE;
			/* clean it in wmtd */
			break;
		}

		/* check result */
		/* wait_ret = wait_for_completion_interruptible_timeout(&pOp->comp, msecs_to_jiffies(u4WaitMs)); */
		/* wait_ret = wait_for_completion_timeout(&pOp->comp, msecs_to_jiffies(u4WaitMs)); */
		if (waitWorker)
			waitRet = osal_wait_for_signal_timeout(pSignal, &pWmtDev->worker_thread);
		else
			waitRet = osal_wait_for_signal_timeout(pSignal, &pWmtDev->thread);
		WMT_DBG_FUNC("osal_wait_for_signal_timeout:%d\n", waitRet);

		if (waitRet == 0)
			WMT_ERR_FUNC("opId(%d) completion timeout\n", opId);

		/* Reset can wake the sender before the consumer has finished. */
		bRet = MTK_WCN_BOOL_FALSE;
		if (waitRet > 0) {
			spin_lock_irqsave(&g_wmt_op_lock, flags);
			if (pOp->wmt_state == WMT_OP_COMPLETED) {
				opResult = pOp->result;
				bRet = (opResult == 0);
				if (result)
					*result = pOp->op;
			}
			spin_unlock_irqrestore(&g_wmt_op_lock, flags);
			if (opResult)
				WMT_WARN_FUNC("opId(%d) result:%d\n", opId, opResult);
		}
	} while (0);

	return bRet;
}

MTK_WCN_BOOL wmt_lib_put_act_op_result(P_OSAL_OP pOp, P_OSAL_OP_DAT result)
{
	MTK_WCN_BOOL ret = wmt_lib_submit_op_result(pOp, result);

	wmt_lib_put_op_ref(pOp);
	return ret;
}

MTK_WCN_BOOL wmt_lib_put_act_op(P_OSAL_OP pOp)
{
	return wmt_lib_put_act_op_result(pOp, NULL);
}

MTK_WCN_BOOL wmt_lib_put_worker_op(P_OSAL_OP pOp)
{
	P_DEV_WMT pWmtDev = &gDevWmt;
	MTK_WCN_BOOL bRet = MTK_WCN_BOOL_FALSE;

	osal_assert(pWmtDev);
	osal_assert(pOp);

	do {
		if (!pWmtDev || !pOp) {
			WMT_ERR_FUNC("pWmtDev(0x%p), pOp(0x%p)\n", pWmtDev, pOp);
			break;
		}

		/* put to activeWorker Q */
		bRet = wmt_lib_queue_op(pOp, true);
		if (bRet == MTK_WCN_BOOL_FALSE) {
			WMT_WARN_FUNC("put to ActiveWorker queue fail\n");
			break;
		}
	} while (0);

	return bRet;
}

static VOID wmt_lib_complete_op(P_OSAL_OP pOp, INT32 result)
{
	unsigned long flags;

	spin_lock_irqsave(&g_wmt_op_lock, flags);
	if (pOp->wmt_state == WMT_OP_PENDING) {
		pOp->wmt_state = WMT_OP_COMPLETED;
		if (osal_op_is_wait_for_signal(pOp))
			osal_op_raise_signal(pOp, result);
	}
	spin_unlock_irqrestore(&g_wmt_op_lock, flags);
	wmt_lib_put_op_ref(pOp);
}

static VOID wmt_lib_cancel_current_op(P_DEV_WMT pWmtDev)
{
	unsigned long flags;
	P_OSAL_OP pOp;

	spin_lock_irqsave(&g_wmt_op_lock, flags);
	pOp = pWmtDev->pCurOP;
	if (pOp && pOp->wmt_state == WMT_OP_PENDING &&
	    osal_op_is_wait_for_signal(pOp)) {
		pOp->wmt_state = WMT_OP_CANCELLED;
		osal_op_raise_signal(pOp, -1);
	}
	spin_unlock_irqrestore(&g_wmt_op_lock, flags);
}

static UINT32 wmt_lib_active_op_id(P_DEV_WMT pWmtDev, bool worker)
{
	unsigned long flags;
	P_OSAL_OP pOp;
	UINT32 id = (UINT32)-1;

	if (!pWmtDev)
		return id;
	spin_lock_irqsave(&g_wmt_op_lock, flags);
	pOp = worker ? pWmtDev->pWorkerOP : pWmtDev->pCurOP;
	if (pOp)
		id = READ_ONCE(pOp->op.opId);
	spin_unlock_irqrestore(&g_wmt_op_lock, flags);
	return id;
}

P_OSAL_OP wmt_lib_get_current_op(P_DEV_WMT pWmtDev)
{
	if (pWmtDev)
		return READ_ONCE(pWmtDev->pCurOP);
	WMT_ERR_FUNC("Invalid pointer\n");
	return NULL;
}

INT32 wmt_lib_set_current_op(P_DEV_WMT pWmtDev, P_OSAL_OP pOp)
{
	unsigned long flags;

	if (pWmtDev) {
		spin_lock_irqsave(&g_wmt_op_lock, flags);
		WRITE_ONCE(pWmtDev->pCurOP, pOp);
		spin_unlock_irqrestore(&g_wmt_op_lock, flags);
		WMT_DBG_FUNC("pOp=0x%p\n", pOp);
		return 0;
	}
	WMT_ERR_FUNC("Invalid pointer\n");
	return -1;
}

INT32 wmt_lib_set_worker_op(P_DEV_WMT pWmtDev, P_OSAL_OP pOp)
{
	unsigned long flags;

	if (pWmtDev) {
		spin_lock_irqsave(&g_wmt_op_lock, flags);
		pWmtDev->pWorkerOP = pOp;
		spin_unlock_irqrestore(&g_wmt_op_lock, flags);
		WMT_DBG_FUNC("pOp=0x%p\n", pOp);
		return 0;
	}
	WMT_ERR_FUNC("Invalid pointer\n");
	return -1;
}

VOID wmt_lib_state_init(VOID)
{
	wmt_lib_drain_op_queue(&gDevWmt.rActiveOpQ);
}

UINT32 wmt_lib_wait_event_checker(P_OSAL_THREAD pThread)
{
	P_DEV_WMT pDevWmt;

	if (pThread) {
		pDevWmt = (P_DEV_WMT) (pThread->pThreadData);
		return !RB_EMPTY(&pDevWmt->rActiveOpQ);
	}
	WMT_ERR_FUNC("pThread(NULL)\n");
	return 0;
}

UINT32 wmt_lib_worker_wait_event_checker(P_OSAL_THREAD pThread)
{
	P_DEV_WMT pDevWmt;

	if (pThread) {
		pDevWmt = (P_DEV_WMT) (pThread->pThreadData);
		return !RB_EMPTY(&pDevWmt->rWorkerOpQ);
	}
	WMT_ERR_FUNC("pThread(NULL)\n");
	return 0;
}

static INT32 wmtd_thread(void *pvData)
{
	P_DEV_WMT pWmtDev = (P_DEV_WMT) pvData;
	P_OSAL_EVENT pEvent = NULL;
	P_OSAL_OP pOp;
	INT32 iResult;
	UINT32 opId;

	if (pWmtDev == NULL) {
		WMT_ERR_FUNC("pWmtDev(NULL)\n");
		return -1;
	}
	WMT_INFO_FUNC("wmtd thread starts\n");

	pEvent = &(pWmtDev->rWmtdWq);

	for (;;) {
		pOp = NULL;
		pEvent->timeoutValue = 0;
/*        osal_thread_wait_for_event(&pWmtDev->thread, pEvent);*/
		osal_thread_wait_for_event(&pWmtDev->thread, pEvent, wmt_lib_wait_event_checker);

		if (osal_thread_should_stop(&pWmtDev->thread)) {
			WMT_INFO_FUNC("wmtd thread should stop now...\n");
			break;
		}

		/* get Op from activeQ */
		pOp = wmt_lib_get_op(&pWmtDev->rActiveOpQ);
		if (!pOp) {
			WMT_WARN_FUNC("get_lxop activeQ fail\n");
			continue;
		}

		osal_op_history_save(&pWmtDev->wmtd_op_history, pOp);

#if 0				/* wmt_core_opid_handler will do sanity check on opId, so no usage here */
		id = lxop_get_opid(pLxOp);
		if (id >= WMT_OPID_MAX) {
			WMT_WARN_FUNC("abnormal opid id: 0x%x\n", id);
			iResult = -1;
			goto handlerDone;
		}
#endif

		if (osal_test_bit(WMT_STAT_RST_ON, &pWmtDev->state)) {
			/* when whole chip reset, only HW RST and SW RST cmd can execute */
			if ((pOp->op.opId == WMT_OPID_HW_RST)
			    || (pOp->op.opId == WMT_OPID_SW_RST)
			    || (pOp->op.opId == WMT_OPID_GPIO_STATE)) {
				iResult = wmt_core_opid(&pOp->op);
			} else {
				iResult = -2;
				WMT_WARN_FUNC
				    ("Whole chip resetting, opid (0x%x) failed, iRet(%d)\n",
				     pOp->op.opId, iResult);
			}
		} else {
			wmt_lib_set_current_op(pWmtDev, pOp);
			iResult = wmt_core_opid(&pOp->op);
			wmt_lib_set_current_op(pWmtDev, NULL);
		}

		/* Wi-Fi dispatch can change the ID and enqueue its own reference. */
		opId = pOp->op.opId;
		if (iResult)
			WMT_WARN_FUNC("opid (0x%x) failed, iRet(%d)\n", opId, iResult);

		if (iResult == 0 &&
			(opId == WMT_OPID_WLAN_PROBE || opId == WMT_OPID_WLAN_REMOVE)) {
			wmt_lib_put_op_ref(pOp);
			continue;
		}

		wmt_lib_complete_op(pOp, iResult);

		if (opId == WMT_OPID_EXIT) {
			WMT_INFO_FUNC("wmtd thread received exit signal\n");
			break;
		}
	}

	WMT_INFO_FUNC("wmtd thread exits succeed\n");

	return 0;
}

static INT32 wmtd_worker_thread(void *pvData)
{
	P_DEV_WMT pWmtDev = (P_DEV_WMT) pvData;
	P_OSAL_EVENT pEvent = NULL;
	P_OSAL_OP pOp;
	INT32 iResult = 0;

	pEvent = &(pWmtDev->rWmtdWorkerWq);

	for (;;) {
		osal_thread_wait_for_event(&pWmtDev->worker_thread, pEvent, wmt_lib_worker_wait_event_checker);

		if (osal_thread_should_stop(&pWmtDev->worker_thread)) {
			WMT_INFO_FUNC("wmtd worker thread should stop now...\n");
			break;
		}

		/* get Op from activeWorkerQ */
		pOp = wmt_lib_get_op(&pWmtDev->rWorkerOpQ);
		if (!pOp) {
			WMT_WARN_FUNC("get activeWorkerQ fail\n");
			continue;
		}
		osal_op_history_save(&pWmtDev->worker_op_history, pOp);

		if (osal_test_bit(WMT_STAT_RST_ON, &pWmtDev->state)) {
			iResult = -2;
			WMT_WARN_FUNC("Whole chip resetting, opid (0x%x) failed, iRet(%d)\n", pOp->op.opId, iResult);
		} else {
			WMT_WARN_FUNC("opid: 0x%x", pOp->op.opId);
			wmt_lib_set_worker_op(pWmtDev, pOp);
			osal_timer_start(&gDevWmt.worker_timer, MAX_FUNC_ON_TIME);
			iResult = wmt_core_opid(&pOp->op);
			osal_timer_stop(&gDevWmt.worker_timer);
			wmt_lib_set_worker_op(pWmtDev, NULL);
		}

		if (iResult)
			WMT_WARN_FUNC("opid (0x%x) failed, iRet(%d)\n", pOp->op.opId, iResult);

		wmt_lib_complete_op(pOp, iResult);
	}

	return 0;
}


static P_OSAL_OP borrow(UINT32 timeout)
{
    P_OSAL_OP operation = wmt_lib_get_free_op();
    assert(operation);
    unsigned char *payload = wmt_lib_alloc_op_data(operation, 32);
    assert(payload);
    memset(payload, 0x3d, 32);
    operation->op.opId = WMT_OPID_LPBK;
    operation->op.au4OpData[0] = (SIZE_T)payload;
    operation->signal.timeoutValue = timeout;
    return operation;
}
static void *shutdown_call(void *unused)
{
    teardown_thread = true;
    assert(wmt_lib_deinit() == 0);
    return NULL;
}
static pthread_t start_shutdown(void)
{
    pthread_t thread;
    assert(pthread_create(&thread, NULL, shutdown_call, NULL) == 0);
    return thread;
}
static void join(pthread_t thread) { assert(pthread_join(thread, NULL) == 0); }
static void *submit_call(void *operation) { assert(wmt_lib_put_act_op(operation)); return NULL; }
static void *release_call(void *operation) { wmt_lib_put_op_ref(operation); return NULL; }
static void *reset_call(void *unused) { wmt_lib_state_init(); return NULL; }
static void still_borrowed(int allocations)
{
    assert(atomic_read(&clears) == 1);
    assert(atomic_read(&g_wmt_ops_checked_out) == 1);
    assert(atomic_read(&live_allocations) == allocations);
    assert(atomic_read(&destroyed_pool_locks) == 0);
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    int test = atoi(argv[1]);
    P_OSAL_OP operation;
    pthread_t teardown, sender;
    OSAL_OP_DAT result;
    assert(wmt_lib_get_free_op() == NULL);
    if (test >= 11 && test <= 13) {
        fail_core_init = test == 11;
        fail_plat_init = test == 12;
        fail_worker_run = test == 13;
        assert(wmt_lib_init() < 0);
        assert(wmt_lib_get_free_op() == NULL);
        assert(wmt_lib_deinit() == 0);
        assert(atomic_read(&destroyed_pool_locks) == (test == 11 ? 0 : 3));
    } else {
        atomic_set(&allow_regular, test == 1 || test == 2 || test == 7 || test == 8 || test == 10);
        atomic_set(&allow_worker, test == 8);
        assert(wmt_lib_init() == 0);
        if (test == 0 || test == 9 || test == 14) {
            operation = borrow(0);
            assert(wmt_lib_put_act_op(operation));
            assert(wmt_lib_deinit() == 0);
            if (test == 9) {
                wmt_lib_state_init();
                assert(wmt_lib_get_free_op() == NULL);
            }
            if (test == 14) {
                assert(wmt_lib_init() == 0);
                operation = borrow(0);
                assert(wmt_lib_put_act_op(operation));
                assert(wmt_lib_deinit() == 0);
            }
        } else if (test == 1 || test == 7 || test == 8) {
            operation = borrow(0);
            operation->op.opId = WMT_OPID_FUNC_ON;
            pause_wifi_dispatch = test == 7;
            pause_worker = test == 8;
            handler_gate.enabled = test != 1;
            assert(wmt_lib_put_act_op(operation));
            if (test == 1) {
                await(&worker_queued);
                assert(wmt_lib_deinit() == 0);
            } else {
                await(&handler_gate);
                teardown = start_shutdown();
                await(&stop_entered);
                still_borrowed(1);
                release(&handler_gate);
                join(teardown);
                assert(atomic_read(&worker_wakeups) == (test == 7 ? 0 : 1));
            }
        } else if (test == 2 || test == 3 || test == 4 || test == 5) {
            operation = borrow(test == 2 ? 2000 : 1);
            if (test == 2 || test == 3)
                assert(wmt_lib_submit_op_result(operation, &result) == (test == 2));
            teardown = start_shutdown();
            await(&idle_entered);
            still_borrowed(1);
            assert(wmt_lib_get_free_op() == NULL);
            if (test == 4) {
                /* A borrower paused before waking the device can still unwind after closure. */
                mutex_lock(&gDevWmt.psm_lock.lock);
                assert(!wmt_lib_submit_op_result(operation, &result));
                mutex_unlock(&gDevWmt.psm_lock.lock);
                assert(RB_EMPTY(&gDevWmt.rActiveOpQ));
                assert(atomic_read(&operation->ref_count) == 1);
                assert(result.au4OpData[0] == operation->op.au4OpData[0]);
            }
            if (test == 2) {
                unsigned char *payload = operation->wmt_payload;
                for (size_t i = 0; i < 32; i++) assert(payload[i] == 0x6b);
            }
            if (test == 3) {
                assert(operation->result == -1 && atomic_read(&signal_calls) == 1);
                assert(atomic_read(&operation->ref_count) == 1);
            }
            if (test == 5) assert(wmt_lib_put_op_to_free_queue(operation) == 0);
            else wmt_lib_put_op_ref(operation);
            join(teardown);
        } else if (test == 6) {
            operation = borrow(0);
            enqueue_gate.enabled = true;
            assert(pthread_create(&sender, NULL, submit_call, operation) == 0);
            await(&enqueue_gate);
            teardown = start_shutdown();
            await(&pool_contended);
            assert(atomic_read(&clears) == 1);
            pthread_mutex_lock(&stop_entered.lock);
            assert(!stop_entered.arrived);
            pthread_mutex_unlock(&stop_entered.lock);
            release(&enqueue_gate);
            join(sender);
            join(teardown);
        } else if (test == 10 || test == 15) {
            operation = borrow(test == 10 ? 2000 : 0);
            if (test == 10) assert(wmt_lib_submit_op_result(operation, &result));
            else assert(wmt_lib_put_act_op(operation));
            recycle_gate.enabled = true;
            assert(pthread_create(&sender, NULL, test == 10 ? release_call : reset_call, operation) == 0);
            await(&recycle_gate);
            teardown = start_shutdown();
            await(&idle_entered);
            still_borrowed(0);
            release(&recycle_gate);
            join(sender);
            join(teardown);
        } else abort();
    }
    assert(atomic_read(&live_allocations) == 0 && atomic_read(&g_wmt_ops_checked_out) == 0);
    assert(atomic_read(&clears) == (test == 14 ? 4 : 2));
    assert(!g_wmt_op_pool_initialized && g_wmt_op_pool_stopping);
    assert(!g_wmt_worker_timer_initialized && !g_wmt_utc_timer_initialized);
    puts("PASS");
    return 0;
}
