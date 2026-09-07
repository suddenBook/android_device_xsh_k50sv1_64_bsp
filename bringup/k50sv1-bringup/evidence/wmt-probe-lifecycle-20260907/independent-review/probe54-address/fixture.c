/* Complete production functions are inserted between the host kernel adapters. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void VOID;
typedef int INT32;
typedef unsigned int UINT32;
typedef unsigned char UINT8;
typedef unsigned char *PUINT8;
typedef int *PINT32;
typedef unsigned int *PUINT32;
typedef uintptr_t SIZE_T;
typedef uintptr_t phys_addr_t;
typedef uintptr_t resource_size_t;
typedef unsigned long long UINT64;
typedef int MTK_WCN_BOOL;
typedef int pm_message_t;
typedef struct { int unused; } CONSYS_EMI_ADDR_INFO, *P_CONSYS_EMI_ADDR_INFO;
#define MTK_WCN_BOOL_TRUE 1
#define MTK_WCN_BOOL_FALSE 0
#define __iomem
#define __init_or_module
#define CONFIG_OF 1
#define GFP_KERNEL 0
#define EPROBE_DEFER 517
#define EXPORT_SYMBOL(value)
#define EXPORT_SYMBOL_GPL(value)
#define THIS_MODULE NULL
#define ARRAY_SIZE(value) (sizeof(value) / sizeof((value)[0]))
#define ERR_PTR(value) ((void *)(intptr_t)(value))
#define PTR_ERR(value) ((long)(intptr_t)(value))
#define IS_ERR(value) ((uintptr_t)(value) >= (uintptr_t)-4095)
#define WMT_PLAT_PR_ERR(...) ((void)0)
#define WMT_PLAT_PR_INFO(...) ((void)0)
#define WMT_PLAT_PR_DBG(...) ((void)0)
#define WMT_PLAT_PR_WARN(...) ((void)0)
#define dev_warn(...) ((void)0)
#define SZ_1M (1024U * 1024U)
#define FORBIDDEN 0
#define NO_PROTECTION 1
#define SET_ACCESS_PERMISSON(...) 0
#define CONSYS_REG_READ(address) (*(UINT32 *)(address))
#define CONSYS_REG_WRITE(address, value) (*(UINT32 *)(address) = (value))
#define NORMAL_GET 0
#define EXCLUSIVE_GET 1
#define OPTIONAL_GET 2

#define CONSYS_BT_WIFI_SHARE_V33 0
#define CONSYS_PMIC_CTRL_ENABLE 1
#define CONSYS_EMI_MPU_SETTING 1
#define PLATFORM_SOC_CHIP 0x6755
#define CONSYS_EMI_MAPPING_OFFSET	0x00001340
#define CONSYS_EMI_COREDUMP_OFFSET		(0x80000)
#define KBYTE (1024*sizeof(char))
#define CONSYS_EMI_MEM_SIZE (96*KBYTE) /*coredump space , 96K is enough */

struct device;
struct platform_device;
struct driver_private;
struct bus_type;
struct devres_node;
struct device_node { int references, role; };
struct device_driver {
    const char *name;
    void *owner;
    const void *of_match_table;
    struct bus_type *bus;
    struct driver_private *p;
    bool suppress_bind_attrs;
    int (*probe)(struct device *);
};
struct device {
    struct device_node *of_node;
    struct device_driver *driver;
    struct devres_node *resources;
};
struct platform_device { struct device dev; };
struct platform_driver {
    int (*probe)(struct platform_device *);
    int (*remove)(struct platform_device *);
    int (*suspend)(struct platform_device *, pm_message_t);
    int (*resume)(struct platform_device *);
    struct device_driver driver;
    bool prevent_deferred_probe;
};
struct list_head { unsigned int count; };
struct driver_private { struct { struct list_head k_list; } klist_devices; };
struct bus_private { struct { bool k_lock; } klist_drivers; };
struct bus_type { struct bus_private *p; };
#define container_of(pointer, type, member) ((type *)((char *)(pointer) - offsetof(type, member)))
#define to_platform_driver(pointer) container_of(pointer, struct platform_driver, driver)
#define to_platform_device(pointer) container_of(pointer, struct platform_device, dev)
#define list_empty(list) (!(list)->count)
struct resource { resource_size_t start, end; };
#define resource_size(resource) ((resource)->end - (resource)->start + 1)
struct clk { int marker; };
struct regulator { int marker; };
struct pinctrl { int marker; };
static const int apwmt_of_ids[] = {0};
static int mtk_wmt_suspend(struct platform_device *pdev, pm_message_t state) { return 0; }
static int mtk_wmt_resume(struct platform_device *pdev) { return 0; }

struct CONSYS_BASE_ADDRESS {
	SIZE_T mcu_base;
	SIZE_T ap_rgu_base;
	SIZE_T topckgen_base;
	SIZE_T spm_base;
	SIZE_T mcu_conn_hif_on_base;
	SIZE_T mcu_top_misc_off_base;
	SIZE_T mcu_cfg_on_base;
	SIZE_T mcu_cirq_base;
	SIZE_T da_xobuf_base;
	SIZE_T mcu_top_misc_on_base;
	SIZE_T mcu_conn_hif_pdma_base;
	SIZE_T ap_pccif4_base;
	SIZE_T infra_ao_pericfg_base;
	SIZE_T infracfg_reg_base;
};
typedef INT32(*CONSYS_IC_CLOCK_BUFFER_CTRL) (MTK_WCN_BOOL enable);
typedef VOID(*CONSYS_IC_HW_RESET_BIT_SET) (MTK_WCN_BOOL enable);
typedef VOID(*CONSYS_IC_HW_SPM_CLK_GATING_ENABLE) (VOID);
typedef INT32(*CONSYS_IC_HW_POWER_CTRL) (MTK_WCN_BOOL enable);
typedef INT32(*CONSYS_IC_AHB_CLOCK_CTRL) (MTK_WCN_BOOL enable);
typedef INT32(*POLLING_CONSYS_IC_CHIPID) (VOID);
typedef VOID(*UPDATE_CONSYS_ROM_DESEL_VALUE) (VOID);
typedef VOID(*CONSYS_HANG_DEBUG)(VOID);
typedef VOID(*CONSYS_IC_ARC_REG_SETTING) (VOID);
typedef VOID(*CONSYS_IC_AFE_REG_SETTING) (VOID);
typedef INT32(*CONSYS_IC_HW_VCN18_CTRL) (MTK_WCN_BOOL enable);
typedef VOID(*CONSYS_IC_VCN28_HW_MODE_CTRL) (UINT32 enable);
typedef INT32(*CONSYS_IC_HW_VCN28_CTRL) (UINT32 enable);
typedef INT32(*CONSYS_IC_HW_WIFI_VCN33_CTRL) (UINT32 enable);
typedef INT32(*CONSYS_IC_HW_BT_VCN33_CTRL) (UINT32 enable);
typedef UINT32(*CONSYS_IC_SOC_CHIPID_GET) (VOID);
typedef INT32(*CONSYS_IC_EMI_MPU_SET_REGION_PROTECTION) (VOID);
typedef UINT32(*CONSYS_IC_EMI_SET_REMAPPING_REG) (VOID);
typedef INT32(*IC_BT_WIFI_SHARE_V33_SPIN_LOCK_INIT) (VOID);
typedef INT32(*CONSYS_IC_CLK_GET_FROM_DTS) (struct platform_device *pdev);
typedef INT32(*CONSYS_IC_PMIC_GET_FROM_DTS) (struct platform_device *pdev);
typedef INT32(*CONSYS_IC_READ_IRQ_INFO_FROM_DTS) (struct platform_device *pdev, PINT32 irq_num, PUINT32 irq_flag);
typedef INT32(*CONSYS_IC_READ_REG_FROM_DTS) (struct platform_device *pdev);
typedef UINT32(*CONSYS_IC_READ_CPUPCR) (VOID);
typedef VOID(*IC_FORCE_TRIGGER_ASSERT_DEBUG_PIN) (VOID);
typedef INT32(*CONSYS_IC_CO_CLOCK_TYPE) (VOID);
typedef P_CONSYS_EMI_ADDR_INFO(*CONSYS_IC_SOC_GET_EMI_PHY_ADD) (VOID);
typedef MTK_WCN_BOOL(*CONSYS_IC_NEED_STORE_PDEV) (VOID);
typedef UINT32(*CONSYS_IC_STORE_PDEV) (struct platform_device *pdev);
typedef UINT32(*CONSYS_IC_STORE_RESET_CONTROL) (struct platform_device *pdev);
typedef MTK_WCN_BOOL(*CONSYS_IC_NEED_GPS) (VOID);
typedef VOID(*CONSYS_IC_SET_IF_PINMUX) (MTK_WCN_BOOL enable);
typedef VOID(*CONSYS_IC_SET_DL_ROM_PATCH_FLAG) (INT32 flag);
typedef INT32(*CONSYS_IC_DEDICATED_LOG_PATH_INIT) (struct platform_device *pdev);
typedef VOID(*CONSYS_IC_DEDICATED_LOG_PATH_DEINIT) (VOID);
typedef INT32(*CONSYS_IC_CHECK_REG_READABLE) (VOID);
typedef INT32(*CONSYS_IC_EMI_COREDUMP_REMAPPING) (UINT8 __iomem **addr, UINT32 enable);
typedef INT32(*CONSYS_IC_RESET_EMI_COREDUMP) (UINT8 __iomem *addr);
typedef VOID(*CONSYS_IC_CLOCK_FAIL_DUMP) (VOID);
typedef INT32(*CONSYS_IC_IS_CONNSYS_REG) (UINT32 addr);
typedef PUINT32(*CONSYS_IC_RESUME_DUMP_INFO) (VOID);
typedef VOID(*CONSYS_IC_SET_PDMA_AXI_RREADY_FORCE_HIGH) (UINT32 enable);
typedef VOID(*CONSYS_IC_SET_MCIF_EMI_MPU_PROTECTION)(MTK_WCN_BOOL enable);
typedef INT32(*CONSYS_IC_CALIBRATION_BACKUP_RESTORE) (VOID);
typedef VOID(*CONSYS_IC_REGISTER_DEVAPC_CB) (VOID);
typedef VOID(*CONSYS_IC_INFRA_REG_DUMP)(VOID);
typedef INT32(*CONSYS_IC_IS_ANT_SWAP_ENABLE_BY_HWID) (INT32 pin_num);
typedef VOID(*CONSYS_IC_GET_ANT_SEL_CR_ADDR) (PUINT32 default_invert_cr, PUINT32 default_invert_bit);
typedef VOID(*CONSYS_IC_PROBE_CLEANUP) (VOID);

