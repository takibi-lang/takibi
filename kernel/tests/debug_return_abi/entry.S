// GitHub issue #713: the smallest EL1 entry for the debug-return fixture on
// QEMU virt: a stack, FP/SIMD enabled, the fixture, then semihosting exit.
    .section .text.boot, "ax"
    .global _start
_start:
    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    ldr     x0, =debug_abi_stack_top
    mov     sp, x0
    bl      debug_abi_main
    mov     x0, #0x18
    ldr     x1, =debug_abi_exit_block
    hlt     #0xf000
1:  b       1b

    .section .data
    .balign 8
debug_abi_exit_block:
    .quad   0x20026
    .quad   0

    .section .bss
    .balign 16
debug_abi_stack:
    .space  16384
debug_abi_stack_top:
