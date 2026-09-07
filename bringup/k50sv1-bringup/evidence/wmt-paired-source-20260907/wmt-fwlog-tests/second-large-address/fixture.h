#define BUF_LEN_MAX 384
#define WMT_PAGED_TRACE_SIZE (32 * 1024)
/* The retained trace format leaves the final byte outside the ring payload. */
#define WMT_PAGED_TRACE_END (WMT_PAGED_TRACE_SIZE - 1)

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

static INT32 wmt_dbg_fwinfor_trace_to(PUINT8 trace, PUINT8 control,
				     PUINT32 cursor, UINT32 end)
{
	while (*cursor < end) {
		UINT32 len;

		if (signal_pending(current))
			return -EINTR;
		if (readl(control + EXP_APMEM_CTRL_CHIP_FW_DBGLOG_MODE) != 1)
			return 1;
		len = min_t(UINT32, end - *cursor, sizeof(gEmiBuf));
		osal_memcpy_fromio(gEmiBuf, trace + *cursor, len);
		wmt_dbg_fwinfor_print_buff(len);
		*cursor += len;
	}
	return 0;
}

INT32 wmt_dbg_fwinfor_from_emi(INT32 par1, INT32 par2, INT32 par3)
{
	static UINT32 prev_idx_pagedtrace;
	P_CONSYS_EMI_ADDR_INFO info;
	PUINT8 control, trace, line_buffer;
	UINT32 offset, len, first, index;
	INT32 ret = 0;
	bool streaming;

	if (par2 < 0 || par2 > WMT_PAGED_TRACE_END || par3 < 0)
		return -EINVAL;
	if (signal_pending(current))
		return -EINTR;
	offset = par2;
	/* The ioctl passes par1=0: drain one producer-index snapshot and return.
	 * Proc command 0x19 keeps streaming, releasing the lock between passes.
	 */
	streaming = par1 != 0 && offset == 1;
	line_buffer = kmalloc(BUF_LEN_MAX, GFP_KERNEL);
	if (!line_buffer)
		return -ENOMEM;

	do {
		ret = mutex_lock_interruptible(&g_dbg_emi_lock.lock);
		if (ret)
			break;
		buf_emi = line_buffer;
		osal_memset(buf_emi, 0, BUF_LEN_MAX);
		info = wmt_plat_get_emi_phy_add();
		control = wmt_plat_get_emi_virt_add(0);
		trace = info ? wmt_plat_get_emi_virt_add(info->paged_trace_off) : NULL;
		if (!control || !trace) {
			WMT_ERR_FUNC("firmware trace EMI mapping unavailable\n");
			ret = -ENODEV;
			goto unlock;
		}
		if (signal_pending(current)) {
			ret = -EINTR;
			goto unlock;
		}
		if (offset == 1) {
			if (readl(control + EXP_APMEM_CTRL_CHIP_FW_DBGLOG_MODE) != 1) {
				ret = 1;
				goto unlock;
			}
			index = readl(control + 0x24);
			if (index >= WMT_PAGED_TRACE_SIZE) {
				WMT_ERR_FUNC("invalid firmware trace index 0x%x\n", index);
				ret = -ERANGE;
				goto unlock;
			}
			if (index < prev_idx_pagedtrace) {
				ret = wmt_dbg_fwinfor_trace_to(trace, control,
						&prev_idx_pagedtrace, WMT_PAGED_TRACE_END);
				if (ret)
					goto unlock;
				prev_idx_pagedtrace = 0;
			}
			ret = wmt_dbg_fwinfor_trace_to(trace, control, &prev_idx_pagedtrace, index);
		} else {
			osal_memcpy_fromio(gEmiBuf, control, 0x100);
			WMT_INFO_FUNC("\n\n -- control word --\n\n");
			wmt_dbg_fwinfor_print_buff(0x100);
			len = min_t(UINT32, par3, min_t(UINT32, sizeof(gEmiBuf), 4096));
			if (offset == WMT_PAGED_TRACE_END)
				offset = 0;
			first = min_t(UINT32, len, WMT_PAGED_TRACE_END - offset);
			osal_memcpy_fromio(gEmiBuf, trace + offset, first);
			if (first < len)
				osal_memcpy_fromio(gEmiBuf + first, trace, len - first);
			WMT_WARN_FUNC("get fw infor from emi at offset(0x%x),len(0x%x)\n", offset, len);
			WMT_INFO_FUNC("\n\n -- paged trace hex output --\n\n");
			wmt_dbg_fwinfor_print_buff(len);
			WMT_INFO_FUNC("\n\n -- paged trace ascii output --\n\n");
			wmt_dbg_fwinfor_print_buff(len);
		}
unlock:
		buf_emi = NULL;
		osal_unlock_sleepable_lock(&g_dbg_emi_lock);
		if (ret == 1) {
			ret = 0;
			break;
		}
		if (ret || !streaming)
			break;
		if (msleep_interruptible(100)) {
			ret = -EINTR;
			break;
		}
	} while (1);

	kfree(line_buffer);
	return ret;
}
