#define BUF_LEN_MAX 384

#if (defined(CONFIG_MTK_GMO_RAM_OPTIMIZE) && !defined(CONFIG_MTK_ENG_BUILD))
#define WMT_EMI_DEBUG_BUF_SIZE (8*1024)
#else
#define WMT_EMI_DEBUG_BUF_SIZE (32*1024)
#endif
static UINT8 gEmiBuf[WMT_EMI_DEBUG_BUF_SIZE];
PUINT8 buf_emi;
static OSAL_SLEEPABLE_LOCK g_dbg_emi_lock;

INT32 osal_lock_sleepable_lock(P_OSAL_SLEEPABLE_LOCK pSL)
{
	return mutex_lock_killable(&pSL->lock);
}

INT32 osal_unlock_sleepable_lock(P_OSAL_SLEEPABLE_LOCK pSL)
{
	mutex_unlock(&pSL->lock);
	return 0;
}

UINT8 *wmt_lib_get_fwinfor_from_emi(UINT8 section, UINT32 offset, UINT8 *buf, UINT32 len)
{
	UINT8 *pAddr = NULL;
	UINT32 sublen1 = 0;
	UINT32 sublen2 = 0;
	P_CONSYS_EMI_ADDR_INFO p_consys_info;

	p_consys_info = wmt_plat_get_emi_phy_add();
	osal_assert(p_consys_info);

	if (section == 0) {
		pAddr = wmt_plat_get_emi_virt_add(0x0);
		if (len > 1024)
			len = 1024;
		if (!pAddr) {
			WMT_ERR_FUNC("wmt-lib: get EMI virtual base address fail\n");
		} else {
			WMT_INFO_FUNC("vir addr(0x%p)\n", pAddr);
			osal_memcpy_fromio(&buf[0], pAddr, len);
		}
	} else {
		if (p_consys_info == NULL) {
			WMT_ERR_FUNC("wmt-lib: get EMI physical address fail!\n");
			return 0;
		}

		if (offset >= 0x7fff)
			offset = 0x0;

		if (offset + len > 32768) {
			pAddr = wmt_plat_get_emi_virt_add(offset + p_consys_info->paged_trace_off);
			if (!pAddr) {
				WMT_ERR_FUNC("wmt-lib: get part1 EMI virtual base address fail\n");
			} else {
				WMT_INFO_FUNC("part1 vir addr(0x%p)\n", pAddr);
				sublen1 = 0x7fff - offset;
				osal_memcpy_fromio(&buf[0], pAddr, sublen1);
			}
			pAddr = wmt_plat_get_emi_virt_add(p_consys_info->paged_trace_off);
			if (!pAddr) {
				WMT_ERR_FUNC("wmt-lib: get part2 EMI virtual base address fail\n");
			} else {
				WMT_INFO_FUNC("part2 vir addr(0x%p)\n", pAddr);
				sublen2 = len - sublen1;
				osal_memcpy_fromio(&buf[sublen1], pAddr, sublen2);
			}
		} else {
			pAddr = wmt_plat_get_emi_virt_add(offset + p_consys_info->paged_trace_off);
			if (!pAddr) {
				WMT_ERR_FUNC("wmt-lib: get EMI virtual base address fail\n");
			} else {
				WMT_INFO_FUNC("vir addr(0x%p)\n", pAddr);
				osal_memcpy_fromio(&buf[0], pAddr, len);
			}
		}
	}

	return 0;
}

static VOID wmt_dbg_fwinfor_print_buff(UINT32 len)
{
	UINT32 i = 0;
	UINT32 idx = 0;

	for (i = 0; i < len; i++) {
		buf_emi[idx] = gEmiBuf[i];
		if (gEmiBuf[i] == '\n') {
			WMT_INFO_FUNC("%s", buf_emi);
			osal_memset(buf_emi, 0, BUF_LEN_MAX);
			idx = 0;
		} else {
			idx++;
			if (idx == BUF_LEN_MAX-1) {
				buf_emi[idx] = '\0';
				WMT_INFO_FUNC("%s", buf_emi);
				osal_memset(buf_emi, 0, BUF_LEN_MAX);
				idx = 0;
			}
		}
	}
	if ((idx != 0) && (idx < BUF_LEN_MAX)) {
		buf_emi[idx] = '\0';
		WMT_INFO_FUNC("%s", buf_emi);
		osal_memset(buf_emi, 0, BUF_LEN_MAX);
		idx = 0;
	}
}