typedef struct _WMT_CONSYS_IC_OPS_ {
	CONSYS_IC_CLOCK_BUFFER_CTRL consys_ic_clock_buffer_ctrl;
	CONSYS_IC_HW_RESET_BIT_SET consys_ic_hw_reset_bit_set;
	CONSYS_IC_HW_SPM_CLK_GATING_ENABLE consys_ic_hw_spm_clk_gating_enable;
	CONSYS_IC_HW_POWER_CTRL consys_ic_hw_power_ctrl;
	CONSYS_IC_AHB_CLOCK_CTRL consys_ic_ahb_clock_ctrl;
	POLLING_CONSYS_IC_CHIPID polling_consys_ic_chipid;
	UPDATE_CONSYS_ROM_DESEL_VALUE update_consys_rom_desel_value;
	CONSYS_HANG_DEBUG consys_hang_debug;
	CONSYS_IC_ARC_REG_SETTING consys_ic_acr_reg_setting;
	CONSYS_IC_AFE_REG_SETTING consys_ic_afe_reg_setting;
	CONSYS_IC_HW_VCN18_CTRL consys_ic_hw_vcn18_ctrl;
	CONSYS_IC_VCN28_HW_MODE_CTRL consys_ic_vcn28_hw_mode_ctrl;
	CONSYS_IC_HW_VCN28_CTRL consys_ic_hw_vcn28_ctrl;
	CONSYS_IC_HW_WIFI_VCN33_CTRL consys_ic_hw_wifi_vcn33_ctrl;
	CONSYS_IC_HW_BT_VCN33_CTRL consys_ic_hw_bt_vcn33_ctrl;
	CONSYS_IC_SOC_CHIPID_GET consys_ic_soc_chipid_get;
	CONSYS_IC_EMI_MPU_SET_REGION_PROTECTION consys_ic_emi_mpu_set_region_protection;
	CONSYS_IC_EMI_SET_REMAPPING_REG consys_ic_emi_set_remapping_reg;
	IC_BT_WIFI_SHARE_V33_SPIN_LOCK_INIT ic_bt_wifi_share_v33_spin_lock_init;
	CONSYS_IC_CLK_GET_FROM_DTS consys_ic_clk_get_from_dts;
	CONSYS_IC_PMIC_GET_FROM_DTS consys_ic_pmic_get_from_dts;
	CONSYS_IC_READ_IRQ_INFO_FROM_DTS consys_ic_read_irq_info_from_dts;
	CONSYS_IC_READ_REG_FROM_DTS consys_ic_read_reg_from_dts;
	CONSYS_IC_READ_CPUPCR consys_ic_read_cpupcr;
	IC_FORCE_TRIGGER_ASSERT_DEBUG_PIN ic_force_trigger_assert_debug_pin;
	CONSYS_IC_CO_CLOCK_TYPE consys_ic_co_clock_type;
	CONSYS_IC_SOC_GET_EMI_PHY_ADD consys_ic_soc_get_emi_phy_add;
	CONSYS_IC_NEED_STORE_PDEV consys_ic_need_store_pdev;
	CONSYS_IC_STORE_PDEV consys_ic_store_pdev;
	CONSYS_IC_STORE_RESET_CONTROL consys_ic_store_reset_control;
	CONSYS_IC_NEED_GPS consys_ic_need_gps;
	CONSYS_IC_SET_IF_PINMUX consys_ic_set_if_pinmux;
	CONSYS_IC_SET_DL_ROM_PATCH_FLAG consys_ic_set_dl_rom_patch_flag;
	CONSYS_IC_DEDICATED_LOG_PATH_INIT consys_ic_dedicated_log_path_init;
	CONSYS_IC_DEDICATED_LOG_PATH_DEINIT consys_ic_dedicated_log_path_deinit;
	CONSYS_IC_CHECK_REG_READABLE consys_ic_check_reg_readable;
	CONSYS_IC_EMI_COREDUMP_REMAPPING consys_ic_emi_coredump_remapping;
	CONSYS_IC_RESET_EMI_COREDUMP consys_ic_reset_emi_coredump;
	CONSYS_IC_CLOCK_FAIL_DUMP consys_ic_clock_fail_dump;
	CONSYS_IC_IS_CONNSYS_REG consys_ic_is_connsys_reg;
	CONSYS_IC_RESUME_DUMP_INFO consys_ic_resume_dump_info;
	CONSYS_IC_SET_PDMA_AXI_RREADY_FORCE_HIGH consys_ic_set_pdma_axi_rready_force_high;
	CONSYS_IC_SET_MCIF_EMI_MPU_PROTECTION consys_ic_set_mcif_emi_mpu_protection;
	CONSYS_IC_CALIBRATION_BACKUP_RESTORE consys_ic_calibration_backup_restore;
	CONSYS_IC_REGISTER_DEVAPC_CB consys_ic_register_devapc_cb;
	CONSYS_IC_INFRA_REG_DUMP consys_ic_infra_reg_dump;
	CONSYS_IC_IS_ANT_SWAP_ENABLE_BY_HWID consys_ic_is_ant_swap_enable_by_hwid;
	CONSYS_IC_GET_ANT_SEL_CR_ADDR consys_ic_get_ant_sel_cr_addr;
	/* Fixed SoC devices may require a completed probe before WMT starts. */
	MTK_WCN_BOOL consys_ic_probe_required;
	/* Clear IC resource handles before the driver core releases devres. */
	CONSYS_IC_PROBE_CLEANUP consys_ic_probe_cleanup;
} WMT_CONSYS_IC_OPS, *P_WMT_CONSYS_IC_OPS;

UINT8 __iomem *pEmibaseaddr;
P_WMT_CONSYS_IC_OPS wmt_consys_ic_ops;
struct platform_device *g_pdev;
static INT32 g_wmt_probe_result = -ENODEV;
static bool g_wmt_hw_registered;
UINT32 gps_lna_pin_num = 0xffffffff;
static INT32 wifi_ant_swap_gpio_pin_num = -1;
struct pinctrl *consys_pinctrl;
struct regulator *reg_VCN18;
struct regulator *reg_VCN28;
struct regulator *reg_VCN33_BT;
struct regulator *reg_VCN33_WIFI;
struct clk *clk_scp_conn_main;
struct CONSYS_BASE_ADDRESS conn_reg;
#define HOST_HAS_PROBE_GATE 1

