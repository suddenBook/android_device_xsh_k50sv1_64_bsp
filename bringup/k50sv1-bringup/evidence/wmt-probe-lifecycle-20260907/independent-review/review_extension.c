/* Host-only extension; complete production functions fill the source markers. */
typedef struct { char name[32]; bool initialized; } OSAL_WAKE_LOCK;
typedef struct { bool initialized; } OSAL_SLEEPABLE_LOCK;
struct pwr_seq_time;
typedef struct pwr_seq_time *P_PWR_SEQ_TIME;
static OSAL_WAKE_LOCK wmt_wake_lock;
static OSAL_SLEEPABLE_LOCK gOsSLock;
static struct { bool lock; } g_bgf_irq_lock;
#define CFG_WMT_WAKELOCK_SUPPORT 1
#define osal_strcpy strcpy
#define WMT_ERR_FUNC(...) ((void)0)
#define WMT_DBG_FUNC(...) ((void)0)
#define CMB_STUB_LOG_PR_WARN(...) ((void)0)
#define CMB_STUB_LOG_PR_INFO(...) ((void)0)
#define CMB_STUB_LOG_PR_DBG(...) ((void)0)
#define CONNADP_INFO_FUNC(...) ((void)0)
#define CONNADP_DBG_FUNC(...) ((void)0)
#define CONNADP_WARN_FUNC(...) ((void)0)
#define dump_stack() ((void)0)
#define unlikely(value) (value)

typedef struct { atomic_int value; } atomic_t;
#define ATOMIC_INIT(initial) { ATOMIC_VAR_INIT(initial) }
#define atomic_read(pointer) atomic_load(&(pointer)->value)
#define atomic_inc(pointer) ((void)atomic_fetch_add(&(pointer)->value, 1))
#define atomic_dec_and_test(pointer) (atomic_fetch_sub(&(pointer)->value, 1) == 1)
#define DEFINE_SPINLOCK(name) pthread_mutex_t name = PTHREAD_MUTEX_INITIALIZER
#define DEFINE_MUTEX(name) pthread_mutex_t name = PTHREAD_MUTEX_INITIALIZER
#define mutex_lock(pointer) assert(pthread_mutex_lock(pointer) == 0)
#define mutex_unlock(pointer) assert(pthread_mutex_unlock(pointer) == 0)
#define spin_lock_irqsave(pointer, flags) do { (flags) = 0; mutex_lock(pointer); } while (0)
#define spin_unlock_irqrestore(pointer, flags) do { (void)(flags); mutex_unlock(pointer); } while (0)
struct review_wait_queue { pthread_mutex_t mutex; pthread_cond_t condition; };
#define DECLARE_WAIT_QUEUE_HEAD(name) struct review_wait_queue name = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER }
static pthread_mutex_t review_gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t review_changed = PTHREAD_COND_INITIALIZER;
static bool review_entered, review_release, review_waiting, review_finished;
static int review_kind;
static unsigned int review_callback_calls;

static void review_note_wait(void)
{
    mutex_lock(&review_gate);
    review_waiting = true;
    assert(pthread_cond_broadcast(&review_changed) == 0);
    mutex_unlock(&review_gate);
}

#define wait_event(queue, predicate) do { \
    mutex_lock(&(queue).mutex); \
    while (!(predicate)) { \
        review_note_wait(); \
        assert(pthread_cond_wait(&(queue).condition, &(queue).mutex) == 0); \
    } \
    mutex_unlock(&(queue).mutex); \
} while (0)

static void wake_up_all(struct review_wait_queue *queue)
{
    mutex_lock(&queue->mutex);
    assert(pthread_cond_broadcast(&queue->condition) == 0);
    mutex_unlock(&queue->mutex);
}

static int osal_wake_lock_init(OSAL_WAKE_LOCK *lock)
{ assert(!lock->initialized); lock->initialized = true; return 0; }
static void osal_sleepable_lock_init(OSAL_SLEEPABLE_LOCK *lock)
{ assert(!lock->initialized); lock->initialized = true; }
static void osal_wake_lock_deinit(OSAL_WAKE_LOCK *lock)
{ assert(!atomic_load(&review_active_callbacks) && lock->initialized); lock->initialized = false; }
static void osal_sleepable_lock_deinit(OSAL_SLEEPABLE_LOCK *lock)
{ assert(!atomic_load(&review_active_callbacks) && lock->initialized); lock->initialized = false; }
static void spin_lock_init(bool *lock) { *lock = false; }
static int mtk_wcn_cmb_hw_init(P_PWR_SEQ_TIME times) { assert(!"unexpected combo backend"); return -EINVAL; }
static int mtk_wcn_cmb_hw_deinit(void) { assert(!"unexpected combo backend"); return -EINVAL; }

/* REVIEW_TYPES */
/* REVIEW_STATES */
/* REVIEW_PROTOTYPES */
/* REVIEW_UNUSED_PAYLOADS */
static ENUM_WMT_CHIP_TYPE wmt_detect_get_chip_type(void) { return WMT_CHIP_TYPE_SOC; }

static int review_payload(void)
{
    healthy();
    atomic_fetch_add(&review_active_callbacks, 1);
    mutex_lock(&review_gate);
    review_callback_calls++;
    review_entered = true;
    assert(pthread_cond_broadcast(&review_changed) == 0);
    while (!review_release)
        assert(pthread_cond_wait(&review_changed, &review_gate) == 0);
    mutex_unlock(&review_gate);
    healthy();
    atomic_fetch_sub(&review_active_callbacks, 1);
    return 73;
}
static long review_thermal_payload(void) { return review_payload(); }
static int review_assert_payload(unsigned int type, unsigned int reason)
{ assert(type == WMTDRV_TYPE_WMT && reason == 45); return review_payload(); }
#define WMT_STEP_DO_ACTIONS_FUNC(point) ((void)review_payload())

