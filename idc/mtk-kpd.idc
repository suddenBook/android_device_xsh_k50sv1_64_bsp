# The keypad can lose the Volume Up release edge. Disable framework-synthesized
# repeats for this device so one stuck down event cannot produce an unbounded
# 50 ms repeat stream. Other input devices keep normal key repeat.
keyboard.handlesKeyRepeat = 1
