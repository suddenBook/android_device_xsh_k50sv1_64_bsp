/* Host synchronization and hardware adapters; production bodies are inserted whole. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>

#define NO_INSTRUMENT __attribute__((no_instrument_function))
void __cyg_profile_func_enter(void *, void *) NO_INSTRUMENT;
void __cyg_profile_func_exit(void *, void *) NO_INSTRUMENT;

typedef void VOID;
typedef int INT32;
typedef int8_t INT8;
typedef unsigned int UINT32;
typedef unsigned long ULONG;
typedef long LONG;
typedef unsigned char *PUINT8;
typedef int ENUM_WMT_CHIP_TYPE;
typedef atomic_int atomic_t;
#define ATOMIC_INIT(value) (value)
#define atomic_read(value) atomic_load(value)
#define atomic_inc(value) ((void)atomic_fetch_add(value, 1))
#define atomic_dec_and_test(value) (atomic_fetch_sub(value, 1) == 1)
#define unlikely(value) (value)
#define EXPORT_SYMBOL(value)
#define CONNADP_INFO_FUNC(...) ((void)0)
#define CONNADP_DBG_FUNC(...) ((void)0)
#define CONNADP_WARN_FUNC(...) ((void)0)
#define CMB_STUB_LOG_PR_WARN(...) ((void)0)
#define CMB_STUB_LOG_PR_INFO(...) ((void)0)
#define CMB_STUB_LOG_PR_DBG(...) ((void)0)
#define WMT_INFO_FUNC(...) ((void)0)
#define WMT_WARN_FUNC(...) ((void)0)
#define WMT_DBG_FUNC(...) ((void)0)
#define WMT_ERR_FUNC(...) ((void)0)
#define WMT_CHIP_TYPE_SOC 1
#define WMT_CHIP_TYPE_COMBO 0
#define WMT_DEV_MAJOR 190
#define WMT_DEV_NUM 1
#define WMT_OP_BUF_SIZE 16
#define CFG_WMT_WAKELOCK_SUPPORT 1
#define CFG_WMT_PS_SUPPORT 1
#define CFG_WMT_LTE_COEX_HANDLING 1
#define CFG_WMT_DBG_SUPPORT 1
#define CFG_WMT_PROC_FOR_AEE 1
#define CFG_WMT_PROC_FOR_DUMP_INFO 1
#define WMT_CREATE_NODE_DYNAMIC 1
#define STEP_TRIGGER_POINT_WHEN_CLOCK_FAIL 1
#define MKDEV(major, minor) ((dev_t)(((unsigned int)(major) << 20) | (minor)))
#define osal_memcpy memcpy
#define osal_free free

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

static pthread_mutex_t progress_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t progress_cond = PTHREAD_COND_INITIALIZER;
static atomic_int module_callbacks, blocked_drains, blocked_writers;
static atomic_int cleanup_calls, thermal_commands, assertion_calls, clock_calls;
static atomic_int operation_references, replacement_calls;
static atomic_bool cleanup_while_callback;
static atomic_bool pause_on_entry[3], pause_on_return[3], arrived[3], released[3];
static bool pause_thermal_command, nested_assertion;
static _Thread_local unsigned int spin_depth;
static _Thread_local bool irq_disabled;

static void progress(void)
{
    CHECK(pthread_mutex_lock(&progress_lock) == 0);
    CHECK(pthread_cond_broadcast(&progress_cond) == 0);
    CHECK(pthread_mutex_unlock(&progress_lock) == 0);
}

static void pause_callback(int kind)
{
    CHECK(!irq_disabled && !spin_depth);
    CHECK(pthread_mutex_lock(&progress_lock) == 0);
    atomic_store(&arrived[kind], true);
    CHECK(pthread_cond_broadcast(&progress_cond) == 0);
    while (!atomic_load(&released[kind]))
        CHECK(pthread_cond_wait(&progress_cond, &progress_lock) == 0);
    CHECK(pthread_mutex_unlock(&progress_lock) == 0);
}

static void release_callback(int kind)
{
    atomic_store(&released[kind], true);
    progress();
}

#define AWAIT(condition) do { \
    struct timespec deadline; \
    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0); deadline.tv_sec += 5; \
    CHECK(pthread_mutex_lock(&progress_lock) == 0); \
    while (!(condition)) \
        CHECK(pthread_cond_timedwait(&progress_cond, &progress_lock, &deadline) == 0); \
    CHECK(pthread_mutex_unlock(&progress_lock) == 0); \
} while (0)

struct mutex { pthread_mutex_t native; const char *name; };
#define DEFINE_MUTEX(name) struct mutex name = {PTHREAD_MUTEX_INITIALIZER, #name}
typedef struct { pthread_mutex_t native; } spinlock_t;
#define DEFINE_SPINLOCK(name) spinlock_t name = {PTHREAD_MUTEX_INITIALIZER}
struct host_wait_queue { pthread_mutex_t lock; pthread_cond_t cond; const char *name; };
#define DECLARE_WAIT_QUEUE_HEAD(name) struct host_wait_queue name = { \
    PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, #name }

static void mutex_lock(struct mutex *lock)
{
    CHECK(!irq_disabled && !spin_depth);
    int result = pthread_mutex_trylock(&lock->native);
    if (result == EBUSY) {
        if (strcmp(lock->name, "bridge_update_lock") == 0) {
            atomic_fetch_add(&blocked_writers, 1);
            progress();
        }
        result = pthread_mutex_lock(&lock->native);
    }
    CHECK(result == 0);
}

static void mutex_unlock(struct mutex *lock)
{
    CHECK(pthread_mutex_unlock(&lock->native) == 0);
}

#define spin_lock_irqsave(lock, flags) do { \
    (flags) = irq_disabled; irq_disabled = true; \
    CHECK(pthread_mutex_lock(&(lock)->native) == 0); spin_depth++; \
} while (0)
#define spin_unlock_irqrestore(lock, flags) do { \
    CHECK(spin_depth > 0); spin_depth--; \
    CHECK(pthread_mutex_unlock(&(lock)->native) == 0); irq_disabled = (flags); \
} while (0)

#define wait_event(queue, condition) do { \
    bool reported = false; \
    CHECK(!irq_disabled && !spin_depth); \
    CHECK(pthread_mutex_lock(&(queue).lock) == 0); \
    while (!(condition)) { \
        if (!reported && strcmp((queue).name, "bridge_idle") == 0) { \
            atomic_fetch_add(&blocked_drains, 1); reported = true; progress(); \
        } \
        CHECK(pthread_cond_wait(&(queue).cond, &(queue).lock) == 0); \
    } \
    CHECK(pthread_mutex_unlock(&(queue).lock) == 0); \
} while (0)

static void wake_up_all(struct host_wait_queue *queue)
{
    CHECK(pthread_mutex_lock(&queue->lock) == 0);
    CHECK(pthread_cond_broadcast(&queue->cond) == 0);
    CHECK(pthread_mutex_unlock(&queue->lock) == 0);
}

typedef enum _ENUM_WMTDRV_TYPE_T {
	WMTDRV_TYPE_BT = 0,
	WMTDRV_TYPE_FM = 1,
	WMTDRV_TYPE_GPS = 2,
	WMTDRV_TYPE_WIFI = 3,
	WMTDRV_TYPE_WMT = 4,
	WMTDRV_TYPE_ANT = 5,
	WMTDRV_TYPE_STP = 6,
	WMTDRV_TYPE_SDIO1 = 7,
	WMTDRV_TYPE_SDIO2 = 8,
	WMTDRV_TYPE_LPBK = 9,
	WMTDRV_TYPE_COREDUMP = 10,
	WMTDRV_TYPE_MAX
} ENUM_WMTDRV_TYPE_T, *P_ENUM_WMTDRV_TYPE_T;
typedef enum _ENUM_WMTTHERM_TYPE_T {
	WMTTHERM_ZERO = 0,
	WMTTHERM_ENABLE = WMTTHERM_ZERO + 1,
	WMTTHERM_READ = WMTTHERM_ENABLE + 1,
	WMTTHERM_DISABLE = WMTTHERM_READ + 1,
	WMTTHERM_MAX
} ENUM_WMTTHERM_TYPE_T, *P_ENUM_WMTTHERM_TYPE_T;
#define WMT_LOG_DBG     3
typedef int (*wmt_bridge_thermal_query_cb)(void);
typedef int (*wmt_bridge_trigger_assert_cb)(void);
typedef void (*wmt_bridge_connsys_clock_fail_dump_cb)(void);
struct wmt_platform_bridge {
	wmt_bridge_thermal_query_cb thermal_query_cb;
	wmt_bridge_trigger_assert_cb trigger_assert_cb;
	wmt_bridge_connsys_clock_fail_dump_cb clock_fail_dump_cb;
};
enum CMB_STUB_AIF_X {
	CMB_STUB_AIF_0 = 0,	/* 0000: BT_PCM_OFF & FM analog (line in/out) */
	CMB_STUB_AIF_1 = 1,	/* 0001: BT_PCM_ON & FM analog (in/out) */
	CMB_STUB_AIF_2 = 2,	/* 0010: BT_PCM_OFF & FM digital (I2S) */
	CMB_STUB_AIF_3 = 3,	/* 0011: BT_PCM_ON & FM digital (I2S) (invalid in 73evb & 1.2 phone configuration) */
	CMB_STUB_AIF_4 = 4, /* 0100: BT_I2S & FM disable in special projects, e.g. protea*/
	CMB_STUB_AIF_MAX = 5,
};
enum CMB_STUB_AIF_CTRL {
	CMB_STUB_AIF_CTRL_DIS = 0,
	CMB_STUB_AIF_CTRL_EN = 1,
	CMB_STUB_AIF_CTRL_MAX = 2,
};
typedef int (*wmt_aif_ctrl_cb) (enum CMB_STUB_AIF_X, enum CMB_STUB_AIF_CTRL);
typedef void (*wmt_func_ctrl_cb) (unsigned int, unsigned int);
typedef signed long (*wmt_thermal_query_cb) (void);
typedef int (*wmt_trigger_assert_cb) (void);
typedef int (*wmt_deep_idle_ctrl_cb) (unsigned int);
typedef int (*wmt_func_do_reset) (unsigned int);

