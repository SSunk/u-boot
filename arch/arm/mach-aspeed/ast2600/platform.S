// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) ASPEED Technology Inc.
 * Chia-Wei Wang <chiawei_wang@aspeedtech.com>
 */

#include <config.h>
#include <version.h>
#include <asm/secure.h>
#include <asm/armv7.h>
#include <linux/linkage.h>

/*
 *       SMP mailbox
 * +----------------------+ 0x40
 * | cpuN sec_entrypoint  |
 * +----------------------+ 0x3c
 * |                      |
 * | mailbox insn. for    |
 * | cpuN GO sign polling |
 * |                      |
 * +----------------------+ 0x10
 * | mailbox ready        |
 * +----------------------+ 0x0c
 * | reserved             |
 * +----------------------+ 0x08
 * | cpuN GO signal       |
 * +----------------------+ 0x04
 * | cpuN ns_entrypoint   |
 * +----------------------+ SCU180
 */

#define SCU_BASE		0x1e6e2000
#define SCU_PROT_KEY1		(SCU_BASE)
#define SCU_PROT_KEY2		(SCU_BASE + 0x010)
#define SCU_REV_ID		(SCU_BASE + 0x014)
#define SCU_SYSRST_CTRL		(SCU_BASE + 0x040)
#define SCU_SYSRST_CTRL_CLR	(SCU_BASE + 0x044)
#define SCU_SYSRST_EVENT	(SCU_BASE + 0x064)
#define SCU_CLK_STOP_CTRL_CLR	(SCU_BASE + 0x084)
#define SCU_DEBUG_CTRL		(SCU_BASE + 0x0c8)
#define SCU_DEBUG_CTRL2		(SCU_BASE + 0x0d8)
#define SCU_SMP_NS_EP		(SCU_BASE + 0x180)
#define SCU_SMP_GO		(SCU_BASE + 0x184)
#define SCU_SMP_READY		(SCU_BASE + 0x18c)
#define SCU_SMP_POLLINSN	(SCU_BASE + 0x190)
#define SCU_SMP_S_EP		(SCU_BASE + 0x1bc)
#define SCU_HPLL_PARAM		(SCU_BASE + 0x200)
#define SCU_HPLL_PARAM_EXT	(SCU_BASE + 0x204)
#define SCU_USB_MULTI_FUNC	(SCU_BASE + 0x440)
#define SCU_HW_STRAP1		(SCU_BASE + 0x500)
#define SCU_HW_STRAP2		(SCU_BASE + 0x510)
#define SCU_HW_STRAP3		(SCU_BASE + 0x51c)
#define SCU_CA7_PARITY_CHK	(SCU_BASE + 0x820)
#define SCU_CA7_PARITY_CLR	(SCU_BASE + 0x824)
#define SCU_MMIO_DEC_SET	(SCU_BASE + 0xc24)

#define FMC_BASE		0x1e620000
#define FMC_CE0_CTRL		(FMC_BASE + 0x010)
#define FMC_SW_RST_CTRL		(FMC_BASE + 0x050)
#define FMC_WDT1_CTRL_MODE	(FMC_BASE + 0x060)
#define FMC_WDT2_CTRL_MODE	(FMC_BASE + 0x064)

#define GPIO_BASE		0x1e780000
#define GPIOYZ_DATA_VALUE	(GPIO_BASE + 0x1e0)

#define SEC_BASE		0x1e6f2000
#define SEC_VAULT_KEY_CTRL	(SEC_BASE + 0x80c)

#define REV_ID_AST2600A0	0x05000303
#define REV_ID_AST2600A1	0x05010303
#define REV_ID_AST2620A1	0x05010203

.macro scu_unlock
	movw	r0, #0xa8a8
	movt	r0, #0x1688	@; magic key to unlock SCU

	ldr	r1, =SCU_PROT_KEY1
	str	r0, [r1]
	ldr	r1, =SCU_PROT_KEY2
	str	r0, [r1]
.endm

.macro timer_init
#ifdef CONFIG_FPGA_ASPEED
	movw	r0, #0x6c00
	movt	r0, #0x02dc
#else
	ldr	r0, =SCU_REV_ID
	ldr	r0, [r0]

	ldr	r1, =REV_ID_AST2600A0
	cmp	r0, r1

	beq	timer_init_a0

	ldr	r1, =SCU_HW_STRAP1
	ldr	r1, [r1]
	and	r1, #0x700
	lsr	r1, #0x8

	cmp	r1, #0x0
	movweq	r0, #0x8c00
	movteq	r0, #0x4786

	cmp	r1, #0x1
	movweq	r0, #0x1000
	movteq	r0, #0x5f5e

	cmp	r1, #0x2
	movweq	r0, #0x8c00
	movteq	r0, #0x4786

	cmp	r1, #0x3
	movweq	r0, #0x1000
	movteq	r0, #0x5f5e

	cmp	r1, #0x4
	movwge	r0, #0x0800
	movtge	r0, #0x2faf

	b	timer_init_out