/* REVIEW_BRIDGE */
/* REVIEW_FUNCTIONS */

static void *review_reader(void *unused)
{
    if (review_kind == 0)
        assert(mtk_wcn_cmb_stub_query_ctrl() == 73);
    else if (review_kind == 1)
        assert(mtk_wcn_cmb_stub_trigger_assert() == 73);
    else
        mtk_wcn_cmb_stub_clock_fail_dump();
    return NULL;
}

static void *review_teardown(void *unused)
{
    assert(wmt_plat_deinit() == 0);
    mutex_lock(&review_gate);
    review_finished = true;
    assert(pthread_cond_broadcast(&review_changed) == 0);
    mutex_unlock(&review_gate);
    return NULL;
}

static void review_complete_platform_cycle(void)
{
    assert(wmt_plat_init(NULL, 0) == 0);
    healthy();
    assert(g_wmt_plat_initialized && wmt_wake_lock.initialized && gOsSLock.initialized);
    assert(wmt_plat_deinit() == 0);
    assert(!g_wmt_plat_initialized && !wmt_wake_lock.initialized && !gOsSLock.initialized);
    resources_clean();
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    const char *name = argv[1];
    int expected = 0;
    bool use_platform = !strncmp(name, "callback-", 9) || is_case(name, "platform-rejects-deferred-probe");
    clear_failures();
    if (is_case(name, "framework-clock-enomem")) {
        review_framework_errno = -ENOMEM; expected = -ENODEV;
    } else if (is_case(name, "framework-pm-deferred")) {
        review_pm_errno = -EPROBE_DEFER; expected = -ENODEV;
    } else if (is_case(name, "framework-pm-other-error")) {
        /* The actual local platform wrapper ignores non-defer attach errors. */
        review_pm_errno = -ENODEV;
    } else if (is_case(name, "required-regulator-enodev")) {
        fail_regulator = 2; review_regulator_errno = -ENODEV; expected = -ENODEV;
    } else if (is_case(name, "exact-coredump-region")) {
        gConEmiSize = CONSYS_EMI_COREDUMP_OFFSET + CONSYS_EMI_MEM_SIZE;
    } else if (is_case(name, "platform-rejects-deferred-probe")) {
        fail_clock = -EPROBE_DEFER; expected = -EPROBE_DEFER;
    }
    wmt_plat_thermal_ctrl_cb_reg(review_thermal_payload);
    wmt_plat_trigger_assert_cb_reg(review_assert_payload);
    int result = use_platform ? wmt_plat_init(NULL, 0) : mtk_wcn_consys_hw_init();
    fprintf(stderr, "result=%d expected=%d registered=%d bound=%d maps=%u\n",
            result, expected, driver_registered, device_bound, map_attempts);
    assert(result == expected);
    if (expected) {
        resources_clean();
        assert(!g_wmt_plat_initialized && !wmt_wake_lock.initialized && !gOsSLock.initialized);
        assert(mtk_wcn_cmb_stub_query_ctrl() == -1);
        if (review_framework_errno || review_pm_errno)
            assert(map_attempts == 0);
        unsigned int count = unregister_calls;
        assert(wmt_plat_deinit() == 0 && mtk_wcn_consys_hw_deinit() == 0);
        assert(count == unregister_calls);
    } else {
        healthy();
        if (is_case(name, "duplicate-probe-keeps-binding")) {
            unsigned int count = live_allocations;
            assert(mtk_wmt_probe(&device) == -EBUSY);
            assert(g_wmt_probe_result == 0 && live_allocations == count);
            healthy();
        }
        if (!strncmp(name, "callback-", 9)) {
            pthread_t reader, writer;
            review_kind = is_case(name, "callback-thermal-before-devres") ? 0 :
                          is_case(name, "callback-assert-before-devres") ? 1 : 2;
            assert(pthread_create(&reader, NULL, review_reader, NULL) == 0);
            mutex_lock(&review_gate);
            while (!review_entered)
                assert(pthread_cond_wait(&review_changed, &review_gate) == 0);
            mutex_unlock(&review_gate);
            assert(pthread_create(&writer, NULL, review_teardown, NULL) == 0);
            mutex_lock(&review_gate);
            while (!review_waiting && !review_finished)
                assert(pthread_cond_wait(&review_changed, &review_gate) == 0);
            assert(!review_finished);
            assert(atomic_load(&review_active_callbacks) == 1 && !release_checks);
            healthy();
            assert(mtk_wcn_cmb_stub_query_ctrl() == -1);
            assert(mtk_wcn_cmb_stub_trigger_assert() == -1);
            mtk_wcn_cmb_stub_clock_fail_dump();
            assert(review_callback_calls == 1);
            review_release = true;
            assert(pthread_cond_broadcast(&review_changed) == 0);
            mutex_unlock(&review_gate);
            assert(pthread_join(reader, NULL) == 0 && pthread_join(writer, NULL) == 0);
            assert(review_finished && release_checks == 1 && !atomic_load(&review_active_callbacks));
        } else {
            assert(mtk_wcn_consys_hw_deinit() == 0);
        }
        resources_clean();
    }
    clear_failures();
    review_framework_errno = review_pm_errno = 0;
    review_regulator_errno = -EPROBE_DEFER;
    review_complete_platform_cycle();
    assert(wmt_plat_deinit() == 0 && mtk_wcn_consys_hw_deinit() == 0);
    resources_clean();
    printf("PASS %s: real platform init/deinit, bridge/stub and probe devres; releases=%u\n", name, release_checks);
    return 0;
}