typedef void (*wmt_clock_fail_dump_cb) (void);

struct _CMB_STUB_CB_ {
	unsigned int size;	/* structure size */
	/*wmt_bgf_eirq_cb bgf_eirq_cb; *//* remove bgf_eirq_cb from stub. handle it in platform */
	wmt_aif_ctrl_cb aif_ctrl_cb;
	wmt_func_ctrl_cb func_ctrl_cb;
	wmt_thermal_query_cb thermal_query_cb;
	wmt_trigger_assert_cb trigger_assert_cb;
	wmt_deep_idle_ctrl_cb deep_idle_ctrl_cb;
	wmt_func_do_reset wmt_do_reset_cb;
	wmt_clock_fail_dump_cb clock_fail_dump_cb;
};
typedef long (*thermal_query_ctrl_cb) (VOID);
typedef INT32(*trigger_assert_cb) (UINT32 type, UINT32 reason);
enum wmt_init_status {
	WMT_INIT_NOT_START,
	WMT_INIT_START,
	WMT_INIT_DONE,
};


typedef int OSAL_SLEEPABLE_LOCK;
typedef spinlock_t OSAL_UNSLEEPABLE_LOCK;
typedef int OSAL_EVENT;
typedef int OSAL_SIGNAL;
typedef int OSAL_THREAD;
typedef int OSAL_TIMER;
typedef int OSAL_WAKE_LOCK;
struct work_struct { int unused; };
struct osal_op_history { int unused; };
typedef struct { OSAL_SIGNAL signal; } OSAL_OP;
typedef struct { OSAL_SLEEPABLE_LOCK sLock; } OSAL_OP_Q;
struct vendor_patch_table { char **active_version; void *patch; int num; };
typedef struct {
    OSAL_THREAD thread, worker_thread;
    OSAL_TIMER worker_timer, utc_sync_timer;
    struct work_struct wmtd_worker_thread_work, utcSyncWorker;
    struct osal_op_history wmtd_op_history, worker_op_history;
    OSAL_OP_Q rFreeOpQ, rActiveOpQ, rWorkerOpQ;
    OSAL_OP arQue[WMT_OP_BUF_SIZE];
    OSAL_EVENT cmdReq, rWmtRxWq, rWmtdWq, rWmtdWorkerWq;
    OSAL_SIGNAL cmdResp;
    OSAL_SLEEPABLE_LOCK mpu_lock, idc_lock, wlan_lock, assert_lock, psm_lock;
    struct { int cfgExist; } rWmtGenConf;
    struct vendor_patch_table patch_table;
} DEV_WMT, *P_DEV_WMT;
static DEV_WMT gDevWmt;
static struct { struct work_struct work; } wmt_assert_work;
struct cdev { int unused; };
struct class { int unused; };
struct device { int unused; };
struct notifier_block { int unused; };
static struct class class_storage, *wmt_class = &class_storage;
static struct device device_storage, *wmt_dev = &device_storage;
static struct notifier_block wmt_fb_notifier;
static OSAL_UNSLEEPABLE_LOCK g_temp_query_spinlock = {PTHREAD_MUTEX_INITIALIZER};
static OSAL_SLEEPABLE_LOCK g_aee_read_lock, g_dump_info_read_lock, gOsSLock;
static OSAL_WAKE_LOCK wmt_wake_lock;
static int gTemperatureThreshold = 65, gWmtDbgLvl;
static struct { void (*consys_ic_clock_fail_dump)(void); } consys_ops;
static typeof(consys_ops) *wmt_consys_ic_ops = &consys_ops;

