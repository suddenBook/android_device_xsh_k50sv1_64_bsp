#!/usr/bin/env python3
"""Independent probe boundaries and complete platform/barrier/probe composition."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

CASES = ["framework-clock-enomem", "framework-pm-deferred", "framework-pm-other-error",
         "required-regulator-enodev", "exact-coredump-region", "duplicate-probe-keeps-binding",
         "platform-rejects-deferred-probe", "callback-thermal-before-devres",
         "callback-assert-before-devres", "callback-clock-before-devres"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sanitizer", choices=["address", "thread"], default="address")
    parser.add_argument("--bridge-revision", help="Negative control: substitute only the builtin bridge from this revision")
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    root = args.kernel.resolve()
    test = root / "drivers/misc/mediatek/connectivity/source/common/test"
    original_runner = test / "test_wmt_probe_lifecycle.py"
    ns = {"__file__": str(original_runner), "__name__": "review_import"}
    exec(compile(original_runner.read_text(), str(original_runner), "exec"), ns)
    function = ns["function"]
    common = "drivers/misc/mediatek/connectivity/source/common/common_main/"
    paths = [common + "platform/" + name for name in
             ["mtk_wcn_consys_hw.c", "mt6755.c", "include/mtk_wcn_consys_hw.h", "include/mt6755.h"]]
    paths += ["lib/devres.c", "drivers/clk/clk-devres.c", "drivers/regulator/devres.c",
              "drivers/pinctrl/core.c", "drivers/base/platform.c"]
    inputs = {name: (root / name).read_bytes() for name in paths}
    source = ns["fixture"]([inputs[name].decode() for name in paths])
    source = source[:source.index("int main(int argc, char **argv)\n{")]
    prefix = """#include <pthread.h>