static INT32 consys_read_reg_from_dts(struct platform_device *pdev);
static INT32 consys_clk_get_from_dts(struct platform_device *pdev);
static INT32 consys_pmic_get_from_dts(struct platform_device *pdev);
static INT32 consys_emi_mpu_set_region_protection(VOID);
static UINT32 consys_emi_set_remapping_reg(VOID);
static INT32 bt_wifi_share_v33_spin_lock_init(VOID);
static INT32 consys_emi_coredump_remapping(UINT8 __iomem **addr, UINT32 enable);
P_WMT_CONSYS_IC_OPS mtk_wcn_get_consys_ic_ops(VOID);
static VOID consys_probe_cleanup(VOID);
static INT32 mtk_wmt_probe(struct platform_device *pdev);
static INT32 mtk_wmt_remove(struct platform_device *pdev);
INT32 mtk_wcn_consys_hw_init(VOID);
INT32 mtk_wcn_consys_hw_deinit(VOID);
INT32 mtk_wcn_consys_hw_restore(struct device *device);
static VOID mtk_wmt_probe_cleanup(struct platform_device *pdev);
void devm_ioremap_release(struct device *dev, void *res);
void __iomem *devm_ioremap(struct device *dev, resource_size_t offset,
			   unsigned long size);
static void devm_clk_release(struct device *dev, void *res);
struct clk *devm_clk_get(struct device *dev, const char *id);
static void devm_regulator_release(struct device *dev, void *res);
static struct regulator *_devm_regulator_get(struct device *dev, const char *id,
					     int get_type);
struct regulator *devm_regulator_get(struct device *dev, const char *id);
static void devm_pinctrl_release(struct device *dev, void *res);
struct pinctrl *devm_pinctrl_get(struct device *dev);
static int platform_drv_probe(struct device *_dev);
static int platform_drv_probe_fail(struct device *_dev);
static int platform_drv_remove(struct device *_dev);
int __init_or_module platform_driver_probe(struct platform_driver *drv,
		int (*probe)(struct platform_device *));
static INT32 consys_clock_buffer_ctrl(MTK_WCN_BOOL enable)
{ return 0; }

static VOID consys_hw_reset_bit_set(MTK_WCN_BOOL enable)
{}

static VOID consys_hw_spm_clk_gating_enable(VOID)
{}

static INT32 consys_hw_power_ctrl(MTK_WCN_BOOL enable)
{ return 0; }

static INT32 consys_ahb_clock_ctrl(MTK_WCN_BOOL enable)
{ return 0; }

static INT32 polling_consys_chipid(VOID)
{ return 0; }

static VOID consys_acr_reg_setting(VOID)
{}

static VOID consys_afe_reg_setting(VOID)
{}

static INT32 consys_hw_vcn18_ctrl(MTK_WCN_BOOL enable)
{ return 0; }

static VOID consys_vcn28_hw_mode_ctrl(UINT32 enable)
{}

static INT32 consys_hw_vcn28_ctrl(UINT32 enable)
{ return 0; }

static INT32 consys_hw_wifi_vcn33_ctrl(UINT32 enable)
{ return 0; }

static INT32 consys_hw_bt_vcn33_ctrl(UINT32 enable)
{ return 0; }

static UINT32 consys_soc_chipid_get(VOID)
{ return 0; }

static INT32 consys_read_irq_info_from_dts(struct platform_device *pdev, INT32 *irq_num, UINT32 *irq_flag)
{ return 0; }

static UINT32 consys_read_cpupcr(VOID)
{ return 0; }

static VOID force_trigger_assert_debug_pin(VOID)
{}

static INT32 consys_co_clock_type(VOID)
{ return 0; }

static P_CONSYS_EMI_ADDR_INFO consys_soc_get_emi_phy_add(VOID)
{ return 0; }

static INT32 consys_reset_emi_coredump(UINT8 __iomem *addr)
{ return 0; }

WMT_CONSYS_IC_OPS consys_ic_ops = {
	.consys_ic_clock_buffer_ctrl = consys_clock_buffer_ctrl,
	.consys_ic_hw_reset_bit_set = consys_hw_reset_bit_set,
	.consys_ic_hw_spm_clk_gating_enable = consys_hw_spm_clk_gating_enable,
	.consys_ic_hw_power_ctrl = consys_hw_power_ctrl,
	.consys_ic_ahb_clock_ctrl = consys_ahb_clock_ctrl,
	.polling_consys_ic_chipid = polling_consys_chipid,
	.consys_ic_acr_reg_setting = consys_acr_reg_setting,
	.consys_ic_afe_reg_setting = consys_afe_reg_setting,
	.consys_ic_hw_vcn18_ctrl = consys_hw_vcn18_ctrl,
	.consys_ic_vcn28_hw_mode_ctrl = consys_vcn28_hw_mode_ctrl,
	.consys_ic_hw_vcn28_ctrl = consys_hw_vcn28_ctrl,
	.consys_ic_hw_wifi_vcn33_ctrl = consys_hw_wifi_vcn33_ctrl,
	.consys_ic_hw_bt_vcn33_ctrl = consys_hw_bt_vcn33_ctrl,
	.consys_ic_soc_chipid_get = consys_soc_chipid_get,
	.consys_ic_emi_mpu_set_region_protection = consys_emi_mpu_set_region_protection,
	.consys_ic_emi_set_remapping_reg = consys_emi_set_remapping_reg,
	.ic_bt_wifi_share_v33_spin_lock_init = bt_wifi_share_v33_spin_lock_init,
	.consys_ic_clk_get_from_dts = consys_clk_get_from_dts,
	.consys_ic_pmic_get_from_dts = consys_pmic_get_from_dts,
	.consys_ic_read_irq_info_from_dts = consys_read_irq_info_from_dts,
	.consys_ic_read_reg_from_dts = consys_read_reg_from_dts,
	.consys_ic_read_cpupcr = consys_read_cpupcr,
	.ic_force_trigger_assert_debug_pin = force_trigger_assert_debug_pin,
	.consys_ic_co_clock_type = consys_co_clock_type,
	.consys_ic_soc_get_emi_phy_add = consys_soc_get_emi_phy_add,
	.consys_ic_emi_coredump_remapping = consys_emi_coredump_remapping,
	.consys_ic_reset_emi_coredump = consys_reset_emi_coredump,
	.consys_ic_probe_required = MTK_WCN_BOOL_TRUE,
	.consys_ic_probe_cleanup = consys_probe_cleanup,
};

static struct platform_driver mtk_wmt_dev_drv = {
	.probe = mtk_wmt_probe,
	.remove = mtk_wmt_remove,
	.suspend = mtk_wmt_suspend,
	.resume = mtk_wmt_resume,
	.driver = {
		   .name = "mtk_wmt",
		   .owner = THIS_MODULE,
#ifdef CONFIG_OF
		   .of_match_table = apwmt_of_ids,
#endif
		   },
};


static phys_addr_t gConEmiPhyBase = 0x90000000;
static UINT64 gConEmiSize = SZ_1M;
static struct device_node root_node, gps_node, pins_node;
static struct platform_device device = { .dev = { .of_node = &root_node } };
static struct bus_private bus_private;
static struct bus_type platform_bus = { .p = &bus_private };
static struct driver_private driver_private;

enum allocation_kind { REG_MAP, EMI_CLEAR, EMI_DUMP, CLK_HANDLE, REGULATOR_HANDLE, PIN_HANDLE };
struct allocation { void *address; size_t size; enum allocation_kind kind; struct allocation *next; };
static struct allocation *allocations;
static unsigned int live_allocations, live_devres;
static unsigned int map_attempts, regulator_attempts, map_devres_attempts, regulator_devres_attempts;
static unsigned int register_calls, unregister_calls, rollback_calls, probe_calls, remove_calls;
static unsigned int clear_calls, dump_mappings, release_checks;
static bool driver_registered, device_bound, pm_domain_attached;
static bool have_device = true, fail_framework, no_gps_phandle, no_gps_child, no_gps_properties;
static bool gps_uses_pinmux = true;
static int fail_register, fail_groups, fail_resource = -1, fail_map = -1, fail_map_devres = -1;
static int fail_clock, fail_regulator = -1, fail_regulator_devres = -1, fail_pinctrl;
static bool fail_clock_devres, fail_pinctrl_devres, fail_emi_clear, fail_emi_dump;
static int wifi_gpio = 27;

static void *allocate_resource(enum allocation_kind kind, size_t size)
{
    struct allocation *record = calloc(1, sizeof(*record));
    assert(record);
    record->address = calloc(1, size);
    assert(record->address);
    record->size = size;
    record->kind = kind;
    record->next = allocations;
    allocations = record;
    live_allocations++;
    return record->address;
}

static struct allocation *find_allocation(const void *address)
{
    struct allocation *record;
    for (record = allocations; record; record = record->next)
        if (record->address == address)
            return record;
    assert(!"Unknown or already released resource");
    return NULL;
}