static wmt_aif_ctrl_cb cmb_stub_aif_ctrl_cb;
static wmt_func_ctrl_cb cmb_stub_func_ctrl_cb;
static wmt_thermal_query_cb cmb_stub_thermal_ctrl_cb;
static wmt_trigger_assert_cb cmb_stub_trigger_assert_cb;
static wmt_deep_idle_ctrl_cb cmb_stub_deep_idle_ctrl_cb;
static wmt_func_do_reset cmb_stub_do_reset_cb;
static wmt_clock_fail_dump_cb cmb_stub_clock_fail_dump_cb;
static bool g_wmt_plat_initialized;
static ENUM_WMT_CHIP_TYPE g_wmt_plat_chip_type;
thermal_query_ctrl_cb wmt_plat_thermal_query_ctrl_cb;
trigger_assert_cb wmt_plat_trigger_assert_cb;
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
static INT32 gWmtMajor = WMT_DEV_MAJOR;
static INT32 gWmtInitStatus = WMT_INIT_NOT_START;
static struct cdev gWmtCdev;
#define HOST_HAS_PLATFORM_OWNER 1

#ifdef MTK_WCN_REMOVE_KERNEL_MODULE
int mtk_wcn_cmb_stub_query_ctrl(void)
#else
static int _mtk_wcn_cmb_stub_query_ctrl(void)
#endif
;
#ifdef MTK_WCN_REMOVE_KERNEL_MODULE
int mtk_wcn_cmb_stub_trigger_assert(void)
#else
static int _mtk_wcn_cmb_stub_trigger_assert(void)
#endif
;
void _mtk_wcn_cmb_stub_clock_fail_dump(void)
;
int mtk_wcn_cmb_stub_reg(struct _CMB_STUB_CB_ *p_stub_cb)
;
int mtk_wcn_cmb_stub_unreg(void)
;
static long wmt_plat_thermal_ctrl(VOID)
;
static INT32 wmt_plat_assert_ctrl(VOID)
;
static VOID wmt_plat_clock_fail_dump(VOID)
;
VOID wmt_plat_thermal_ctrl_cb_reg(thermal_query_ctrl_cb thermal_query_ctrl)
;
VOID wmt_plat_trigger_assert_cb_reg(trigger_assert_cb trigger_assert)
;
INT32 wmt_plat_deinit(VOID)
;
VOID mtk_wcn_consys_clock_fail_dump(VOID)
;
LONG wmt_dev_tm_temp_query(VOID)
;
static VOID WMT_exit(VOID)
;
INT32 wmt_lib_register_thermal_ctrl_cb(thermal_query_ctrl_cb thermal_ctrl)
;
INT32 wmt_lib_register_trigger_assert_cb(trigger_assert_cb trigger_assert)
;
INT32 wmt_lib_trigger_assert(ENUM_WMTDRV_TYPE_T type, UINT32 reason)
;
INT32 wmt_lib_deinit(VOID)
;

static void dump_stack(void) {}
static struct wmt_platform_bridge bridge;
static DEFINE_SPINLOCK(bridge_lock);
static DEFINE_MUTEX(bridge_update_lock);
static DECLARE_WAIT_QUEUE_HEAD(bridge_idle);
static atomic_t bridge_users = ATOMIC_INIT(0);

/* The reference covers the complete callback, including any sleeping work. */
static bool wmt_platform_bridge_get(struct wmt_platform_bridge *cb)
{
	unsigned long flags;
	bool active;

	spin_lock_irqsave(&bridge_lock, flags);
	*cb = bridge;
	active = cb->thermal_query_cb || cb->trigger_assert_cb || cb->clock_fail_dump_cb;
	if (active)
		atomic_inc(&bridge_users);
	spin_unlock_irqrestore(&bridge_lock, flags);
	return active;
}

static void wmt_platform_bridge_put(void)
{
	if (atomic_dec_and_test(&bridge_users))
		wake_up_all(&bridge_idle);
}

/* bridge_update_lock keeps registration from reopening admission while draining. */
static void wmt_platform_bridge_drain(void)
{
	unsigned long flags;

	spin_lock_irqsave(&bridge_lock, flags);
	memset(&bridge, 0, sizeof(bridge));
	spin_unlock_irqrestore(&bridge_lock, flags);
	wait_event(bridge_idle, atomic_read(&bridge_users) == 0);
}

void wmt_export_platform_bridge_register(struct wmt_platform_bridge *cb)
{
	unsigned long flags;

	if (unlikely(!cb))
		return;
	mutex_lock(&bridge_update_lock);
	wmt_platform_bridge_drain();
	spin_lock_irqsave(&bridge_lock, flags);
	bridge = *cb;
	spin_unlock_irqrestore(&bridge_lock, flags);
	mutex_unlock(&bridge_update_lock);
	CONNADP_INFO_FUNC("\n");
}
EXPORT_SYMBOL(wmt_export_platform_bridge_register);

void wmt_export_platform_bridge_unregister(void)
{
	mutex_lock(&bridge_update_lock);
	wmt_platform_bridge_drain();
	mutex_unlock(&bridge_update_lock);
	CONNADP_INFO_FUNC("\n");
}
EXPORT_SYMBOL(wmt_export_platform_bridge_unregister);

int mtk_wcn_cmb_stub_query_ctrl(void)
{
	struct wmt_platform_bridge cb;
	bool active;
	int ret = -1;

	CONNADP_DBG_FUNC("\n");
	active = wmt_platform_bridge_get(&cb);
	if (active && cb.thermal_query_cb)
		ret = cb.thermal_query_cb();
	else
		CONNADP_WARN_FUNC("Thermal query not registered\n");
	if (active)
		wmt_platform_bridge_put();
	return ret;
}