timer_init_a0:
	movweq	r0, #0x32c0
	movteq	r0, #0x4013

timer_init_out:
#endif
	mcr	p15, 0, r0, c14, c0, 0	@; update CNTFRQ
.endm


.globl lowlevel_init

lowlevel_init:
#if defined(CONFIG_SPL) && !defined(CONFIG_SPL_BUILD)
	mov	pc, lr
#else
	/* setup ARM arch timer frequency */
	timer_init

	/* reset SMP mailbox as early as possible */
	mov	r0, #0x0
	ldr	r1, =SCU_SMP_READY
	str	r0, [r1]

	/* set ACTLR.SMP to enable cache use */
	mrc	p15, 0, r0, c1, c0, 1
	orr	r0, #0x40
	mcr	p15, 0, r0, c1, c0, 1

	/*
	 * we treat cpu0 as the primary core and
	 * put secondary core (cpuN) to sleep
	 */
	mrc   p15, 0, r0, c0, c0, 5	@; Read CPU ID register
	ands  r0, #0xff			@; Mask off, leaving the CPU ID field
	movw  r4, #0xab00
	movt  r4, #0xabba
	orr   r4, r0

	beq   do_primary_core_setup

	/* hold cpuN until SMP mailbox is ready */
poll_smp_mbox_ready:
	wfe
	ldr	r0, =SCU_SMP_READY
	ldr	r0, [r0]
	movw	r1, #0xcafe
	movt	r1, #0xbabe
	cmp	r1, r0
	bne	poll_smp_mbox_ready

	/*
	 * for relocated SMP mailbox insn. use
	 *  r4 = per-cpu go sign value
	 *  r5 = SCU_SMP_GO
	 *  r6 = SCU_SMP_NS_EP
	 *  r7 = SCU_SMP_S_EP
	 */
	ldr	r5, =SCU_SMP_GO
	ldr	r6, =SCU_SMP_NS_EP
	ldr	r7, =SCU_SMP_S_EP

	/* no return */
	ldr	pc, =SCU_SMP_POLLINSN

do_primary_core_setup:
	/* unlock system control unit */
	scu_unlock

	/* identify AST2600 A0/A1 */
	ldr	r0, =SCU_REV_ID
	ldr	r0, [r0]

	ldr	r1, =REV_ID_AST2600A0
	cmp	r0, r1

	bne	0f

	/* tune up CPU clocks (A0 only) */
	ldr	r0, =SCU_HW_STRAP1
	ldr	r1, [r0]
	bic	r1, #0x1800
	orr	r1, #0x1000
	str	r1, [r0]

	ldr	r0, =SCU_HPLL_PARAM
	movw	r1, #0x4080
	movt	r1, #0x1000
	str	r1, [r0]

	ldr	r0, =SCU_HPLL_PARAM_EXT
	mov	r1, #0x47
	str	r1, [r0]

wait_lock:
	ldr	r1, [r0]
	tst	r1, #0x80000000
	beq	wait_lock

	/* skip A1 only area */
	b 2f

0:
	/* identify AST2600/AST2620 A1 */
	ldr	r0, =SCU_REV_ID
	ldr	r0, [r0]

	ldr	r1, =REV_ID_AST2600A1
	cmp	r0, r1
	beq	1f

	ldr	r1, =REV_ID_AST2620A1
	cmp	r0, r1
	bne	2f

1:
	/* LPC/eSPI mode selection by SW (AST2600/AST2620 A1 only) */
	ldr	r0, =GPIOYZ_DATA_VALUE
	ldr	r0, [r0]
	tst	r0, #0x1000
	beq	2f

	/* switch to LPC mode if GPIOZ[4]=1 */
	ldr	r0, =SCU_HW_STRAP2
	ldr	r1, [r0]
	orr	r1, #0x40
	str	r1, [r0]

2:
	/* Enable Vault Key Write Protection */
	mov	r0, #0x2
	ldr	r1, =SEC_VAULT_KEY_CTRL
	str	r0, [r1]

	/* PCIeRC/E2M8 power-on reset comes from SCU040
	It need set SCU040[18] high to reset PCIeRC/E2M
	when AC power-on */
	ldr	r0,  =SCU_SYSRST_EVENT
	ldr	r1, [r0]
	tst	r1, #0x1
	beq	3f
	ldr     r0, =SCU_SYSRST_CTRL
	movw    r1, #0x0000
	movt    r1, #0x0004
	str     r1, [r0]
