# The keypad can leave Volume Up reported as stuck DOWN. Repeated hardware
# scans keep its matrix bit asserted, most likely from the switch/flex/matrix
# path, with a latched controller state still possible. Disable framework
# repeats so that state cannot produce an unbounded 50 ms stream. This affects
# every key on mtk-kpd (held Volume Down adjusts once) but leaves other input
# devices unchanged. Raw getevent state remains visible for hardware diagnosis.
keyboard.handlesKeyRepeat = 1
