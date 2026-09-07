/* Additional histories against the unchanged, source-derived host fixture. */
#define main retained_fixture_main
#include "test_host.c"
#undef main

static bool extra_case(const char *name)
{
    if (!strcmp(name, "signal-in-wrap-tail-resumes")) {
        REQUIRE(sizeof(gEmiBuf) == 8192);
        set_word(0x24, 100);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        clear_copies();
        set_word(0x24, 7);
        signal_on_copy = true;
        REQUIRE(result_is(invoke(0, 1, 0), -EINTR));
        REQUIRE(trace_bytes == 8192 && copied_count == 1);
        REQUIRE(copied[0].offset == 100 && copied[0].size == 8192);
        REQUIRE(healthy());
        atomic_store(&current->pending, false);
        signal_on_copy = false;
        clear_copies();
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        REQUIRE(trace_bytes == 24482 && copied_count == 4);
        REQUIRE(copied[0].offset == 8292 && copied[0].size == 8192);
        REQUIRE(copied[1].offset == 16484 && copied[1].size == 8192);
        REQUIRE(copied[2].offset == 24676 && copied[2].size == 8091);
        REQUIRE(copied[3].offset == 0 && copied[3].size == 7);
    } else if (!strcmp(name, "disable-between-wrap-segments-resumes")) {
        set_word(0x24, 32764);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        clear_copies();
        set_word(0x24, 7);
        disable_on_copy = true;
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        REQUIRE(trace_bytes == 3 && copied_count == 1);
        REQUIRE(copied[0].offset == 32764 && copied[0].size == 3);
        REQUIRE(healthy());
        disable_on_copy = false;
        set_word(0x40, 1);
        clear_copies();
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        REQUIRE(trace_bytes == 7 && copied_count == 1);
        REQUIRE(copied[0].offset == 0 && copied[0].size == 7);
    } else if (!strcmp(name, "invalid-index-preserves-progress")) {
        set_word(0x24, 123);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        clear_copies();
        set_word(0x24, 32768);
        REQUIRE(result_is(invoke(0, 1, 0), -ERANGE));
        REQUIRE(!trace_bytes && healthy());
        set_word(0x24, 129);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        REQUIRE(trace_bytes == 6 && copied_count == 1 && copied[0].offset == 123);
    } else if (!strcmp(name, "manual-read-preserves-progress")) {
        set_word(0x24, 123);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        clear_copies();
        REQUIRE(result_is(invoke(0x19, 32764, 4096), 0));
        REQUIRE(control_bytes == 256 && trace_bytes == 4096 && copied_count == 2);
        REQUIRE(copied[0].offset == 32764 && copied[0].size == 3);
        REQUIRE(copied[1].offset == 0 && copied[1].size == 4093);
        REQUIRE(healthy());
        clear_copies();
        set_word(0x24, 129);
        REQUIRE(result_is(invoke(0, 1, 0), 0));
        REQUIRE(trace_bytes == 6 && copied_count == 1 && copied[0].offset == 123);
    } else {
        REQUIRE(!"unknown independent review case");
    }
    REQUIRE(atomic_load(&sleep_calls) == 0);
    REQUIRE(healthy());
    return fresh_success();
}

int main(int argc, char **argv)
{
    struct test_task main_task = {0};
    assert(argc == 2);
    current = &main_task;
    assert(pthread_mutex_init(&g_dbg_emi_lock.lock.native, NULL) == 0);
    for (size_t i = 0; i < sizeof(trace_memory); i++)
        trace_memory[i] = i % 79 == 0 ? '\n' : 'a' + i % 26;
    set_word(0x40, 1);
    bool passed = extra_case(argv[1]);
    printf("%s %s buffer_size=%zu live_allocations=%d held_locks=%d\n",
           passed ? "PASS" : "FAIL", argv[1], sizeof(gEmiBuf),
           atomic_load(&live_allocations), atomic_load(&lock_balance));
    return passed ? 0 : 1;
}
