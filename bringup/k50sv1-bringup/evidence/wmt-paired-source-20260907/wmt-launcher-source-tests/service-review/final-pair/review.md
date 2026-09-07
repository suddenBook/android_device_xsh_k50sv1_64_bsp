# Final launcher and v2 broker review

Reviewed launcher `2cbfa92e64e2b01461de512e4feb2c5676406125` with broker
`857d2d0b238231ad931e342c6950c458dae99063` and required firmware-log dependency
`75f4664c480ccbf64b764406776e8a3d88a3325b`. No new findings reached the
confidence threshold of 80. All three source trees were clean at verification.

The two initial service findings are resolved by this pair. Read-side
`EAGAIN` and `ETIMEDOUT` preserve the command session and retry. Firmware
logging repeats bounded kernel drains, then joins the worker before final
disable; the ioctl dispatcher propagates collector errors. Applying the
broker without the bounded collector would leave the earlier hang unresolved.

The kernel-exported and launcher UAPI files are byte-identical. Startup binds
the negotiated session before HIF setup, kill-clear, readiness and the separate
power worker. Each request and reply carries session/transaction identity.
The broker parses one private reply copy and checks identity, delivery state
and deadline before publishing metadata and waking the producer. A stale
reply cannot alter the metadata cache or launcher version properties.

Normal lists require a complete set of 1..count sequences; ROM lists support
zero entries and independently optional types 0..4. Native and compat legacy
setters are rejected. The launcher handles unknown commands with a negative
tagged status and publishes versions only after a full accepted write.

Optional dynamic-dump and logging failures retain a pending request for later
poll iterations. A failed logging worker is joined before replacement, and
shutdown retains final disable if replacement creation fails. Unbinding the
command session precedes the power-worker join; logging joins precede file
close and final disable follows the last bounded enable.

Verification checked all 14 broker source hashes and nine recorded result
hashes. The launcher evidence matches 35/35 ASan/UBSan and 17/17 TSan cases,
including every recorded source and artifact hash. Broker 74/74 ASan/UBSan
and 5/5 TSan result sources and extracted fixtures also match the frozen
commit. These are verified author test results; this final review did not
repeat the suites. `review.json` records exact source/function hashes and
line ranges, initial finding IDs, and evidence references.

The later integrated kernel `4192fb6ae88e057bb2abb0f464cf6b4cb64697de`
matches the reviewed broker and collector files. Its real broker/userspace
host pair passes 6/6 cases under ASan/UBSan and 6/6 under TSan. Independent
checks matched each run's seven kernel, 19 device, six harness and all output
hashes, and found 39 complete original kernel function bodies, each once in
the generated fixture. The full launcher is included by its syscall adapter;
the ioctl fixture keeps the relevant original case blocks. HIF, power,
properties, allocation/user-copy and waiting remain host adapters.

These six cases cover retained normal firmware, synthetic ROM types 0..4,
empty ROM, missing normal firmware, negative unknown commands, cancellation,
duplicate stale replies and stop with a pending request. The first run's
close-pending expectation was corrected from `ECANCELED` to the implemented
`ECONNRESET`; comparing the preserved harness shows exactly that one assertion
change and no production change. The initial 5/6 result remains retained.

The final standalone Android ARM64 and ARM binaries, commands, logs and source
hashes match the launcher commit. All nine integrated ARM64 kernel objects,
commands, logs and source hashes also match. This evidence reveals no new
pairing gap that should block build18. No suite was repeated during this check.

The collector and firmware helper were authored in this branch of work;
this report checks them as interface dependencies and does not claim an
independent audit of their implementation. The collector receives a separate
review. Host integration and standalone target compilation remain distinct
from the linked product build and handset validation. No production files were
changed and no device commands were run during this final review.