static void free_resource(void *address, enum allocation_kind kind)
{
    struct allocation **position = &allocations;
    assert(address && !IS_ERR(address));
    while (*position && (*position)->address != address)
        position = &(*position)->next;
    assert(*position && (*position)->kind == kind);
    struct allocation *record = *position;
    *position = record->next;
    assert(live_allocations-- > 0);
    free(record->address);
    free(record);
}

static void require_handles_withdrawn(void)
{
    fprintf(stderr, "withdrawn=%d maps=%u devres=%u bound=%d\n",
            !g_pdev && !consys_pinctrl && !conn_reg.mcu_base && !conn_reg.ap_rgu_base &&
            !conn_reg.topckgen_base && !conn_reg.spm_base && !clk_scp_conn_main &&
            !reg_VCN18 && !reg_VCN28 && !reg_VCN33_BT && !reg_VCN33_WIFI,
            live_allocations, live_devres, device_bound);
    assert(!g_pdev && !consys_pinctrl && !pEmibaseaddr);
    assert(!conn_reg.mcu_base && !conn_reg.ap_rgu_base && !conn_reg.topckgen_base && !conn_reg.spm_base);
    assert(!clk_scp_conn_main && !reg_VCN18 && !reg_VCN28 && !reg_VCN33_BT && !reg_VCN33_WIFI);
    release_checks++;
}

struct devres_node {
    void (*release)(struct device *, void *);
    struct device *owner;
    struct devres_node *next;
    unsigned char data[];
};

static void *devres_alloc(void (*release)(struct device *, void *), size_t size, int flags)
{
    if (release == devm_ioremap_release && (int)map_devres_attempts++ == fail_map_devres)
        return NULL;
    if (release == devm_clk_release && fail_clock_devres)
        return NULL;
    if (release == devm_regulator_release && (int)regulator_devres_attempts++ == fail_regulator_devres)
        return NULL;
    if (release == devm_pinctrl_release && fail_pinctrl_devres)
        return NULL;
    struct devres_node *node = calloc(1, sizeof(*node) + size);
    assert(node);
    node->release = release;
    live_devres++;
    return node->data;
}

static void devres_add(struct device *dev, void *data)
{
    struct devres_node *node = container_of(data, struct devres_node, data);
    assert(!node->owner);
    node->owner = dev;
    node->next = dev->resources;
    dev->resources = node;
}

static void devres_free(void *data)
{
    struct devres_node *node = container_of(data, struct devres_node, data);
    assert(!node->owner);
    assert(live_devres-- > 0);
    free(node);
}

static void devres_release_all(struct device *dev)
{
    /* Local drivers/base/dd.c calls this after failed probe or after remove. */
    require_handles_withdrawn();
    while (dev->resources) {
        struct devres_node *node = dev->resources;
        dev->resources = node->next;
        assert(node->owner == dev);
        node->release(dev, node->data);
        assert(live_devres-- > 0);
        free(node);
    }
}

static int of_address_to_resource(struct device_node *node, unsigned int index, struct resource *resource)
{
    static const uintptr_t addresses[] = {0x18070000, 0x10007000, 0x10000000, 0x10006000};
    static const size_t sizes[] = {0x200, 0x100, 0x2000, 0x1000};
    assert(node == &root_node && index < 4);
    if ((int)index == fail_resource)
        return -EINVAL;
    resource->start = addresses[index];
    resource->end = addresses[index] + sizes[index] - 1;
    return 0;
}

static void *ioremap(resource_size_t address, unsigned long size)
{
    if ((int)map_attempts++ == fail_map)
        return NULL;
    return allocate_resource(REG_MAP, size);
}

static void *of_iomap(struct device_node *node, unsigned int index)
{
    /* The local OF helper is exactly address translation followed by ioremap. */
    struct resource resource;
    if (of_address_to_resource(node, index, &resource))
        return NULL;
    return ioremap(resource.start, resource_size(&resource));
}

static void *ioremap_nocache(resource_size_t address, unsigned long size)
{
    if (address == gConEmiPhyBase) {
        if (fail_emi_clear)
            return NULL;
        return allocate_resource(EMI_CLEAR, size);
    }
    assert(address == gConEmiPhyBase + CONSYS_EMI_COREDUMP_OFFSET);
    if (fail_emi_dump)
        return NULL;
    dump_mappings++;
    return allocate_resource(EMI_DUMP, size);
}

static void iounmap(void *address)
{
    struct allocation *record = find_allocation(address);
    enum allocation_kind kind = record->kind;
    assert(kind == REG_MAP || kind == EMI_CLEAR || kind == EMI_DUMP);
    if (kind == REG_MAP) {
        assert((SIZE_T)address != conn_reg.mcu_base && (SIZE_T)address != conn_reg.ap_rgu_base);
        assert((SIZE_T)address != conn_reg.topckgen_base && (SIZE_T)address != conn_reg.spm_base);
    } else if (kind == EMI_DUMP) {
        assert(address != pEmibaseaddr);
    }
    free_resource(address, kind);
}

static void memset_io(void *address, int value, size_t size)
{
    assert(address);
    assert(size <= find_allocation(address)->size);
    memset(address, value, size);
    clear_calls++;
}

static struct clk *clk_get(struct device *dev, const char *name)
{
    assert(dev == &device.dev && strcmp(name, "conn") == 0);
    if (fail_clock)
        return ERR_PTR(fail_clock);
    return allocate_resource(CLK_HANDLE, sizeof(struct clk));
}

static void clk_put(struct clk *clock)
{
    assert(clock != clk_scp_conn_main);
    free_resource(clock, CLK_HANDLE);
}

static struct regulator *regulator_get(struct device *dev, const char *name)
{
    static const char *names[] = {"vcn18", "vcn28", "vcn33_bt", "vcn33_wifi"};
    unsigned int index = regulator_attempts++;
    assert(dev == &device.dev && index < ARRAY_SIZE(names) && strcmp(name, names[index]) == 0);
    if ((int)index == fail_regulator)
        return ERR_PTR(-EPROBE_DEFER);
    return allocate_resource(REGULATOR_HANDLE, sizeof(struct regulator));
}
static struct regulator *regulator_get_exclusive(struct device *dev, const char *name)
{ return regulator_get(dev, name); }
static struct regulator *regulator_get_optional(struct device *dev, const char *name)
{ return regulator_get(dev, name); }

static void regulator_put(struct regulator *regulator)
{
    assert(regulator != reg_VCN18 && regulator != reg_VCN28);
    assert(regulator != reg_VCN33_BT && regulator != reg_VCN33_WIFI);
    free_resource(regulator, REGULATOR_HANDLE);
}

static struct pinctrl *pinctrl_get(struct device *dev)
{
    assert(dev == &device.dev);
    if (fail_pinctrl)
        return ERR_PTR(fail_pinctrl);
    return allocate_resource(PIN_HANDLE, sizeof(struct pinctrl));
}
static void pinctrl_put(struct pinctrl *pinctrl)
{
    assert(pinctrl != consys_pinctrl);
    free_resource(pinctrl, PIN_HANDLE);
}

static struct device_node *of_parse_phandle(struct device_node *node, const char *name, int index)
{
    assert(node == &root_node && strcmp(name, "pinctrl-1") == 0 && index == 0);
    if (no_gps_phandle)
        return NULL;
    gps_node.references++;
    return &gps_node;
}
static struct device_node *of_get_child_by_name(struct device_node *node, const char *name)
{
    assert(node == &gps_node && strcmp(name, "pins_cmd_dat") == 0);
    if (no_gps_child)
        return NULL;
    pins_node.references++;
    return &pins_node;
}
static int of_property_read_u32(struct device_node *node, const char *name, UINT32 *value)
{
    assert(node == &pins_node);
    if (no_gps_properties || (strcmp(name, "pinmux") == 0 && !gps_uses_pinmux))
        return -EINVAL;
    *value = 27U << 8;
    return 0;
}
static void of_node_put(struct device_node *node)
{
    if (node)
        assert(node->references-- > 0);
}
static int of_get_named_gpio(struct device_node *node, const char *name, int index)
{
    assert(node == &root_node && strcmp(name, "wifi_ant_swap_gpio") == 0 && index == 0);
    return wifi_gpio;
}

static void pm_runtime_enable(struct device *dev) { assert(!"MT6755 does not request runtime PM"); }
static void pm_runtime_disable(struct device *dev) { assert(!"MT6755 does not request runtime PM"); }
static void emi_mpu_set_region_protection(phys_addr_t start, phys_addr_t end, int region, int flags)
{ assert(start <= end && region == 13); }
static void spin_lock(bool *lock) { assert(!*lock); *lock = true; }
static void spin_unlock(bool *lock) { assert(*lock); *lock = false; }
static int of_clk_set_defaults(struct device_node *node, bool supplier)
{ return fail_framework ? -EPROBE_DEFER : 0; }
static int dev_pm_domain_attach(struct device *dev, bool power_on)
{
    assert(!pm_domain_attached);
    pm_domain_attached = true;
    return 0;
}
static void dev_pm_domain_detach(struct device *dev, bool power_off)
{
    assert(pm_domain_attached);
    pm_domain_attached = false;
}