int mtk_wcn_cmb_stub_trigger_assert(void)
{
	struct wmt_platform_bridge cb;
	bool active;
	int ret = -1;

	CONNADP_DBG_FUNC("\n");
	/* dump backtrace for checking assert reason */
	dump_stack();
	active = wmt_platform_bridge_get(&cb);
	if (active && cb.trigger_assert_cb)
		ret = cb.trigger_assert_cb();
	else
		CONNADP_WARN_FUNC("Trigger assert not registered\n");
	if (active)
		wmt_platform_bridge_put();
	return ret;
}

void mtk_wcn_cmb_stub_clock_fail_dump(void)
{
	struct wmt_platform_bridge cb;
	bool active;

	CONNADP_DBG_FUNC("\n");
	active = wmt_platform_bridge_get(&cb);
	if (active && cb.clock_fail_dump_cb)
		cb.clock_fail_dump_cb();
	else
		CONNADP_WARN_FUNC("Clock fail dump not registered\n");
	if (active)
		wmt_platform_bridge_put();
}



static void record_cleanup(void)
{
    atomic_fetch_add(&cleanup_calls, 1);
    if (atomic_load(&module_callbacks))
        atomic_store(&cleanup_while_callback, true);
}

static int osal_thread_destroy(OSAL_THREAD *thread) { record_cleanup(); return 0; }
static void osal_timer_stop_sync(OSAL_TIMER *timer) { record_cleanup(); }
static void wmt_lib_drain_op_queue(OSAL_OP_Q *queue) { record_cleanup(); }
static void cancel_work_sync(struct work_struct *work) { record_cleanup(); }
static void osal_op_history_deinit(struct osal_op_history *history) { record_cleanup(); }
static void wmt_idc_deinit(void) { record_cleanup(); }
static int wmt_lib_ps_deinit(void) { record_cleanup(); return 0; }
static void osal_event_deinit(OSAL_EVENT *event) { record_cleanup(); }
static void osal_signal_deinit(OSAL_SIGNAL *signal) { record_cleanup(); }
static void osal_sleepable_lock_deinit(OSAL_SLEEPABLE_LOCK *lock) { record_cleanup(); }
static void osal_unsleepable_lock_deinit(OSAL_UNSLEEPABLE_LOCK *lock) { record_cleanup(); }
static void wmt_lib_rom_patch_info_free(void) { record_cleanup(); }
/* Broker behavior is covered by test_wmt_command_v2.py. */
static void wmt_lib_cmd_shutdown(void) { record_cleanup(); }
static int wmt_core_deinit(void) { record_cleanup(); return 0; }
static int wmt_conf_deinit(void) { record_cleanup(); return 0; }
static void *osal_memset(void *address, int value, size_t size)
{ record_cleanup(); return memset(address, value, size); }
static int wmt_detect_get_chip_type(void) { return WMT_CHIP_TYPE_SOC; }
static int mtk_wcn_consys_hw_deinit(void) { record_cleanup(); return 0; }
static int mtk_wcn_cmb_hw_deinit(void) { record_cleanup(); return 0; }
static int osal_wake_lock_deinit(OSAL_WAKE_LOCK *lock) { record_cleanup(); return 0; }
static void fb_unregister_client(struct notifier_block *notifier) { record_cleanup(); }
static void wmt_dev_patch_info_free(void) { record_cleanup(); }
static void mtk_wcn_stp_uart_drv_exit(void) { record_cleanup(); }
static void mtk_wcn_stp_sdio_drv_exit(void) { record_cleanup(); }
static void wmt_dev_bgw_desense_deinit(void) { record_cleanup(); }
#define WMT_STEP_DEINIT_FUNC() record_cleanup()
static void wmt_dev_dbg_remove(void) { record_cleanup(); }
static void wmt_dev_proc_for_aee_remove(void) { record_cleanup(); }
static void wmt_dev_proc_for_dump_info_remove(void) { record_cleanup(); }
static void device_destroy(struct class *class_, dev_t dev) { record_cleanup(); }
static void class_destroy(struct class *class_) { record_cleanup(); }
static void cdev_del(struct cdev *dev) { record_cleanup(); }
static void unregister_chrdev_region(dev_t dev, int count) { record_cleanup(); }
static void stp_drv_exit(void) { record_cleanup(); }
static void mtk_wcn_hif_sdio_driver_exit(void) { record_cleanup(); }
static void osal_lock_unsleepable_lock(OSAL_UNSLEEPABLE_LOCK *lock)
{ CHECK(pthread_mutex_lock(&lock->native) == 0); }
static void osal_unlock_unsleepable_lock(OSAL_UNSLEEPABLE_LOCK *lock)
{ CHECK(pthread_mutex_unlock(&lock->native) == 0); }
static void do_gettimeofday(struct timeval *now) { CHECK(gettimeofday(now, NULL) == 0); }
static int wmt_dev_tra_poll(void) { return 0; }

static int mtk_wcn_wmt_therm_ctrl(int operation)
{
    CHECK(!irq_disabled && !spin_depth);
    atomic_fetch_add(&thermal_commands, 1);
    atomic_fetch_add(&operation_references, 1);
    if (operation == WMTTHERM_READ && nested_assertion)
        CHECK(mtk_wcn_cmb_stub_trigger_assert() == -1);
    if (operation == WMTTHERM_READ && pause_thermal_command)
        pause_callback(0);
    atomic_fetch_sub(&operation_references, 1);
    return operation == WMTTHERM_READ ? 42 : 0;
}

static int wmt_lib_trigger_assert_keyword(ENUM_WMTDRV_TYPE_T type, UINT32 reason, PUINT8 keyword)
{
    CHECK(!spin_depth && !irq_disabled);
    CHECK(type == WMTDRV_TYPE_WMT && reason == 45 && keyword == NULL);
    atomic_fetch_add(&assertion_calls, 1);
    return -1;
}

static void host_step_action(int point)
{
    CHECK(!spin_depth && point == STEP_TRIGGER_POINT_WHEN_CLOCK_FAIL);
    atomic_fetch_add(&clock_calls, 1);
}
#define WMT_STEP_DO_ACTIONS_FUNC(point) host_step_action(point)

#ifdef MTK_WCN_REMOVE_KERNEL_MODULE
int mtk_wcn_cmb_stub_query_ctrl(void)
#else
static int _mtk_wcn_cmb_stub_query_ctrl(void)
#endif
{
	signed long temp = 0;

	if (cmb_stub_thermal_ctrl_cb)
		temp = (*cmb_stub_thermal_ctrl_cb) ();
	else
		CMB_STUB_LOG_PR_WARN("[cmb_stub] thermal_ctrl_cb null\n");

	return temp;
}