#include <stdatomic.h>
static atomic_int review_active_callbacks;
static int review_framework_errno, review_pm_errno;
static int review_regulator_errno = -517;
"""
    source = prefix + source

    def replace_host_function(name, replacement):
        nonlocal source
        match = re.search(r"(?m)^static [^;\n]*\b" + re.escape(name) + r"\([^;{}]*\)\n\{", source)
        assert match, name
        depth = 1
        end = match.end()
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        old = source[match.start():end] + "\n"
        assert source.count(old) == 1
        source = source.replace(old, replacement + "\n", 1)

    replace_host_function("of_clk_set_defaults", """static int of_clk_set_defaults(struct device_node *node, bool supplier)
{
    return review_framework_errno ? review_framework_errno : (fail_framework ? -EPROBE_DEFER : 0);
}""")
    replace_host_function("dev_pm_domain_attach", """static int dev_pm_domain_attach(struct device *dev, bool power_on)
{
    assert(!pm_domain_attached);
    if (review_pm_errno)
        return review_pm_errno;
    pm_domain_attached = true;
    return 0;
}""")
    replace_host_function("dev_pm_domain_detach", """static void dev_pm_domain_detach(struct device *dev, bool power_off)
{
    /* Actual API is harmless when no domain attached. */
    pm_domain_attached = false;
}""")
    old = function(source, "regulator_get")
    source = source.replace(old, old.replace("ERR_PTR(-EPROBE_DEFER)", "ERR_PTR(review_regulator_errno)"), 1)
    old = function(source, "require_handles_withdrawn")
    new = old.replace("{\n", "{\n    assert(atomic_load(&review_active_callbacks) == 0 && \"devres release while callback is active\");\n", 1)
    source = source.replace(old, new, 1)

    extra_names = {
        "bridge": "drivers/misc/mediatek/connectivity/common/wmt_build_in_adapter.c",
        "bridge_h": "drivers/misc/mediatek/connectivity/common/wmt_build_in_adapter.h",
        "stub": "drivers/misc/mediatek/connectivity/source/common/common_detect/mtk_wcn_stub_alps.c",
        "stub_h": "drivers/misc/mediatek/include/mt-plat/mtk_wcn_cmb_stub.h",
        "plat": common + "platform/wmt_plat_alps.c", "plat_h": common + "include/wmt_plat.h",
        "exp_h": common + "include/wmt_exp.h",
        "detect_h": "drivers/misc/mediatek/connectivity/source/common/common_detect/wmt_detect.h",
    }
    extra = {}
    for key, name in extra_names.items():
        data = (subprocess.check_output(["git", "show", args.bridge_revision + ":" + name], cwd=root)
                if key == "bridge" and args.bridge_revision else (root / name).read_bytes())
        inputs[name] = data
        extra[key] = data.decode()
    types = re.search(r"typedef enum _ENUM_WMT_CHIP_TYPE_T \{.*?^\} ENUM_WMT_CHIP_TYPE;", extra["detect_h"], re.M | re.S)[0] + "\n"
    types += re.search(r"typedef enum _ENUM_WMTDRV_TYPE_T \{.*?^\}[^;]*;", extra["exp_h"], re.M | re.S)[0] + "\n"
    types += "\n".join(re.findall(r"^typedef[^\n]*wmt_bridge_[^\n]*;$", extra["bridge_h"], re.M)) + "\n"
    types += re.search(r"struct wmt_platform_bridge \{.*?^\};", extra["bridge_h"], re.M | re.S)[0] + "\n"
    for name in ["CMB_STUB_AIF_X", "CMB_STUB_AIF_CTRL"]:
        types += re.search(r"enum " + name + r" \{.*?^\};", extra["stub_h"], re.M | re.S)[0] + "\n"
    types += extra["stub_h"][extra["stub_h"].index("typedef int (*wmt_aif_ctrl_cb)"):extra["stub_h"].index("typedef void (*msdc_sdio_irq_handler_t)")]
    types += re.search(r"struct _CMB_STUB_CB_ \{.*?^\};", extra["stub_h"], re.M | re.S)[0] + "\n"
    types += "\n".join(re.findall(r"^typedef[^\n]*(?:thermal_query_ctrl_cb|trigger_assert_cb)[^\n]*;$", extra["plat_h"], re.M)) + "\n"
    states = "\n".join(re.findall(r"^static wmt_[^\n]* cmb_stub_[^;\n]*;$", extra["stub"], re.M)) + "\n"
    states += "\n".join(re.findall(r"^(?:static )?(?:thermal_query_ctrl_cb|trigger_assert_cb|bool|ENUM_WMT_CHIP_TYPE|UINT32) "
                                    r"(?:wmt_plat_thermal_query_ctrl_cb|wmt_plat_trigger_assert_cb|g_wmt_plat_\w+|gCoClockFlag)[^;\n]*;$", extra["plat"], re.M)) + "\n"
    functions = []
    for name in ["query_ctrl", "trigger_assert"]:
        start = extra["stub"].index("#ifdef MTK_WCN_REMOVE_KERNEL_MODULE\nint mtk_wcn_cmb_stub_" + name + "(void)")
        functions.append(extra["stub"][start:extra["stub"].index("\n}", start) + 2] + "\n")
    functions += [function(extra["stub"], name) for name in
                  ["_mtk_wcn_cmb_stub_clock_fail_dump", "mtk_wcn_cmb_stub_reg", "mtk_wcn_cmb_stub_unreg"]]
    functions += [function(extra["plat"], name) for name in
                  ["wmt_plat_init", "wmt_plat_deinit", "wmt_plat_thermal_ctrl", "wmt_plat_assert_ctrl",
                   "wmt_plat_clock_fail_dump", "wmt_plat_soc_co_clock_flag_set",
                   "wmt_plat_thermal_ctrl_cb_reg", "wmt_plat_trigger_assert_cb_reg"]]
    functions += [function(inputs[paths[0]].decode(), name) for name in
                  ["mtk_wcn_consys_clock_fail_dump", "mtk_wcn_consys_co_clock_type"]]
    prototypes = "\n".join(value[:value.index("\n{")] + "\n;" for value in functions)
    unused = []
    for name in ["wmt_plat_audio_ctrl", "wmt_plat_func_ctrl", "wmt_plat_deep_idle_ctrl"]:
        signature = function(extra["plat"], name).split("\n{", 1)[0]
        unused.append(signature + ("\n{}\n" if "VOID " in signature else "\n{ return 0; }\n"))
    start = extra["bridge"].index("static struct wmt_platform_bridge bridge;")
    end = extra["bridge"].index("/*******************************************************************************", start)
    bridge = extra["bridge"][start:end]
    extension_path = Path(__file__).with_name("review_extension.c")
    extension = extension_path.read_text()
    for marker, text in [("REVIEW_TYPES", types), ("REVIEW_STATES", states), ("REVIEW_PROTOTYPES", prototypes),
                         ("REVIEW_UNUSED_PAYLOADS", "\n".join(unused)), ("REVIEW_BRIDGE", bridge),
                         ("REVIEW_FUNCTIONS", "\n".join(functions))]:
        extension = extension.replace("/* " + marker + " */", text)
    source += extension
    # Whole extracted function bodies, including all driver/probe/devm code, stay unchanged.
    fidelity = []
    for value in functions + [bridge]:
        assert source.count(value) == 1
        fidelity.append({"first_line": value.splitlines()[0], "sha256": hashlib.sha256(value.encode()).hexdigest()})
    for name, data in inputs.items():
        if name not in paths:
            continue
        original = data.decode()
        for match in re.finditer(r"(?m)^[A-Za-z_][^;\n]*\b([A-Za-z_][A-Za-z_0-9]*)\([^;{}]*\)\n\{", original):
            value = function(original, match[1])
            if value in source:
                fidelity.append({"path": name, "function": match[1], "sha256": hashlib.sha256(value.encode()).hexdigest()})
    if args.case and set(args.case) - set(CASES):
        parser.error("unknown case")
    selected = args.case or CASES
    args.output.mkdir(parents=True, exist_ok=False)
    fixture = args.output / "fixture.c"
    fixture.write_text(source)
    binary = args.output / "fixture"
    sanitizer = "address,undefined" if args.sanitizer == "address" else "thread"
    command = shlex.split(os.environ.get("CC", "cc")) + ["-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-function", "-Wno-unused-variable", "-Wno-unused-parameter", "-Wno-unused-but-set-variable",
        "-pthread", "-fsanitize=" + sanitizer, "-fno-sanitize-recover=all", "-fno-omit-frame-pointer", "-no-pie",
        str(fixture), "-o", str(binary)]
    compiled = subprocess.run(command, capture_output=True)
    (args.output / "compile.txt").write_bytes(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        raise SystemExit(compiled.stderr.decode())
    rows = []
    for name in selected:
        try:
            run = subprocess.run([str(binary), name], capture_output=True, timeout=15,
                                 env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1:halt_on_error=1", TSAN_OPTIONS="halt_on_error=1"))
            output, code = run.stdout + run.stderr, run.returncode
        except subprocess.TimeoutExpired as exc:
            output, code = (exc.stdout or b"") + (exc.stderr or b"") + b"Timed out\n", 124
        (args.output / (name + ".txt")).write_bytes(output)
        rows.append({"case": name, "passed": code == 0, "exit_code": code,
                     "diagnostic": output.decode(errors="replace") if code else None})
        print(("PASS " if code == 0 else "FAIL ") + name, flush=True)
    record = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "bridge_revision": args.bridge_revision, "passed": sum(r["passed"] for r in rows), "total": len(rows),
              "cases": rows, "sanitizer": sanitizer, "compiler": command,
              "source_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()},
              "whole_function_fidelity": fidelity, "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
              "original_runner_sha256": hashlib.sha256(original_runner.read_bytes()).hexdigest(),
              "original_host_sha256": hashlib.sha256((test / "wmt_probe_lifecycle_host.c").read_bytes()).hexdigest(),
              "review_runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "review_extension_sha256": hashlib.sha256(extension_path.read_bytes()).hexdigest()}
    (args.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(record["passed"] != record["total"])


if __name__ == "__main__":
    main()