3:
	/* Fix UART1 route problem on A3 */
	ldr     r0, =0x1e789098
	movw    r1, #0x0a30
	movt    r1, #0x0000
	str     r1, [r0]

	ldr     r0, =0x1e78909c
	movw    r1, #0x0000
	movt    r1, #0x0000
	str     r1, [r0]

	/* MMIO decode setting */
	ldr	r0, =SCU_MMIO_DEC_SET
	mov	r1, #0x2000
	str	r1, [r0]

	/* enable cache & SRAM parity check */
	mov	r0, #0
	ldr	r1, =SCU_CA7_PARITY_CLR
	str	r0, [r1]

	mov	r0, #0x1
	ldr	r1, =SCU_CA7_PARITY_CHK
	str	r0, [r1]

	/* Select USB2.0 Device mode as USB port B */
	ldr	r0, =0x10000000
	ldr	r1, =SCU_USB_MULTI_FUNC
	str	r0, [r1]

	/* enable USB port B PHY clk */
	mov	r0, #0x80
	ldr	r1, =SCU_CLK_STOP_CTRL_CLR
	str	r0, [r1]

#if 0
	ldr	r1, =FMC_WDT2_CTRL_MODE
	str	r0, [r1]
#endif

	/* do not fill FMC50[1] if boot from eMMC */
	ldr	r0, =SCU_HW_STRAP1
	ldr	r1, [r0]
	ands	r1, #0x04
	bne	skip_fill_wip_bit

	/* fill FMC50[1] for waiting WIP idle */
	mov	r0, #0x02
	ldr	r1, =FMC_SW_RST_CTRL
	str	r0, [r1]
skip_fill_wip_bit:

#if !defined(CONFIG_ASPEED_DEFAULT_SPI_FREQUENCY)
	/* tune up SPI clock */
	movw	r0, #0x0600
	movt	r0, #0x0000
	ldr	r1, =FMC_CE0_CTRL
	str	r0, [r1]
#endif

	/* disable FMC WDT for SPI address mode detection */
	mov	r0, #0
	ldr	r1, =FMC_WDT1_CTRL_MODE
	str	r0, [r1]

	/* disable backdoor for A1/A2 to align A3 design */
	ldr	r0, =SCU_HW_STRAP3
	ldr	r0, [r0]
	tst	r0, #0x1

	ldr	r0, =SCU_DEBUG_CTRL
	movwne	r1, #0x0ffd
	movweq	r1, #0x0fff
	movt	r1, #0x0000
	str	r1, [r0]

	ldr	r0, =SCU_DEBUG_CTRL2
	movne	r1, #0xf7
	moveq	r1, #0xff
	str	r1, [r0]

relocate_smp_mbox_start:
	/* relocate SMP mailbox insn. for cpuN to poll for go signal */
	adrl	r0, smp_mbox_insn
	adrl	r1, smp_mbox_insn_end
	ldr	r2, =SCU_SMP_POLLINSN

relocate_smp_mbox_insn:
	ldr	r3, [r0], #0x4
	str	r3, [r2], #0x4
	cmp	r0, r1
	bne	relocate_smp_mbox_insn

	/* reset SMP go sign and entrypoints */
	mov	r0, #0
	ldr	r1, =SCU_SMP_GO
	str	r0, [r1]
	ldr	r1, =SCU_SMP_NS_EP
	str	r0, [r1]
	ldr	r1, =SCU_SMP_S_EP
	str	r0, [r1]

	/* notify cpuN mailbox is ready */
	movw	r0, #0xcafe
	movt	r0, #0xbabe
	ldr	r1, =SCU_SMP_READY
	str	r0, [r1]
	sev

	/* back to arch calling code */
	mov	pc, lr

/*
 * insn. inside mailbox to poll SMP go signal.
 *
 * Note that as this code will be relocated, any
 * pc-relative assembly should NOT be used.
 */
smp_mbox_insn:
	/*
	 *  r4 = per-cpu go sign value
	 *  r5 = SCU_SMP_GO
	 *  r6 = SCU_SMP_NS_EP
	 *  r7 = SCU_SMP_S_EP
	 */
poll_smp_mbox_go:
	wfe
	ldr	r0, [r5]
	cmp	r0, r4
	bne	poll_smp_mbox_go

	/* go to secure world if secure entrypoint is specified */
	ldr	r3, [r7]
	cmp	r3, #0
	beq	1f

	ldr	lr, [r6]
	mov	pc, r3
1:
	ldr	pc, [r6]

smp_mbox_insn_end:
	/* should never reach */
	b	.

#endif