static int platform_driver_register(struct platform_driver *driver)
{
    register_calls++;
    driver->driver.bus = &platform_bus;
    if (fail_register)
        return fail_register;
    assert(!driver_registered);
    driver_registered = true;
    driver->driver.p = &driver_private;
    driver_private.klist_devices.k_list.count = 0;
    if (have_device) {
        device.dev.driver = &driver->driver;
        probe_calls++;
        int ret = platform_drv_probe(&device.dev);
        if (ret) {
            /* really_probe() releases devres, then deliberately returns 0. */
            devres_release_all(&device.dev);
            device.dev.driver = NULL;
        } else {
            device_bound = true;
            driver_private.klist_devices.k_list.count = 1;
        }
    }
    if (fail_groups) {
        /* driver_register() calls bus_remove_driver() on add-groups failure. */
        if (device_bound) {
            remove_calls++;
            assert(platform_drv_remove(&device.dev) == 0);
            devres_release_all(&device.dev);
            device_bound = false;
            device.dev.driver = NULL;
        }
        driver_private.klist_devices.k_list.count = 0;
        driver->driver.p = NULL;
        driver_registered = false;
        rollback_calls++;
        return fail_groups;
    }
    return 0;
}

static void platform_driver_unregister(struct platform_driver *driver)
{
    assert(driver_registered);
    unregister_calls++;
    if (device_bound) {
        remove_calls++;
        assert(platform_drv_remove(&device.dev) == 0);
        devres_release_all(&device.dev);
        device_bound = false;
        device.dev.driver = NULL;
    }
    driver_private.klist_devices.k_list.count = 0;
    driver->driver.p = NULL;
    driver_registered = false;
}

void devm_ioremap_release(struct device *dev, void *res)
{
	iounmap(*(void __iomem **)res);
}

void __iomem *devm_ioremap(struct device *dev, resource_size_t offset,
			   unsigned long size)
{
	void __iomem **ptr, *addr;

	ptr = devres_alloc(devm_ioremap_release, sizeof(*ptr), GFP_KERNEL);
	if (!ptr)
		return NULL;

	addr = ioremap(offset, size);
	if (addr) {
		*ptr = addr;
		devres_add(dev, ptr);
	} else
		devres_free(ptr);

	return addr;
}

static void devm_clk_release(struct device *dev, void *res)
{
	clk_put(*(struct clk **)res);
}

struct clk *devm_clk_get(struct device *dev, const char *id)
{
	struct clk **ptr, *clk;

	ptr = devres_alloc(devm_clk_release, sizeof(*ptr), GFP_KERNEL);
	if (!ptr)
		return ERR_PTR(-ENOMEM);

	clk = clk_get(dev, id);
	if (!IS_ERR(clk)) {
		*ptr = clk;
		devres_add(dev, ptr);
	} else {
		devres_free(ptr);
	}

	return clk;
}

static void devm_regulator_release(struct device *dev, void *res)
{
	regulator_put(*(struct regulator **)res);
}

static struct regulator *_devm_regulator_get(struct device *dev, const char *id,
					     int get_type)
{
	struct regulator **ptr, *regulator;

	ptr = devres_alloc(devm_regulator_release, sizeof(*ptr), GFP_KERNEL);
	if (!ptr)
		return ERR_PTR(-ENOMEM);

	switch (get_type) {
	case NORMAL_GET:
		regulator = regulator_get(dev, id);
		break;
	case EXCLUSIVE_GET:
		regulator = regulator_get_exclusive(dev, id);
		break;
	case OPTIONAL_GET:
		regulator = regulator_get_optional(dev, id);
		break;
	default:
		regulator = ERR_PTR(-EINVAL);
	}

	if (!IS_ERR(regulator)) {
		*ptr = regulator;
		devres_add(dev, ptr);
	} else {
		devres_free(ptr);
	}

	return regulator;
}

struct regulator *devm_regulator_get(struct device *dev, const char *id)
{
	return _devm_regulator_get(dev, id, NORMAL_GET);
}

static void devm_pinctrl_release(struct device *dev, void *res)
{
	pinctrl_put(*(struct pinctrl **)res);
}

struct pinctrl *devm_pinctrl_get(struct device *dev)
{
	struct pinctrl **ptr, *p;

	ptr = devres_alloc(devm_pinctrl_release, sizeof(*ptr), GFP_KERNEL);
	if (!ptr)
		return ERR_PTR(-ENOMEM);

	p = pinctrl_get(dev);
	if (!IS_ERR(p)) {
		*ptr = p;
		devres_add(dev, ptr);
	} else {
		devres_free(ptr);
	}

	return p;
}

static INT32 consys_read_reg_from_dts(struct platform_device *pdev)
{
#ifdef CONFIG_OF		/*use DT */
	SIZE_T *bases[] = {
		&conn_reg.mcu_base, &conn_reg.ap_rgu_base,
		&conn_reg.topckgen_base, &conn_reg.spm_base,
	};
	struct resource resource;
	void __iomem *base;
	INT32 iRet;
	UINT32 i;

	if (!pdev || !pdev->dev.of_node) {
		WMT_PLAT_PR_ERR("[%s] can't find CONSYS compatible node\n", __func__);
		return -ENODEV;
	}
	for (i = 0; i < ARRAY_SIZE(bases); i++) {
		iRet = of_address_to_resource(pdev->dev.of_node, i, &resource);
		if (iRet)
			return iRet;
		/* TOPCKGEN and SPM are shared; do not claim an exclusive region. */
		base = devm_ioremap(&pdev->dev, resource.start, resource_size(&resource));
		if (!base)
			return -ENOMEM;
		*bases[i] = (SIZE_T) base;
		WMT_PLAT_PR_DBG("Get register %u base(0x%zx)\n", i, *bases[i]);
	}
#endif
	return 0;
}

static INT32 consys_clk_get_from_dts(struct platform_device *pdev)
{
#ifdef CONFIG_OF		/*use DT */
#if !defined(CONFIG_MTK_CLKMGR)
	struct clk *clk;

	clk = devm_clk_get(&pdev->dev, "conn");
	if (IS_ERR(clk)) {
		WMT_PLAT_PR_ERR("[CCF]cannot get clk_scp_conn_main clock.\n");
		return PTR_ERR(clk);
	}
	clk_scp_conn_main = clk;
	WMT_PLAT_PR_DBG("[CCF]clk_scp_conn_main=%p\n", clk_scp_conn_main);
#if 0
	clk_infra_conn_main = devm_clk_get(&pdev->dev, "bus");
	if (IS_ERR(clk_infra_conn_main)) {
		WMT_PLAT_PR_ERR("[CCF]cannot get clk_infra_conn_main clock.\n");
		return PTR_ERR(clk_infra_conn_main);
	}
	WMT_PLAT_PR_DBG("[CCF]clk_infra_conn_main=%p\n", clk_infra_conn_main);
#endif

#endif /* !defined(CONFIG_MTK_CLKMGR) */
#endif
	return 0;
}

static INT32 consys_pmic_get_from_dts(struct platform_device *pdev)
{
#ifdef CONFIG_OF		/*use DT */
#if CONSYS_PMIC_CTRL_ENABLE
#if !defined(CONFIG_MTK_PMIC_LEGACY)
	struct {
		struct regulator **handle;
		const char *name;
	} supplies[] = {
		{ &reg_VCN18, "vcn18" },
		{ &reg_VCN28, "vcn28" },
		{ &reg_VCN33_BT, "vcn33_bt" },
		{ &reg_VCN33_WIFI, "vcn33_wifi" },
	};
	struct regulator *regulator;
	UINT32 i;

	for (i = 0; i < ARRAY_SIZE(supplies); i++) {
		regulator = devm_regulator_get(&pdev->dev, supplies[i].name);
		if (IS_ERR(regulator)) {
			WMT_PLAT_PR_ERR("Regulator_get %s failed(%ld)\n",
					 supplies[i].name, PTR_ERR(regulator));
			return PTR_ERR(regulator);
		}
		*supplies[i].handle = regulator;
	}
#endif
#endif
#endif
	return 0;
}