#ifdef MTK_WCN_REMOVE_KERNEL_MODULE
int mtk_wcn_cmb_stub_trigger_assert(void)
#else
static int _mtk_wcn_cmb_stub_trigger_assert(void)
#endif
{
	int ret = 0;

	if (cmb_stub_trigger_assert_cb)
		ret = (*cmb_stub_trigger_assert_cb) ();
	else
		CMB_STUB_LOG_PR_WARN("[cmb_stub] trigger_assert_cb null\n");

	return ret;
}

void _mtk_wcn_cmb_stub_clock_fail_dump(void)
{
	if (cmb_stub_clock_fail_dump_cb)
		(*cmb_stub_clock_fail_dump_cb) ();
	else
		CMB_STUB_LOG_PR_WARN("[cmb_stub] clock_fail_dump_cb null\n");
}

int mtk_wcn_cmb_stub_reg(struct _CMB_STUB_CB_ *p_stub_cb)
{
#ifndef MTK_WCN_REMOVE_KERNEL_MODULE
	struct wmt_platform_bridge pbridge;

	memset(&pbridge, 0, sizeof(struct wmt_platform_bridge));
#endif

	if ((!p_stub_cb)
	    || (p_stub_cb->size != sizeof(struct _CMB_STUB_CB_))) {
		CMB_STUB_LOG_PR_WARN("[cmb_stub] invalid p_stub_cb:0x%p size(%d)\n",
				  p_stub_cb, (p_stub_cb) ? p_stub_cb->size : 0);
		return -1;
	}

	CMB_STUB_LOG_PR_DBG("[cmb_stub] registered, p_stub_cb:0x%p size(%d)\n",
			p_stub_cb, p_stub_cb->size);

	cmb_stub_aif_ctrl_cb = p_stub_cb->aif_ctrl_cb;
	cmb_stub_func_ctrl_cb = p_stub_cb->func_ctrl_cb;
	cmb_stub_thermal_ctrl_cb = p_stub_cb->thermal_query_cb;
	cmb_stub_trigger_assert_cb = p_stub_cb->trigger_assert_cb;
	cmb_stub_deep_idle_ctrl_cb = p_stub_cb->deep_idle_ctrl_cb;
	cmb_stub_do_reset_cb = p_stub_cb->wmt_do_reset_cb;
	cmb_stub_clock_fail_dump_cb = p_stub_cb->clock_fail_dump_cb;

#ifndef MTK_WCN_REMOVE_KERNEL_MODULE
	pbridge.thermal_query_cb = _mtk_wcn_cmb_stub_query_ctrl;
	pbridge.trigger_assert_cb = _mtk_wcn_cmb_stub_trigger_assert;
	pbridge.clock_fail_dump_cb = _mtk_wcn_cmb_stub_clock_fail_dump;
	wmt_export_platform_bridge_register(&pbridge);
#endif

	return 0;
}

int mtk_wcn_cmb_stub_unreg(void)
{
#ifndef MTK_WCN_REMOVE_KERNEL_MODULE
	wmt_export_platform_bridge_unregister();
#endif

	cmb_stub_aif_ctrl_cb = NULL;
	cmb_stub_func_ctrl_cb = NULL;
	cmb_stub_thermal_ctrl_cb = NULL;
	cmb_stub_trigger_assert_cb = NULL;
	cmb_stub_deep_idle_ctrl_cb = NULL;
	cmb_stub_do_reset_cb = NULL;
	cmb_stub_clock_fail_dump_cb = NULL;
	CMB_STUB_LOG_PR_INFO("[cmb_stub] unregistered\n");	/* KERN_DEBUG */

	return 0;
}

static long wmt_plat_thermal_ctrl(VOID)
{
	long temp = 0;

	if (wmt_plat_thermal_query_ctrl_cb)
		temp = (*wmt_plat_thermal_query_ctrl_cb)();

	return temp;
}

static INT32 wmt_plat_assert_ctrl(VOID)
{
	INT32 ret = 0;

	if (wmt_plat_trigger_assert_cb)
		ret = (*wmt_plat_trigger_assert_cb)(WMTDRV_TYPE_WMT, 45);

	return ret;
}

static VOID wmt_plat_clock_fail_dump(VOID)
{
	mtk_wcn_consys_clock_fail_dump();
}

VOID wmt_plat_thermal_ctrl_cb_reg(thermal_query_ctrl_cb thermal_query_ctrl)
{
	wmt_plat_thermal_query_ctrl_cb = thermal_query_ctrl;
}

VOID wmt_plat_trigger_assert_cb_reg(trigger_assert_cb trigger_assert)
{
	wmt_plat_trigger_assert_cb = trigger_assert;
}

INT32 wmt_plat_deinit(VOID)
{
	INT32 iret;
	INT32 hw_ret;

	if (!g_wmt_plat_initialized)
		return 0;
	g_wmt_plat_initialized = false;

	/* Withdraw callbacks before releasing the resources they use. */
	iret = mtk_wcn_cmb_stub_unreg();
	if (g_wmt_plat_chip_type == WMT_CHIP_TYPE_SOC)
		hw_ret = mtk_wcn_consys_hw_deinit();
	else
		hw_ret = mtk_wcn_cmb_hw_deinit();
	if (!iret)
		iret = hw_ret;
#ifdef CFG_WMT_WAKELOCK_SUPPORT
	osal_sleepable_lock_deinit(&gOsSLock);
	osal_wake_lock_deinit(&wmt_wake_lock);
	WMT_DBG_FUNC("destroy wmt_wake_lock\n");
#endif
	WMT_DBG_FUNC("WMT-PLAT: ALPS platform deinit (%d)\n", iret);

	return iret;
}

VOID mtk_wcn_consys_clock_fail_dump(VOID)
{
	if (wmt_consys_ic_ops->consys_ic_clock_fail_dump)
		wmt_consys_ic_ops->consys_ic_clock_fail_dump();
	WMT_STEP_DO_ACTIONS_FUNC(STEP_TRIGGER_POINT_WHEN_CLOCK_FAIL);
}

