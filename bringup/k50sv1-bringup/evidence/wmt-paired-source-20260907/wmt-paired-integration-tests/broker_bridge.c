/* Appended to the generated, unchanged kernel source fixture. */
void pair_init(void)
{
    scenario = 200; /* Real pthread completion adapter, no scripted on_wait. */
    wmt_lib_cmd_start();
}
int pair_open(void) { return WMT_open(&inode, &open_a); }
int pair_close(void) { return WMT_close(&inode, &open_a); }
long pair_ioctl(unsigned long command, unsigned long argument)
{ return WMT_unlocked_ioctl(&open_a, command, argument); }
ssize_t pair_read(void *data, size_t size)
{ return WMT_read(&open_a, data, size, NULL); }
ssize_t pair_write(const void *data, size_t size)
{ return WMT_write(&open_a, data, size, NULL); }
unsigned pair_poll(void) { return WMT_poll(&open_a, NULL); }
int pair_command(const char *command)
{ return wmt_ctrl_ul_cmd(&gDevWmt, (PUINT8)command); }
void pair_cancel(void) { wmt_lib_cancel_cmd(); }
void pair_empty(void)
{
    struct cache_snapshot snapshot = snapshot_cache();
    CHECK(snapshot.count == 0 && snapshot.rom_mask == 0);
}
void pair_patch(unsigned sequence, const char *name, const unsigned char address[4])
{
    WMT_CTRL_DATA control = {0};
    unsigned char actual_name[256] = {0}, actual_address[4] = {0};
    CHECK(wmt_ctrl_get_patch_num(&control) == 0 && control.au4CtrlData[0] == 2);
    control.au4CtrlData[0] = sequence;
    control.au4CtrlData[1] = (SIZE_T)actual_name;
    control.au4CtrlData[2] = (SIZE_T)actual_address;
    CHECK(wmt_ctrl_get_patch_info(&control) == 0);
    CHECK(!strcmp((char *)actual_name, name));
    CHECK(!memcmp(actual_address, address, 4));
}
void pair_rom(unsigned type, const char *name, const unsigned char address[4])
{
    unsigned char actual_name[256] = {0}, actual_address[4] = {0};
    int result = wmt_lib_get_rom_patch_info(type, actual_name, actual_address);
    if (!name) { CHECK(result == -ENOENT); return; }
    CHECK(result == 0 && !strcmp((char *)actual_name, name));
    CHECK(!memcmp(actual_address, address, 4));
}
void pair_cleanup(void) { cleanup(); }