static INT32 consys_emi_mpu_set_region_protection(VOID)
{
#if CONSYS_EMI_MPU_SETTING
	/*set MPU for EMI share Memory */
	WMT_PLAT_PR_INFO("setting MPU for EMI share memory\n");
	emi_mpu_set_region_protection(gConEmiPhyBase + SZ_1M / 2,
					gConEmiPhyBase + SZ_1M - 1,
					13,
					SET_ACCESS_PERMISSON(FORBIDDEN, FORBIDDEN, FORBIDDEN, FORBIDDEN,
					FORBIDDEN, NO_PROTECTION, FORBIDDEN, NO_PROTECTION));
#endif
	return 0;
}

static UINT32 consys_emi_set_remapping_reg(VOID)
{
#ifdef CONFIG_OF		/*use DT */
	UINT32 addrPhy = 0;

	/*consys to ap emi remapping register:10000320, cal remapping address */
	addrPhy = (gConEmiPhyBase & 0xFFF00000) >> 20;

	/*enable consys to ap emi remapping bit12 */
	addrPhy = addrPhy | 0x1000;

	CONSYS_REG_WRITE(conn_reg.topckgen_base + CONSYS_EMI_MAPPING_OFFSET,
			 CONSYS_REG_READ(conn_reg.topckgen_base + CONSYS_EMI_MAPPING_OFFSET) | addrPhy);

	WMT_PLAT_PR_INFO("CONSYS_EMI_MAPPING dump in restore cb(0x%08x)\n",
			   CONSYS_REG_READ(conn_reg.topckgen_base + CONSYS_EMI_MAPPING_OFFSET));
#endif
	return 0;
}

static INT32 bt_wifi_share_v33_spin_lock_init(VOID)
{
#if CONSYS_BT_WIFI_SHARE_V33
	gBtWifiV33.counter = 0;
	spin_lock_init(&gBtWifiV33.lock);
#endif
	return 0;
}

static INT32 consys_emi_coredump_remapping(UINT8 __iomem **addr, UINT32 enable)
{
	UINT8 __iomem *mapping;

	if (!addr)
		return -EINVAL;
	if (enable) {
		if (!gConEmiPhyBase || gConEmiSize < CONSYS_EMI_COREDUMP_OFFSET + CONSYS_EMI_MEM_SIZE)
			return -EINVAL;
		if (!*addr)
			*addr = ioremap_nocache(gConEmiPhyBase + CONSYS_EMI_COREDUMP_OFFSET, CONSYS_EMI_MEM_SIZE);
		if (*addr) {
			WMT_PLAT_PR_INFO("COREDUMP EMI mapping OK virtual(0x%p) physical(0x%x)\n",
					   *addr, (UINT32) gConEmiPhyBase + CONSYS_EMI_COREDUMP_OFFSET);
			memset_io(*addr, 0, CONSYS_EMI_MEM_SIZE);
		} else {
			WMT_PLAT_PR_ERR("EMI mapping fail\n");
			return -ENOMEM;
		}
	} else {
		mapping = *addr;
		*addr = NULL;
		if (mapping)
			iounmap(mapping);
	}
	return 0;
}

P_WMT_CONSYS_IC_OPS mtk_wcn_get_consys_ic_ops(VOID)
{
	return &consys_ic_ops;
}

static VOID consys_probe_cleanup(VOID)
{
	/* The caller withdraws these handles before devres frees their resources. */
#ifdef CONFIG_OF
	conn_reg.mcu_base = 0;
	conn_reg.ap_rgu_base = 0;
	conn_reg.topckgen_base = 0;
	conn_reg.spm_base = 0;
#endif
#if !defined(CONFIG_MTK_CLKMGR)
	clk_scp_conn_main = NULL;
#endif
#if CONSYS_PMIC_CTRL_ENABLE && !defined(CONFIG_MTK_PMIC_LEGACY)
	reg_VCN18 = NULL;
	reg_VCN28 = NULL;
	reg_VCN33_BT = NULL;
	reg_VCN33_WIFI = NULL;
#endif
}

static INT32 mtk_wmt_probe(struct platform_device *pdev)
{
	INT32 iRet = -1;
	INT32 pin_ret = 0;
	UINT32 pinmux = 0;
	MTK_WCN_BOOL probe_required;
	struct device_node *pinctl_node, *pins_node;
	UINT8 __iomem *pConnsysEmiStart;

	if (!pdev) {
		WMT_PLAT_PR_ERR("pdev is NULL\n");
		iRet = -EINVAL;
		goto out;
	}
	if (!wmt_consys_ic_ops) {
		iRet = -ENODEV;
		goto out;
	}
	if (g_pdev)
		return -EBUSY;
	probe_required = wmt_consys_ic_ops->consys_ic_probe_required;

	if (wmt_consys_ic_ops->consys_ic_need_store_pdev) {
		if (wmt_consys_ic_ops->consys_ic_need_store_pdev() == MTK_WCN_BOOL_TRUE) {
			if (wmt_consys_ic_ops->consys_ic_store_pdev)
				wmt_consys_ic_ops->consys_ic_store_pdev(pdev);
			pm_runtime_enable(&pdev->dev);
		}
	}

	if (wmt_consys_ic_ops->consys_ic_read_reg_from_dts)
		iRet = wmt_consys_ic_ops->consys_ic_read_reg_from_dts(pdev);
	else
		iRet = -1;

	if (iRet)
		goto error;

	if (wmt_consys_ic_ops->consys_ic_clk_get_from_dts)
		iRet = wmt_consys_ic_ops->consys_ic_clk_get_from_dts(pdev);
	else
		iRet = -1;

	if (iRet)
		goto error;

	if (gConEmiPhyBase) {
		if (!gConEmiSize) {
			iRet = -EINVAL;
			goto error;
		}
		pConnsysEmiStart = ioremap_nocache(gConEmiPhyBase, gConEmiSize);
		if (!pConnsysEmiStart) {
			iRet = -ENOMEM;
			goto error;
		}
		WMT_PLAT_PR_INFO("Clearing Connsys EMI (virtual(0x%p) physical(0x%pa)) %llu bytes\n",
				   pConnsysEmiStart, &gConEmiPhyBase, gConEmiSize);
		memset_io(pConnsysEmiStart, 0, gConEmiSize);
		iounmap(pConnsysEmiStart);
		pConnsysEmiStart = NULL;

		if (wmt_consys_ic_ops->consys_ic_emi_mpu_set_region_protection)
			wmt_consys_ic_ops->consys_ic_emi_mpu_set_region_protection();
		if (wmt_consys_ic_ops->consys_ic_emi_set_remapping_reg)
			wmt_consys_ic_ops->consys_ic_emi_set_remapping_reg();
		if (wmt_consys_ic_ops->consys_ic_emi_coredump_remapping) {
			iRet = wmt_consys_ic_ops->consys_ic_emi_coredump_remapping(&pEmibaseaddr, 1);
			if (iRet && probe_required)
				goto error;
		}
		if (wmt_consys_ic_ops->consys_ic_dedicated_log_path_init)
			wmt_consys_ic_ops->consys_ic_dedicated_log_path_init(pdev);
	} else {
		WMT_PLAT_PR_ERR("consys emi memory address gConEmiPhyBase invalid\n");
		if (probe_required) {
			iRet = -ENODEV;
			goto error;
		}
	}

	if (wmt_consys_ic_ops->ic_bt_wifi_share_v33_spin_lock_init)
		wmt_consys_ic_ops->ic_bt_wifi_share_v33_spin_lock_init();


	if (wmt_consys_ic_ops->consys_ic_pmic_get_from_dts) {
		iRet = wmt_consys_ic_ops->consys_ic_pmic_get_from_dts(pdev);
		if (iRet && probe_required)
			goto error;
	}

	consys_pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(consys_pinctrl)) {
		WMT_PLAT_PR_ERR("cannot find consys pinctrl.\n");
		iRet = PTR_ERR(consys_pinctrl);
		consys_pinctrl = NULL;
		/* Missing optional pins are allowed; failed/deferred acquisition is not. */
		if (probe_required && iRet != -ENODEV)
			goto error;
	}

	/* find gps lna gpio number */
	if (consys_pinctrl) {
		pinctl_node = of_parse_phandle(pdev->dev.of_node, "pinctrl-1", 0);
		if (pinctl_node) {
			pins_node = of_get_child_by_name(pinctl_node, "pins_cmd_dat");
			if (pins_node) {
				pin_ret = of_property_read_u32(pins_node, "pinmux", &pinmux);
				if (pin_ret)
					pin_ret = of_property_read_u32(pins_node, "pins", &pinmux);
				if (!pin_ret) {
					gps_lna_pin_num = (pinmux >> 8) & 0xff;
					WMT_PLAT_PR_INFO("GPS LNA gpio pin number:%d, pinmux:0x%08x.\n",
							   gps_lna_pin_num, pinmux);
				}
				of_node_put(pins_node);
			}
			of_node_put(pinctl_node);
		}
	}

	wifi_ant_swap_gpio_pin_num = of_get_named_gpio(pdev->dev.of_node, "wifi_ant_swap_gpio", 0);
	if (probe_required && wifi_ant_swap_gpio_pin_num == -EPROBE_DEFER) {
		iRet = -EPROBE_DEFER;
		goto error;
	}
	WMT_PLAT_PR_INFO("ant swap pin number:%d\n", wifi_ant_swap_gpio_pin_num);

	if (wmt_consys_ic_ops->consys_ic_store_reset_control)
		wmt_consys_ic_ops->consys_ic_store_reset_control(pdev);

	if (wmt_consys_ic_ops->consys_ic_register_devapc_cb)
		wmt_consys_ic_ops->consys_ic_register_devapc_cb();