LONG wmt_dev_tm_temp_query(VOID)
{
#define HISTORY_NUM       3
#define REFRESH_TIME    300	/* sec */

	static INT32 s_temp_table[HISTORY_NUM] = { 99 };	/* not query yet. */
	static INT32 s_idx_temp_table;
	static struct timeval s_query_time;

	INT32 temp_table[HISTORY_NUM];
	INT32 idx_temp_table;
	struct timeval query_time;

	struct timeval now_time;
	INT32 current_temp = 0;
	INT32 index = 0;
	LONG return_temp = 0;
	INT8 query_cond = 0;

	/* Let us work on the copied version of function static variables */
	osal_lock_unsleepable_lock(&g_temp_query_spinlock);
	osal_memcpy(temp_table, s_temp_table, sizeof(s_temp_table));
	osal_memcpy(&query_time, &s_query_time, sizeof(struct timeval));
	idx_temp_table = s_idx_temp_table;
	osal_unlock_unsleepable_lock(&g_temp_query_spinlock);

	/* Query condition 1: */
	/* If we have the high temperature records on the past, we continue to query/monitor */
	/* the real temperature until cooling */
	for (index = 0; index < HISTORY_NUM; index++) {
		if (temp_table[index] >= gTemperatureThreshold) {
			query_cond = 1;
			WMT_DBG_FUNC
				("temperature table is still initial value, we should query temp temperature..\n");
		}
	}

	do_gettimeofday(&now_time);
#if 1
	/* Query condition 2: */
	/* Moniter the bus activity to decide if we have the need to query temperature. */
	if (!query_cond) {
		if (wmt_dev_tra_poll() == 0) {
			query_cond = 1;
			WMT_DBG_FUNC("traffic , we must query temperature..\n");
		} else if (temp_table[idx_temp_table] >= gTemperatureThreshold) {
			WMT_INFO_FUNC("temperature maybe greater than %d, query temperature\n", gTemperatureThreshold);
			query_cond = 1;
		} else
			WMT_DBG_FUNC("idle traffic ....\n");

		/* only WIFI tx power might make temperature varies largely */
#if 0
		if (!query_cond) {
			last_access_time = wmt_dev_tra_uart_poll();
			if (jiffies_to_msecs(last_access_time) < TIME_THRESHOLD_TO_TEMP_QUERY) {
				query_cond = 1;
				WMT_DBG_FUNC("uart busy traffic , we must query temperature..\n");
			} else {
				WMT_DBG_FUNC("uart still idle traffic , we don't query temp temperature..\n");
			}
		}
#endif
	}
#endif
	/* Query condition 3: */
	/* If the query time exceeds the a certain of period, refresh temp table. */
	/*  */
	if (!query_cond) {
		/* time overflow, we refresh temp table again for simplicity! */
		if ((now_time.tv_sec < query_time.tv_sec) ||
		    ((now_time.tv_sec > query_time.tv_sec) &&
			(now_time.tv_sec - query_time.tv_sec) > REFRESH_TIME)) {
			query_cond = 1;

			WMT_INFO_FUNC
				("It is long time (prev(%lu), now(%lu), > %d sec) not to query, query temp again..\n",
				 query_time.tv_sec, now_time.tv_sec, REFRESH_TIME);
			for (index = 0; index < HISTORY_NUM; index++)
				temp_table[index] = 99;

		}
	}

	if (query_cond) {
		/* update the temperature record */
		mtk_wcn_wmt_therm_ctrl(WMTTHERM_ENABLE);
		current_temp = mtk_wcn_wmt_therm_ctrl(WMTTHERM_READ);
		mtk_wcn_wmt_therm_ctrl(WMTTHERM_DISABLE);

		/* Only update temperature if our index hasn't been modified by the concurrent thread */
		osal_lock_unsleepable_lock(&g_temp_query_spinlock);
		if (idx_temp_table == s_idx_temp_table) {
			osal_memcpy(s_temp_table, temp_table, sizeof(s_temp_table));
			s_idx_temp_table = (s_idx_temp_table + 1) % HISTORY_NUM;
			s_temp_table[s_idx_temp_table] = current_temp;
			do_gettimeofday(&s_query_time);
			index = -1;
		} else {
			index = s_idx_temp_table;
		}
		osal_unlock_unsleepable_lock(&g_temp_query_spinlock);

		if (index == -1) {
			WMT_INFO_FUNC("[Thermal] current_temp = 0x%x\n", (current_temp & 0xFF));
		} else {
			WMT_ERR_FUNC("Temperature(0x%x) update failed due to modified idx_temp_table(%d, %d)",
				(current_temp & 0xFF), idx_temp_table, index);
		}
	} else {
		/* Only update temperature if our index hasn't been modified by the concurrent thread */
		osal_lock_unsleepable_lock(&g_temp_query_spinlock);
		if (idx_temp_table == s_idx_temp_table) {
			current_temp = s_temp_table[s_idx_temp_table];
			s_idx_temp_table = (s_idx_temp_table + 1) % HISTORY_NUM;
			s_temp_table[s_idx_temp_table] = current_temp;
			index = -1;
		} else {
			/* Return the last valid temperature which has just been modified by the concurrent thread */
			current_temp = s_temp_table[s_idx_temp_table];
			index = s_idx_temp_table;
		}
		osal_unlock_unsleepable_lock(&g_temp_query_spinlock);
		if (index != -1) {
			WMT_DBG_FUNC("Use last valid temperature (0x%x) due to modified idx_temp_table(%d, %d)",
				(current_temp & 0xFF), idx_temp_table, index);
		}
	}

	/*  */
	/* Dump information */
	/*  */
	if (gWmtDbgLvl >= WMT_LOG_DBG) {
		osal_lock_unsleepable_lock(&g_temp_query_spinlock);
		WMT_DBG_FUNC("[Thermal] s_idx_temp_table = %d, idx_temp_table = %d\n",
			s_idx_temp_table, idx_temp_table);
		WMT_DBG_FUNC("[Thermal] now.time = %lu, s_query.time = %lu, query.time = %lu, REFRESH_TIME = %d\n",
			now_time.tv_sec, s_query_time.tv_sec, query_time.tv_sec, REFRESH_TIME);

		WMT_DBG_FUNC("[0] = %d, [1] = %d, [2] = %d\n----\n",
			s_temp_table[0], s_temp_table[1], s_temp_table[2]);
		osal_unlock_unsleepable_lock(&g_temp_query_spinlock);
	}

	return_temp = ((current_temp & 0x80) == 0x0) ? current_temp : (-1) * (current_temp & 0x7f);

	return return_temp;
}

