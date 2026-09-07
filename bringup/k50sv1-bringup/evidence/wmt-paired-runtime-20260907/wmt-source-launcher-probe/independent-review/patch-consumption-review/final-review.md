Reviewed `capture-build19-patch-consumption.py` at SHA-256 `4f1de93a049ba08f19ca06d9ad72b185a1c41095bd354e84ba88740fe24b090f`, with kernel `4192fb6ae88e057bb2abb0f464cf6b4cb64697de` and device source `c270801a1f214b3c56b16efda5742eb0947b0c37`.

PASS: no new findings at confidence 80 or higher within the requested parser and source-inference scope.

The pinned source has one positive publication route for normal metadata: a matching accepted v2 normal-list reply. The cold-boot download loop reads that cache in sequence order. Legacy metadata setters reject. The observed terminal records require successful transport, matching acknowledgments, and all fragments completed.

The 28-byte normal header is correct. Header sequence 1 is `ROMv2_lm_patch_1_1_hdr.bin`: 318,408 total bytes, 318,380 body bytes, 319 fragments, final fragment 380 bytes. Sequence 2 is `ROMv2_lm_patch_1_0_hdr.bin`: 179,699 total bytes, 179,671 body bytes, 180 fragments, final fragment 671 bytes.

The original collector's filename-order assumption caused the retained host failure. The corrected version validates count/sequence and sorts by header sequence. The original unmodified blocks still reject the actual capture; the corrected unmodified blocks reproduce both final capture results exactly.

- First boot `5707e604-68f3-4f50-ab7f-0aa6e0fb23e6`: accepted sequence 0–42705 through the 392.28-second cutoff; both expected downloads complete.
- Normal reboot `617ecc06-c2fc-404f-9af7-57a370fc85ce`: accepted sequence 0–10353 through the 52.15-second cutoff; both expected downloads complete.
- Offline verification passed 19/19 cases, including actual captures, the original ordering failure, missing/gapped/duplicate/reordered records, nonzero/failing transport results, fragment/body mismatch, unfinished downloads, bad firmware hashes, and invalid header sequence/count. Process launches were blocked; no ADB calls occurred.
- Consumed byte prefixes match their recorded hashes. Both captures' six source copies match pinned Git objects; identity, module, firmware hashes, and 30 installed-file readbacks agree. All 65 previously frozen probe-review files remain unchanged.

These observations support accepted-v2 cache consumption and successful transfers of the two expected body lengths. They do not independently expose exact reply contents, cold userspace session IDs, cache names/addresses, or bus-level firmware bytes. The contiguous sequence-zero requirement applies to the parsed prefix through the recorded uptime cutoff, not the entire boot log.

Reproduce the offline checks with `python3 verify_offline.py --output validation-replay-NEW`, choosing a new child directory. Detailed source ranges and evidence hashes are retained in `source-semantics.json`, `final-review.json`, and `snapshot-sha256.json`.