INT32 wmt_dbg_fwinfor_from_emi(INT32 par1, INT32 par2, INT32 par3)
{
	UINT32 offset = 0;
	UINT32 len = 0;
	UINT32 *pAddr = NULL;
	UINT32 cur_idx_pagedtrace;
	static UINT32 prev_idx_pagedtrace;
	MTK_WCN_BOOL isBreak = MTK_WCN_BOOL_TRUE;

	offset = par2;
	len = par3;

	if (osal_lock_sleepable_lock(&g_dbg_emi_lock)) {
		WMT_ERR_FUNC("lock failed\n");
		return -1;
	}

	buf_emi = kmalloc(sizeof(UINT8) * BUF_LEN_MAX, GFP_KERNEL);
	if (!buf_emi) {
		WMT_ERR_FUNC("buf kmalloc memory fail\n");
		return 0;
	}
	osal_memset(buf_emi, 0, BUF_LEN_MAX);
	osal_memset(&gEmiBuf[0], 0, WMT_EMI_DEBUG_BUF_SIZE);
	wmt_lib_get_fwinfor_from_emi(0, offset, &gEmiBuf[0], 0x100);

	if (offset == 1) {
		do {
			pAddr = (PUINT32) wmt_plat_get_emi_virt_add(0x24);
			if (pAddr == NULL) {
				WMT_ERR_FUNC("get virtual emi address 0x24 fail!\n");
				return -1;
			}
			cur_idx_pagedtrace = *pAddr;

			if (cur_idx_pagedtrace > prev_idx_pagedtrace) {
				len = cur_idx_pagedtrace - prev_idx_pagedtrace;
				wmt_lib_get_fwinfor_from_emi(1, prev_idx_pagedtrace, &gEmiBuf[0], len);
				wmt_dbg_fwinfor_print_buff(len);
				prev_idx_pagedtrace = cur_idx_pagedtrace;
			}

			if (cur_idx_pagedtrace < prev_idx_pagedtrace) {
				if (prev_idx_pagedtrace >= 0x8000) {
					WMT_INFO_FUNC("++ prev_idx_pagedtrace invalid ...++\n\\n");
					prev_idx_pagedtrace = 0x8000 - 1;
					continue;
				}

				len = 0x8000 - prev_idx_pagedtrace - 1;
				wmt_lib_get_fwinfor_from_emi(1, prev_idx_pagedtrace, &gEmiBuf[0], len);
				WMT_INFO_FUNC("\n\n -- CONNSYS paged trace ascii output (cont...) --\n\n");
				wmt_dbg_fwinfor_print_buff(len);

				len = cur_idx_pagedtrace;
				wmt_lib_get_fwinfor_from_emi(1, 0x0, &gEmiBuf[0], len);
				WMT_INFO_FUNC("\n\n -- CONNSYS paged trace ascii output (end) --\n\n");
				wmt_dbg_fwinfor_print_buff(len);
				prev_idx_pagedtrace = cur_idx_pagedtrace;
			}
			msleep(100);
		} while (isBreak);
	}

	WMT_INFO_FUNC("\n\n -- control word --\n\n");
	wmt_dbg_fwinfor_print_buff(256);
	if (len > 1024 * 4)
		len = 1024 * 4;

	WMT_WARN_FUNC("get fw infor from emi at offset(0x%x),len(0x%x)\n", offset, len);
	osal_memset(&gEmiBuf[0], 0, WMT_EMI_DEBUG_BUF_SIZE);
	wmt_lib_get_fwinfor_from_emi(1, offset, &gEmiBuf[0], len);

	WMT_INFO_FUNC("\n\n -- paged trace hex output --\n\n");
	wmt_dbg_fwinfor_print_buff(len);
	WMT_INFO_FUNC("\n\n -- paged trace ascii output --\n\n");
	wmt_dbg_fwinfor_print_buff(len);
	kfree(buf_emi);
	osal_unlock_sleepable_lock(&g_dbg_emi_lock);

	return 0;
}
