# WLAN first-enable warning: bounded diagnosis

**Conclusion:** the warning is a prebuilt WLAN diagnostic length-accounting bug. For the observed 952-byte initialization dump, truncation causes an oversized `snprintf` argument; the shipped kernel rejects it before accessing the destination. This path does **not** perform an out-of-bounds destination write. It does form an invalid destination pointer and call the formatter with an invalid size, so it remains a real module defect. No source-kernel change or WARN suppression is justified.

Scope: read-only analysis of kernel `2fa898562dbe6b41893e99f7dc1bc68b414b3813`, the existing vendor module, and the supplied first-boot log. No handset access, build, module replacement, or shared-source edits were performed. This conclusion covers this warning path, not the rest of the WLAN module.

## Identity and runtime match

The original vendor, staged vendor, and product-output copies of `wlan_drv_gen2.ko` are identical:

- SHA-256: `658b5fa6378267368c4b809f540b270efaee80062c374fb7250db7928a8bb84f`
- AArch64 ELF relocatable; build ID `46254f8ea1460dc7f9aacd4e1343b0e09eadbbd6`; srcversion `533BB7E5866E52F63B9ACCB`.
- Imported `snprintf` resolves to the source kernel; the dump helper itself is module code. Paths and hashes are in [identity.json](identity.json); ELF anchors are in [symbols.txt](symbols.txt).

[Numbered runtime evidence](runtime-warning.txt), from `runtime/first-boot/dmesg-completed.txt`:

| Original line | Evidence |
|---|---|
| 10122 / 10133 | At 147.912943 s, `vsnprintf:1731`; return PC `ffffffc0003a7b08`, exactly the built kernel's WARN call return. |
| 10135 | Module PC `ffffffbffc196204` = module text base + `0x204` = `dumpMemory8IEOneLine` + `0x9c`. |
| 10136 | Caller PC is module text + `0x404e4`, immediately after the dump call. |
| 10147 | Truncated output begins `[52:65:67:49:6e:66],Len:952:[`. |

## Actual caller and arithmetic

[Module disassembly](dump-memory-disassembly.txt) places the helper at `.text+0x168`. It zeroes a **1024-byte stack buffer**, writes the header, and loops over `min(input_length, 512)` unsigned bytes. [Format literals](dump-formats.txt) are `[%pM],Len:%u:[`, `%02x,`, and a final `]`.

The [caller](caller-disassembly.txt) passes length `0x3b8` (952) and the literal `RegInfo`. `%pM` prints that literal's first six bytes, explaining the apparently MAC-shaped `52:65:67:49:6e:66` prefix. The call is after NVRAM field population.

The trace's `wlanSubModInit+0xbdc` is a nearest-symbol label: that named function's ELF size is only `0x48`. The adjacent unnamed callback starts at `0x3f950`; [registration relocations](probe-callback-relocations.txt) and [module initialization](module-init.txt) establish that it is passed as the probe callback to `glRegisterBus`.

The append loop uses 32-bit subtraction and unconditionally adds `snprintf`'s return value:

```text
.text+0x1ec: sub w1, w23, w19      // size = u32(1024 - position)
.text+0x1fc: add x0, x0, w19,uxtw  // destination = buffer + position
.text+0x200: bl snprintf
.text+0x204: add w19, w19, w0      // adds required length after truncation too
```

With this 29-character header, each byte needs three characters:

| Byte index (zero based) | Position | Size argument | Result |
|---|---:|---:|---|
| 330 | 1019 | 5 | Three characters; return 3. |
| 331 | 1022 | 2 | One retained character plus NUL at offset 1023; still return 3. |
| 332–511 | 1025 | `0x00000000ffffffff` | Rejected; return 0; no destination access. |
| Closing bracket | 1025 | `0x00000000ffffffff` | Same rejection. |

The position therefore remains 1025. The 180 remaining byte appends and closing append are rejected. A complete capped dump would need 1567 bytes including its terminator. [arithmetic.py](arithmetic.py) reproduces this calculation; [output](arithmetic.txt) and [all calls](arithmetic.csv) are supplied. This is an arithmetic replay, not execution or instrumentation of the module.

## Why the kernel prevents a write

The source's `size > INT_MAX` check precedes destination setup. The [built entry instructions](kernel-vsnprintf-entry.txt) compare the 64-bit size against `0x7fffffff`; the [warning branch](kernel-vsnprintf-warning.txt) sets the result to zero and takes the [return path](kernel-vsnprintf-return.txt). Neither the first rejected call nor subsequent calls reaches formatting or destination stores. `WARN_ON_ONCE` suppresses repeated messages while continuing to return the condition; it does not disable the size check after the first warning.

This behavior matches [Linux 3.18.119's formatter](https://github.com/gregkh/linux/blob/v3.18.119/lib/vsprintf.c). Local `lib/vsprintf.c` and `include/asm-generic/bug.h` are unchanged between baseline `cff4b045c36` and the reviewed head.

For same-platform corroboration, the MediaTek-authored [MT6755 configuration](https://github.com/SonyCustoms/kernel_sony_tuba/blob/9171e8bd34dae219a4af6ceb76ed276c3fb96893/arch/arm64/configs/tuba_defconfig) and [Gen2 initialization source](https://github.com/SonyCustoms/kernel_sony_tuba/blob/9171e8bd34dae219a4af6ceb76ed276c3fb96893/drivers/misc/mediatek/connectivity/wlan/gen2/os/linux/gl_init.c) show `wlanProbe` registered with `glRegisterBus`, loading NVRAM into `rRegInfo` before firmware mapping and adapter startup. That public revision's [dump source](https://github.com/SonyCustoms/kernel_sony_tuba/blob/9171e8bd34dae219a4af6ceb76ed276c3fb96893/drivers/misc/mediatek/connectivity/wlan/gen2/common/dump.c) lacks this additional one-line helper. It corroborates the probe flow; **the shipped binary supplies the exact faulty arithmetic**. Pinned source copies are retained in this directory.

## Recommendation

Record this as an unresolved vendor-module diagnostic defect and retain the WARN. Repeated Wi-Fi enables without another message cannot demonstrate a fix because the warning is emitted once per boot at this check. Do not change global formatter semantics, suppress the WARN, or attribute this trace to the new source changes.

If the matching WLAN source becomes available, repair its bounded append accounting: stop on truncation, maintain an in-buffer position, and reserve room for closure and termination, or use a bounded multi-line hex dump. Rebuild and validate that module separately against the existing ABI and WLAN runtime requirements. No such change was made here.