#ifdef CONFIG_MTK_HIBERNATION
	WMT_PLAT_PR_INFO("register connsys restore cb for complying with IPOH function\n");
	register_swsusp_restore_noirq_func(ID_M_CONNSYS, mtk_wcn_consys_hw_restore, NULL);
#endif
	g_pdev = pdev;
	iRet = 0;
	goto out;

error:
	mtk_wmt_probe_cleanup(pdev);
out:
	g_wmt_probe_result = iRet;
	return iRet;
}

static INT32 mtk_wmt_remove(struct platform_device *pdev)
{
	if (g_pdev != pdev)
		return 0;
	mtk_wmt_probe_cleanup(pdev);
	g_wmt_probe_result = -ENODEV;

	return 0;
}

INT32 mtk_wcn_consys_hw_init(VOID)
{
	INT32 iRet = -1;

	if (g_wmt_hw_registered)
		return -EBUSY;
	if (wmt_consys_ic_ops == NULL)
		wmt_consys_ic_ops = mtk_wcn_get_consys_ic_ops();
	if (!wmt_consys_ic_ops)
		return -ENODEV;

	if (wmt_consys_ic_ops->consys_ic_probe_required) {
		/*
		 * This fixed device must be ready before WMT publishes callbacks.
		 * Failed/deferred probes need a later WMT init retry. This API
		 * unregisters an unbound driver and rejects later probe attempts.
		 */
		g_wmt_probe_result = -ENODEV;
		iRet = platform_driver_probe(&mtk_wmt_dev_drv, mtk_wmt_probe);
		if (iRet == -ENODEV && g_wmt_probe_result)
			iRet = g_wmt_probe_result;
	} else {
		iRet = platform_driver_register(&mtk_wmt_dev_drv);
	}
	if (iRet) {
		WMT_PLAT_PR_ERR("WMT platform driver registered failed(%d)\n", iRet);
		wmt_consys_ic_ops = NULL;
		return iRet;
	}
	g_wmt_hw_registered = true;

	return 0;

}

INT32 mtk_wcn_consys_hw_deinit(VOID)
{
	if (!g_wmt_hw_registered)
		return 0;
	g_wmt_hw_registered = false;
	/* remove clears published handles before driver core releases devres. */
	platform_driver_unregister(&mtk_wmt_dev_drv);

	if (wmt_consys_ic_ops)
		wmt_consys_ic_ops = NULL;

	return 0;
}

INT32 mtk_wcn_consys_hw_restore(struct device *device)
{
	if (gConEmiPhyBase) {
		if (wmt_consys_ic_ops->consys_ic_emi_mpu_set_region_protection)
			wmt_consys_ic_ops->consys_ic_emi_mpu_set_region_protection();
		if (wmt_consys_ic_ops->consys_ic_emi_set_remapping_reg)
			wmt_consys_ic_ops->consys_ic_emi_set_remapping_reg();
		if (wmt_consys_ic_ops->consys_ic_emi_coredump_remapping)
			wmt_consys_ic_ops->consys_ic_emi_coredump_remapping(&pEmibaseaddr, 1);
	} else {
		WMT_PLAT_PR_ERR("consys emi memory address gConEmiPhyBase invalid\n");
	}

	return 0;
}

static VOID mtk_wmt_probe_cleanup(struct platform_device *pdev)
{
	if (wmt_consys_ic_ops->consys_ic_need_store_pdev &&
	    wmt_consys_ic_ops->consys_ic_need_store_pdev() == MTK_WCN_BOOL_TRUE)
		pm_runtime_disable(&pdev->dev);

	if (g_pdev == pdev) {
#ifdef CONFIG_MTK_HIBERNATION
		unregister_swsusp_restore_noirq_func(ID_M_CONNSYS);
#endif
		if (wmt_consys_ic_ops->consys_ic_dedicated_log_path_deinit)
			wmt_consys_ic_ops->consys_ic_dedicated_log_path_deinit();
	}
	if (pEmibaseaddr && wmt_consys_ic_ops->consys_ic_emi_coredump_remapping)
		wmt_consys_ic_ops->consys_ic_emi_coredump_remapping(&pEmibaseaddr, 0);

	/* Driver core releases managed mappings, clocks and pinctrl after return. */
	if (wmt_consys_ic_ops->consys_ic_probe_cleanup)
		wmt_consys_ic_ops->consys_ic_probe_cleanup();
	consys_pinctrl = NULL;
	gps_lna_pin_num = 0xffffffff;
	wifi_ant_swap_gpio_pin_num = -1;
	g_pdev = NULL;
}

static int platform_drv_probe(struct device *_dev)
{
	struct platform_driver *drv = to_platform_driver(_dev->driver);
	struct platform_device *dev = to_platform_device(_dev);
	int ret;

	ret = of_clk_set_defaults(_dev->of_node, false);
	if (ret < 0)
		return ret;

	ret = dev_pm_domain_attach(_dev, true);
	if (ret != -EPROBE_DEFER) {
		ret = drv->probe(dev);
		if (ret)
			dev_pm_domain_detach(_dev, true);
	}

	if (drv->prevent_deferred_probe && ret == -EPROBE_DEFER) {
		dev_warn(_dev, "probe deferral not supported\n");
		ret = -ENXIO;
	}

	return ret;
}

static int platform_drv_probe_fail(struct device *_dev)
{
	return -ENXIO;
}

static int platform_drv_remove(struct device *_dev)
{
	struct platform_driver *drv = to_platform_driver(_dev->driver);
	struct platform_device *dev = to_platform_device(_dev);
	int ret;

	ret = drv->remove(dev);
	dev_pm_domain_detach(_dev, true);

	return ret;
}

int __init_or_module platform_driver_probe(struct platform_driver *drv,
		int (*probe)(struct platform_device *))
{
	int retval, code;

	/*
	 * Prevent driver from requesting probe deferral to avoid further
	 * futile probe attempts.
	 */
	drv->prevent_deferred_probe = true;

	/* make sure driver won't have bind/unbind attributes */
	drv->driver.suppress_bind_attrs = true;

	/* temporary section violation during probe() */
	drv->probe = probe;
	retval = code = platform_driver_register(drv);

	/*
	 * Fixup that section violation, being paranoid about code scanning
	 * the list of drivers in order to probe new devices.  Check to see
	 * if the probe was successful, and make sure any forced probes of
	 * new devices fail.
	 */
	spin_lock(&drv->driver.bus->p->klist_drivers.k_lock);
	drv->probe = NULL;
	if (code == 0 && list_empty(&drv->driver.p->klist_devices.k_list))
		retval = -ENODEV;
	drv->driver.probe = platform_drv_probe_fail;
	spin_unlock(&drv->driver.bus->p->klist_drivers.k_lock);

	if (code != retval)
		platform_driver_unregister(drv);
	return retval;
}


static void resources_clean(void)
{
    assert(!allocations && !live_allocations && !live_devres && !device.dev.resources);
    assert(!g_pdev && !consys_pinctrl && !pEmibaseaddr);
    assert(!conn_reg.mcu_base && !conn_reg.ap_rgu_base && !conn_reg.topckgen_base && !conn_reg.spm_base);
    assert(!clk_scp_conn_main && !reg_VCN18 && !reg_VCN28 && !reg_VCN33_BT && !reg_VCN33_WIFI);
    assert(!gps_node.references && !pins_node.references);
    assert(!driver_registered && !device_bound && !pm_domain_attached);
}

static void clear_failures(void)
{
    fail_register = fail_groups = fail_clock = fail_pinctrl = 0;
    fail_resource = fail_map = fail_map_devres = fail_regulator = fail_regulator_devres = -1;
    fail_clock_devres = fail_pinctrl_devres = fail_emi_clear = fail_emi_dump = false;
    have_device = true;
    fail_framework = no_gps_phandle = no_gps_child = no_gps_properties = false;
    gps_uses_pinmux = true;
    wifi_gpio = 27;
    gConEmiPhyBase = 0x90000000;
    gConEmiSize = SZ_1M;
    device.dev.of_node = &root_node;
    map_attempts = regulator_attempts = map_devres_attempts = regulator_devres_attempts = 0;
#ifdef HOST_HAS_PROBE_GATE
    consys_ic_ops.consys_ic_probe_required = MTK_WCN_BOOL_TRUE;
#endif
}

