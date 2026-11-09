# RootHeld activation-entry milestone space review

Measured production source: `40619bdb44c3af19abab8cde3202c4194b5b3b2e`.
Baseline: published `88c1912cceb8305af9158b8fd4f9e60b392946a3`.
The baseline archive is the canonical main repository's
`.git/takibi-land/baselines/kernel-green-88c1912c`, not a worktree `.git` file.
The accompanying JSON records manifest, ELF and all four object hashes.
Later caller-policy and documentation commits leave this production source
fingerprint unchanged.

## Workload and accounting boundary

Use the maintained two-root boot isolation and image-growth probes, followed
by ordinary process dispatch, clone/exec/wait/reap, the full normal QEMU boot
and PTY smokes, affinity/GDB, DDB/oops, and the standard four-core RPi5 lane.
The probes retain actual owners and Running reservations while their roots
are live and consume them on cleanup. RootHeld adds no per-process fields,
heap allocation, pool metadata or persistent storage. Its source index and
view carry no stored payload; its retained helper calls still have code and
stack cost, shown below. A prepared token does not retain a returned borrow.

| Platform | Text before | Text after | Text delta | Data delta | BSS span delta | Named mutable payload delta | Image reservation delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| qemu | 818056 | 821568 | +3512 | 0 | 0 | 0 | 0 |
| rpi5 | 4202692 | 4206236 | +3544 | 0 | 0 | 0 | 0 |

The reservation boundary (`usable_ram_start`) stays at `0x40210000` on
QEMU and `0x7e0000` on RPi5. These boundaries are distinct from section payload.
Named data/BSS symbol sizes are unchanged. RPi5 boot and bounded-end pool
samples are preserved in JSON; their equality is an endpoint comparison,
not a claim about peak allocation or all possible workloads.

## Corrected frame observations

Disassembly command: `llvm-objdump-19 -d --no-show-raw-insn OBJECT`.
Observe the existing first-12-line prologue method, with hexadecimal negative
`stp` offsets recognized locally. The shared gate's decimal-only `stp` pattern
is unchanged. Both baseline and candidate scheduler frames are 3184 bytes in
production and 3312 in debug on both platforms; ext2 update frames are 2528
and 2640. The shared debug gate's smaller reported sizes are not actual frame
measurements or evidence that these existing baseline frames grew.

| Candidate helper (QEMU) | Production frame | Debug frame |
| --- | ---: | ---: |
| `root_held_owned` | 16 | 48 |
| `address_space_prepare_held` | 288 | 336 |
| `address_space_commit_held` | 64 | 160 |
| `address_space_activate_held` | 192 | 256 |
| `process_image_commit_activation` | 32 | 96 |
| `process_image_commit_current_activation` | 16 | 48 |
| `process_image_activation_committed` | 48 | 80 |
| `kernel_process_activate_stable_root` | 96 | 96 |
| `kernel_process_activate_stable_owned_root` | 112 | 144 |

These are selected per-function observations. In an image commit wrapper the
lower commit finishes before the success-trace helper starts; they are separate
branches of its call sequence, not one nested prefix. The RootHeld constructor,
owner-root lookup and lower entry likewise execute sequentially. No frame sum,
whole-callpath bound, interrupt nesting proof or whole 16 KiB stack proof is
claimed. The final QEMU debug object was rebuilt by runtime prerequisites;
all four final objects were measured after the chain ended, rather than using
the earlier before-comment debug object.

## Compile allocation and acceptance

The unchanged compiler's final uninstrumented QEMU compile allocated
593855601 OCaml words. This is compiler allocation, not kernel heap occupancy.
A bounded witness-propagation snapshot measured 99139467 words in that stage.
On matched earlier source the single disjoint candidate increased total
allocation from 593876226 to 624878992 and was discarded; restoration exactly
reproduced 593876226. The approved 743000000-word ceiling gives approximately
25 percent headroom around the final measurement. No compiler change remains.

Allbuild (including langcheck, slowcheck and compiler tests), linuxcheck,
modelcheck, serial normal/affinity/DDB/oops QEMU, and RPi5 each ended with status
zero on the measured source. Models remain bounded protocol evidence; they do
not prove root lifetime. Exact entry/caller source policies retain the trusted
physical owner/root association and do not introduce page-table write authority.
Image mapping still passes its explicit target through segment/page install and
stores it in ProcessImagePages.root; activation derives the root from retained
current or owned authority instead of substituting current root during mapping.

Accept the small text increase and retained helper frames for explicit entry
protection and must-use activation outcomes. No storage representation, safety
rule or shared frame budget was weakened. Existing cross-OS comparisons need
no repetition because this review changes neither their normalized workload nor
allocator boundary. Measure again when a root/owner lifetime or page-table write
boundary, context-switch activation path, allocation workload or stack-helper
structure changes.