static VOID WMT_exit(VOID)
{
	dev_t dev = MKDEV(gWmtMajor, 0);

	if (gWmtInitStatus != WMT_INIT_DONE)
		return;

	/* Thermal callbacks can outlive their individual WMT operation references. */
	wmt_export_platform_bridge_unregister();

	osal_unsleepable_lock_deinit(&g_temp_query_spinlock);
	osal_sleepable_lock_deinit(&g_aee_read_lock);
	osal_sleepable_lock_deinit(&g_dump_info_read_lock);
#ifdef CONFIG_EARLYSUSPEND
	unregister_early_suspend(&wmt_early_suspend_handler);
	WMT_INFO_FUNC("unregister_early_suspend finished\n");
#else
	fb_unregister_client(&wmt_fb_notifier);
#endif /* CONFIG_EARLYSUSPEND */

	mtk_wcn_stp_uart_drv_exit();
	mtk_wcn_stp_sdio_drv_exit();

	wmt_dev_bgw_desense_deinit();

	wmt_lib_register_thermal_ctrl_cb(NULL);

	wmt_lib_deinit();
	WMT_STEP_DEINIT_FUNC();

#if CFG_WMT_DBG_SUPPORT
	wmt_dev_dbg_remove();
#endif

#if CFG_WMT_PROC_FOR_AEE
	wmt_dev_proc_for_aee_remove();
#endif

#if CFG_WMT_PROC_FOR_DUMP_INFO
	wmt_dev_proc_for_dump_info_remove();
#endif

#if WMT_CREATE_NODE_DYNAMIC
	if (wmt_dev) {
		device_destroy(wmt_class, dev);
		wmt_dev = NULL;
	}
	if (wmt_class) {
		class_destroy(wmt_class);
		wmt_class = NULL;
	}
#endif
	cdev_del(&gWmtCdev);
	unregister_chrdev_region(dev, WMT_DEV_NUM);
	gWmtMajor = -1;

	stp_drv_exit();
	mtk_wcn_hif_sdio_driver_exit();
	gWmtInitStatus = WMT_INIT_NOT_START;
	WMT_INFO_FUNC("done\n");
}

INT32 wmt_lib_register_thermal_ctrl_cb(thermal_query_ctrl_cb thermal_ctrl)
{
	wmt_plat_thermal_ctrl_cb_reg(thermal_ctrl);
	return 0;
}

INT32 wmt_lib_register_trigger_assert_cb(trigger_assert_cb trigger_assert)
{
	wmt_plat_trigger_assert_cb_reg(trigger_assert);
	return 0;
}