static void healthy(void)
{
    assert(driver_registered && device_bound && g_pdev == &device);
    assert(conn_reg.mcu_base && conn_reg.ap_rgu_base && conn_reg.topckgen_base && conn_reg.spm_base);
    assert(clk_scp_conn_main && !IS_ERR(clk_scp_conn_main));
    assert(reg_VCN18 && reg_VCN28 && reg_VCN33_BT && reg_VCN33_WIFI && pEmibaseaddr);
    assert(!gps_node.references && !pins_node.references);
}

static bool is_case(const char *name, const char *expected) { return strcmp(name, expected) == 0; }
static int case_index(const char *name, const char *prefix)
{
    size_t size = strlen(prefix);
    return strncmp(name, prefix, size) == 0 ? atoi(name + size) : -1;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    const char *name = argv[1];
    int expected = 0, index, result;
    clear_failures();
    if ((index = case_index(name, "missing-register-resource-")) >= 0) {
        fail_resource = index; expected = -EINVAL;
    } else if ((index = case_index(name, "register-devres-allocation-")) >= 0) {
        fail_map_devres = index; expected = -ENOMEM;
    } else if ((index = case_index(name, "register-ioremap-failure-")) >= 0) {
        fail_map = index; expected = -ENOMEM;
    } else if ((index = case_index(name, "regulator-devres-allocation-")) >= 0) {
        fail_regulator_devres = index; expected = -ENOMEM;
    } else if ((index = case_index(name, "regulator-provider-failure-")) >= 0) {
        fail_regulator = index; expected = -EPROBE_DEFER;
    } else if (is_case(name, "driver-register-enomem")) {
        expected = fail_register = -ENOMEM;
    } else if (is_case(name, "driver-register-ebusy")) {
        expected = fail_register = -EBUSY;
    } else if (is_case(name, "driver-groups-rollback")) {
        expected = fail_groups = -ENOMEM;
    } else if (is_case(name, "driver-groups-rollback-after-probe-failure")) {
        expected = fail_groups = -EIO; fail_clock = -ENOENT;
    } else if (is_case(name, "no-matching-device")) {
        have_device = false; expected = -ENODEV;
    } else if (is_case(name, "probe-missing-device-node")) {
        device.dev.of_node = NULL; expected = -ENODEV;
    } else if (is_case(name, "clock-devres-allocation")) {
        fail_clock_devres = true; expected = -ENOMEM;
    } else if (is_case(name, "clock-provider-enoent")) {
        expected = fail_clock = -ENOENT;
    } else if (is_case(name, "clock-provider-deferred")) {
        expected = fail_clock = -EPROBE_DEFER;
    } else if (is_case(name, "emi-base-missing")) {
        gConEmiPhyBase = 0; expected = -ENODEV;
    } else if (is_case(name, "emi-size-zero")) {
        gConEmiSize = 0; expected = -EINVAL;
    } else if (is_case(name, "emi-clear-map-failure")) {
        fail_emi_clear = true; expected = -ENOMEM;
    } else if (is_case(name, "coredump-map-failure")) {
        fail_emi_dump = true; expected = -ENOMEM;
    } else if (is_case(name, "coredump-region-too-small")) {
        gConEmiSize = CONSYS_EMI_COREDUMP_OFFSET; expected = -EINVAL;
    } else if (is_case(name, "pinctrl-devres-allocation")) {
        fail_pinctrl_devres = true; expected = -ENOMEM;
    } else if (is_case(name, "pinctrl-provider-enomem")) {
        expected = fail_pinctrl = -ENOMEM;
    } else if (is_case(name, "pinctrl-provider-deferred")) {
        expected = fail_pinctrl = -EPROBE_DEFER;
    } else if (is_case(name, "optional-pinctrl-absent")) {
        fail_pinctrl = -ENODEV;
    } else if (is_case(name, "gps-pins-fallback")) {
        gps_uses_pinmux = false;
    } else if (is_case(name, "gps-phandle-absent")) {
        no_gps_phandle = true;
    } else if (is_case(name, "gps-child-absent")) {
        no_gps_child = true;
    } else if (is_case(name, "gps-properties-absent")) {
        no_gps_properties = true;
    } else if (is_case(name, "wifi-gpio-provider-deferred")) {
        expected = wifi_gpio = -EPROBE_DEFER;
    } else if (is_case(name, "optional-wifi-gpio-absent")) {
        wifi_gpio = -ENOENT;
    } else if (is_case(name, "framework-failure-before-probe")) {
        fail_framework = true; expected = -ENODEV;
    } else if (is_case(name, "legacy-ops-allow-unbound-registration")) {
        have_device = false;
#ifdef HOST_HAS_PROBE_GATE
        consys_ic_ops.consys_ic_probe_required = MTK_WCN_BOOL_FALSE;
#endif
    }

    if (is_case(name, "remove-before-probe")) {
        assert(mtk_wmt_remove(&device) == 0);
        assert(mtk_wcn_consys_hw_deinit() == 0);
        assert(!register_calls && !unregister_calls);
    } else if (is_case(name, "probe-null-device")) {
        wmt_consys_ic_ops = mtk_wcn_get_consys_ic_ops();
        assert(mtk_wmt_probe(NULL) == -EINVAL);
    } else {
        result = mtk_wcn_consys_hw_init();
        fprintf(stderr, "init_ret=%d expected=%d register=%u unregister=%u rollback=%u probe=%u remove=%u\n",
                result, expected, register_calls, unregister_calls, rollback_calls, probe_calls, remove_calls);
        assert(result == expected);
#ifdef HOST_HAS_PROBE_GATE
        if (consys_ic_ops.consys_ic_probe_required) {
            assert(mtk_wmt_dev_drv.prevent_deferred_probe);
            assert(mtk_wmt_dev_drv.driver.suppress_bind_attrs);
            assert(!mtk_wmt_dev_drv.probe);
            assert(mtk_wmt_dev_drv.driver.probe(&device.dev) == -ENXIO);
        }
#endif
        if (!result && have_device && !fail_framework) {
            healthy();
            if (is_case(name, "gps-properties-absent") || no_gps_child || no_gps_phandle || fail_pinctrl)
                assert(gps_lna_pin_num == 0xffffffff);
            else
                assert(gps_lna_pin_num == 27);
            if (is_case(name, "duplicate-hardware-init")) {
                assert(mtk_wcn_consys_hw_init() == -EBUSY);
                assert(register_calls == 1 && probe_calls == 1);
                healthy();
            }
            if (is_case(name, "coredump-restore-reuses-mapping")) {
                unsigned int mappings = dump_mappings;
                void *saved = pEmibaseaddr;
                assert(mtk_wcn_consys_hw_restore(&device.dev) == 0);
                assert(mtk_wcn_consys_hw_restore(&device.dev) == 0);
                assert(pEmibaseaddr == saved && dump_mappings == mappings);
            }
            if (is_case(name, "coredump-unmap-is-idempotent")) {
                assert(consys_emi_coredump_remapping(&pEmibaseaddr, 0) == 0);
                assert(consys_emi_coredump_remapping(&pEmibaseaddr, 0) == 0);
            }
        } else if (!result) {
            assert(driver_registered && !device_bound && !g_pdev);
        } else {
            resources_clean();
            if (fail_register || fail_groups)
                assert(unregister_calls == 0);
            else
                assert(unregister_calls == 1);
        }
        assert(mtk_wcn_consys_hw_deinit() == 0);
        unsigned int unregisters = unregister_calls;
        assert(mtk_wcn_consys_hw_deinit() == 0);
        assert(unregister_calls == unregisters);
    }
    resources_clean();
    /* Every injected failure must allow a fresh, complete successful cycle. */
    clear_failures();
    assert(mtk_wcn_consys_hw_init() == 0);
    healthy();
    assert(mtk_wcn_consys_hw_deinit() == 0);
    resources_clean();
    assert(gps_lna_pin_num == 0xffffffff && wifi_ant_swap_gpio_pin_num == -1);
    unsigned int unregisters = unregister_calls;
    assert(mtk_wcn_consys_hw_deinit() == 0);
    assert(unregister_calls == unregisters);
    printf("PASS: register=%u unregister=%u rollback=%u probe=%u remove=%u release_checks=%u\n",
           register_calls, unregister_calls, rollback_calls, probe_calls, remove_calls, release_checks);
    return 0;
}