INT32 wmt_lib_trigger_assert(ENUM_WMTDRV_TYPE_T type, UINT32 reason)
{
	return wmt_lib_trigger_assert_keyword(type, reason, NULL);
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


static int callback_index(void *function) NO_INSTRUMENT;
static int callback_index(void *function)
{
    if (function == (void *)_mtk_wcn_cmb_stub_query_ctrl) return 0;
    if (function == (void *)_mtk_wcn_cmb_stub_trigger_assert) return 1;
    if (function == (void *)_mtk_wcn_cmb_stub_clock_fail_dump) return 2;
    return -1;
}

void __cyg_profile_func_enter(void *function, void *caller)
{
    int kind = callback_index(function);
    if (kind >= 0) {
        CHECK(!spin_depth);
        atomic_fetch_add(&module_callbacks, 1);
        if (atomic_load(&pause_on_entry[kind]))
            pause_callback(kind);
    }
}

void __cyg_profile_func_exit(void *function, void *caller)
{
    int kind = callback_index(function);
    if (kind >= 0) {
        if (atomic_load(&pause_on_return[kind]))
            pause_callback(kind);
        CHECK(atomic_fetch_sub(&module_callbacks, 1) > 0);
        progress();
    }
}

static void register_actual_chain(void)
{
    struct _CMB_STUB_CB_ callbacks = {0};
    callbacks.size = sizeof(callbacks);
    callbacks.thermal_query_cb = wmt_plat_thermal_ctrl;
    callbacks.trigger_assert_cb = wmt_plat_assert_ctrl;
    callbacks.clock_fail_dump_cb = wmt_plat_clock_fail_dump;
    CHECK(mtk_wcn_cmb_stub_reg(&callbacks) == 0);
    CHECK(wmt_lib_register_thermal_ctrl_cb(wmt_dev_tm_temp_query) == 0);
    CHECK(wmt_lib_register_trigger_assert_cb(wmt_lib_trigger_assert) == 0);
}

static void prepare_lifecycle(void)
{
    gWmtInitStatus = WMT_INIT_DONE;
    g_wmt_platform_initialized = true;
    g_wmt_resources_initialized = true;
    g_wmt_core_initialized = true;
    g_wmt_ps_initialized = true;
    g_wmt_idc_initialized = true;
    g_wmt_op_pool_initialized = true;
    g_wmt_worker_timer_initialized = true;
    g_wmt_utc_timer_initialized = true;
    g_wmt_assert_work_initialized = true;
    gDevWmt.rWmtGenConf.cfgExist = 1;
#ifdef HOST_HAS_PLATFORM_OWNER
    g_wmt_plat_initialized = true;
    g_wmt_plat_chip_type = WMT_CHIP_TYPE_SOC;
#endif
}

static int replacement_query(void)
{
    CHECK(!spin_depth);
    atomic_fetch_add(&replacement_calls, 1);
    return 73;
}

enum operation { QUERY, ASSERTION, CLOCK, UNREGISTER, REGISTER, OUTER_EXIT, LIBRARY_EXIT };
struct job {
    pthread_t thread;
    enum operation operation;
    int result;
    atomic_bool done;
};

static void *run_job(void *argument)
{
    struct job *job = argument;
    struct wmt_platform_bridge replacement = {.thermal_query_cb = replacement_query};
    switch (job->operation) {
    case QUERY: job->result = mtk_wcn_cmb_stub_query_ctrl(); break;
    case ASSERTION: job->result = mtk_wcn_cmb_stub_trigger_assert(); break;
    case CLOCK: mtk_wcn_cmb_stub_clock_fail_dump(); break;
    case UNREGISTER: wmt_export_platform_bridge_unregister(); break;
    case REGISTER: wmt_export_platform_bridge_register(&replacement); break;
    case OUTER_EXIT: WMT_exit(); break;
    case LIBRARY_EXIT: job->result = wmt_lib_deinit(); break;
    }
    atomic_store(&job->done, true);
    progress();
    return NULL;
}

static void start_job(struct job *job, enum operation operation)
{
    job->operation = operation;
    atomic_init(&job->done, false);
    CHECK(pthread_create(&job->thread, NULL, run_job, job) == 0);
}

static void join_job(struct job *job)
{
    CHECK(pthread_join(job->thread, NULL) == 0);
    CHECK(atomic_load(&job->done));
}

static void require_blocked(struct job *writer, int previous_drains, bool before_cleanup)
{
    AWAIT(atomic_load(&writer->done) || atomic_load(&blocked_drains) > previous_drains);
    fprintf(stderr, "writer_returned=%d active_module_callbacks=%d operation_refs=%d cleanup_calls=%d\n",
            atomic_load(&writer->done), atomic_load(&module_callbacks),
            atomic_load(&operation_references), atomic_load(&cleanup_calls));
    CHECK(!atomic_load(&writer->done));
    CHECK(atomic_load(&module_callbacks) > 0);
    if (before_cleanup) CHECK(atomic_load(&cleanup_calls) == 0);
}

static void require_closed(void)
{
    int commands = atomic_load(&thermal_commands), assertions = atomic_load(&assertion_calls);
    int clocks = atomic_load(&clock_calls);
    CHECK(mtk_wcn_cmb_stub_query_ctrl() == -1);
    CHECK(mtk_wcn_cmb_stub_trigger_assert() == -1);
    mtk_wcn_cmb_stub_clock_fail_dump();
    CHECK(atomic_load(&thermal_commands) == commands);
    CHECK(atomic_load(&assertion_calls) == assertions);
    CHECK(atomic_load(&clock_calls) == clocks);
}

int main(int argc, char **argv)
{
    CHECK(argc == 2);
    int test = atoi(argv[1]);
    struct job reader[3] = {0}, writer = {0}, second = {0};
    if (test == 0) {
        require_closed();
        wmt_export_platform_bridge_unregister();
        wmt_export_platform_bridge_unregister();
        wmt_export_platform_bridge_register(NULL);
        require_closed();
    } else if (test == 1) {
        register_actual_chain();
        CHECK(mtk_wcn_cmb_stub_query_ctrl() == 42);
        CHECK(mtk_wcn_cmb_stub_trigger_assert() == -1);
        mtk_wcn_cmb_stub_clock_fail_dump();
        CHECK(atomic_load(&thermal_commands) == 3);
        CHECK(atomic_load(&assertion_calls) == 1 && atomic_load(&clock_calls) == 1);
    } else if ((test >= 2 && test <= 7) || (test >= 14 && test <= 16) || test == 18) {
        register_actual_chain();
        int first = test == 4 ? 1 : test == 5 ? 2 : 0;
        int count = test == 6 ? 3 : 1;
        pause_thermal_command = test == 2;
        for (int kind = first; kind < first + count; kind++) {
            atomic_store(&pause_on_entry[kind], test == 18);
            atomic_store(&pause_on_return[kind], !pause_thermal_command && test != 18);
            start_job(&reader[kind], (enum operation)kind);
            AWAIT(atomic_load(&arrived[kind]));
        }
        bool lifecycle = test >= 14 && test <= 16;
        if (lifecycle) prepare_lifecycle();
        if (test == 16) g_wmt_platform_initialized = false;
        int old_drains = atomic_load(&blocked_drains);
        start_job(&writer, test == 14 ? OUTER_EXIT : lifecycle ? LIBRARY_EXIT : UNREGISTER);
        require_blocked(&writer, old_drains, lifecycle);
        if (test != 2) CHECK(atomic_load(&operation_references) == 0);
        require_closed();
        for (int kind = first; kind < first + count; kind++) {
            release_callback(kind);
            join_job(&reader[kind]);
            if (kind + 1 < first + count) CHECK(!atomic_load(&writer.done));
        }
        join_job(&writer);
        CHECK(!atomic_load(&cleanup_while_callback));
        if (lifecycle) CHECK(atomic_load(&cleanup_calls) > 0);
    } else if (test == 8 || test == 9 || test == 10) {
        register_actual_chain();
        atomic_store(&pause_on_return[0], true);
        start_job(&reader[0], QUERY);
        AWAIT(atomic_load(&arrived[0]));
        int old_drains = atomic_load(&blocked_drains);
        start_job(&writer, test == 8 ? REGISTER : UNREGISTER);
        require_blocked(&writer, old_drains, false);
        require_closed();
        if (test != 8) {
            int old_writers = atomic_load(&blocked_writers);
            start_job(&second, test == 9 ? REGISTER : UNREGISTER);
            AWAIT(atomic_load(&second.done) || atomic_load(&blocked_writers) > old_writers);
            CHECK(!atomic_load(&second.done));
            require_closed();
        }
        release_callback(0);
        join_job(&reader[0]);
        join_job(&writer);
        if (test != 8) join_job(&second);
        if (test != 10) {
            CHECK(mtk_wcn_cmb_stub_query_ctrl() == 73);
            CHECK(atomic_load(&replacement_calls) == 1);
        }
    } else if (test == 11) {
        register_actual_chain();
        nested_assertion = true;
        CHECK(mtk_wcn_cmb_stub_query_ctrl() == 42);
        CHECK(atomic_load(&assertion_calls) == 1);
    } else if (test == 12) {
        register_actual_chain();
        irq_disabled = true;
        mtk_wcn_cmb_stub_clock_fail_dump();
        CHECK(irq_disabled && !spin_depth);
        irq_disabled = false;
        CHECK(atomic_load(&clock_calls) == 1);
    } else if (test == 13) {
        struct wmt_platform_bridge partial = {.thermal_query_cb = replacement_query};
        wmt_export_platform_bridge_register(&partial);
        CHECK(mtk_wcn_cmb_stub_trigger_assert() == -1);
        mtk_wcn_cmb_stub_clock_fail_dump();
        CHECK(mtk_wcn_cmb_stub_query_ctrl() == 73);
        wmt_export_platform_bridge_unregister();
        require_closed();
    } else if (test == 17) {
        register_actual_chain();
        wmt_export_platform_bridge_unregister();
        require_closed();
        register_actual_chain();
        CHECK(mtk_wcn_cmb_stub_query_ctrl() == 42);
    } else {
        CHECK(false);
    }
    wmt_export_platform_bridge_unregister();
    require_closed();
    CHECK(!atomic_load(&module_callbacks) && !atomic_load(&operation_references));
    printf("PASS: drained=%d serialized_writers=%d cleanup=%d\n", atomic_load(&blocked_drains),
           atomic_load(&blocked_writers), atomic_load(&cleanup_calls));
    return 0;
}
