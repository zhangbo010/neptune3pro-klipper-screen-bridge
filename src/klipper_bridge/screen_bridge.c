// STM32 USART6 serial screen bridge
//
// Byte pipe between USART6 (PA12/PA11) and the Klipper host protocol.
// This file must NOT call serial_rx_byte() / serial_get_tx_byte() —
// those belong to the host UART (USART2 on this board).
//
// Overflow / UART errors only drop bytes and increment counters.
// They must never call shutdown().
//
// This file may be distributed under the terms of the GNU GPLv3 license.

#include "autoconf.h" // CONFIG_STM32_SCREEN_BRIDGE_BAUD
#include "board/armcm_boot.h" // armcm_enable_irq
#include "board/io.h" // readl, writel
#include "board/irq.h" // irq_save
#include "command.h" // DECL_COMMAND, sendf
#include "compiler.h" // DIV_ROUND_CLOSEST
#include "internal.h" // enable_pclock, gpio_peripheral
#include "sched.h" // DECL_INIT

DECL_CONSTANT_STR("RESERVE_PINS_screen_bridge", "PA12,PA11");
DECL_CONSTANT("SCREEN_BRIDGE_BAUD", CONFIG_STM32_SCREEN_BRIDGE_BAUD);

#define GPIO_Rx GPIO('A', 12)
#define GPIO_Tx GPIO('A', 11)
#define GPIO_AF_MODE 8

// Power-of-two sizes so index wrapping can use a mask.
#define RX_SIZE 2048
#define TX_SIZE 4096
#define RX_MASK (RX_SIZE - 1)
#define TX_MASK (TX_SIZE - 1)

// Klipper frames are MESSAGE_MAX (64) bytes including header/trailer.
// One %*s payload therefore has to stay well under 64; 48 is safe.
#define BRIDGE_MSG_MAX 48

#define CR1_FLAGS (USART_CR1_UE | USART_CR1_RE | USART_CR1_TE \
                   | USART_CR1_RXNEIE)

// IRQ writer / task reader for RX; task writer / IRQ reader for TX.
static uint8_t rx_buf[RX_SIZE];
static uint32_t rx_head, rx_tail;
static uint8_t tx_buf[TX_SIZE];
static uint32_t tx_head, tx_tail;
static uint32_t rx_dropped, tx_dropped;

static void
bridge_set_baud(uint32_t baud)
{
    uint32_t pclk = get_pclock_frequency((uint32_t)USART6);
    uint32_t div = DIV_ROUND_CLOSEST(pclk, baud);
    USART6->BRR = (((div / 16) << USART_BRR_DIV_Mantissa_Pos)
                   | ((div % 16) << USART_BRR_DIV_Fraction_Pos));
}

static void
bridge_enable_tx_irq(void)
{
    USART6->CR1 = CR1_FLAGS | USART_CR1_TXEIE;
}

static void
rx_push_byte(uint8_t data)
{
    uint32_t head = rx_head;
    uint32_t tail = rx_tail;
    if (head - tail >= RX_SIZE) {
        // Drop oldest. IRQ is the only writer of rx_head; on overflow
        // it also advances rx_tail. Reset is the only other mutator
        // and runs with IRQs disabled.
        rx_tail = tail + 1;
        rx_dropped++;
    }
    rx_buf[head & RX_MASK] = data;
    rx_head = head + 1;
}

void
USART6_IRQHandler(void)
{
    uint32_t sr = USART6->SR;
    if (sr & (USART_SR_RXNE | USART_SR_ORE | USART_SR_FE | USART_SR_NE)) {
        // Reading SR then DR clears RXNE/ORE/FE/NE. Never shutdown.
        uint8_t data = USART6->DR;
        if (sr & USART_SR_ORE)
            rx_dropped++;
        if (sr & (USART_SR_RXNE | USART_SR_ORE))
            rx_push_byte(data);
    }
    if ((sr & USART_SR_TXE) && (USART6->CR1 & USART_CR1_TXEIE)) {
        uint32_t tail = tx_tail;
        if (tail == tx_head) {
            USART6->CR1 = CR1_FLAGS;
        } else {
            USART6->DR = tx_buf[tail & TX_MASK];
            tx_tail = tail + 1;
        }
    }
}

void
command_bridge_config(uint32_t *args)
{
    uint32_t baud = args[0];
    if (baud < 1200 || baud > 4500000)
        return;
    irqstatus_t flag = irq_save();
    USART6->CR1 = 0;
    bridge_set_baud(baud);
    USART6->CR1 = CR1_FLAGS;
    irq_restore(flag);
}
DECL_COMMAND(command_bridge_config, "bridge_config baud=%u");

void
command_bridge_tx(uint32_t *args)
{
    uint32_t len = args[0];
    uint8_t *data = command_decode_ptr(args[1]);
    uint32_t head = readl(&tx_head);
    uint32_t tail = readl(&tx_tail);
    uint32_t used = head - tail;
    uint32_t space = TX_SIZE - used;
    if (len > space) {
        tx_dropped += len;
        return;
    }
    for (uint32_t i = 0; i < len; i++)
        tx_buf[(head + i) & TX_MASK] = data[i];
    writel(&tx_head, head + len);
    if (len)
        bridge_enable_tx_irq();
}
DECL_COMMAND(command_bridge_tx, "bridge_tx data=%*s");

void
command_bridge_rx(uint32_t *args)
{
    uint32_t max = args[0];
    uint8_t buf[BRIDGE_MSG_MAX];
    if (max > BRIDGE_MSG_MAX)
        max = BRIDGE_MSG_MAX;
    uint32_t tail = readl(&rx_tail);
    uint32_t head = readl(&rx_head);
    uint32_t avail = head - tail;
    if (avail > max)
        avail = max;
    for (uint32_t i = 0; i < avail; i++)
        buf[i] = rx_buf[(tail + i) & RX_MASK];
    // The RX IRQ may advance rx_tail on overflow, so update it atomically.
    irqstatus_t flag = irq_save();
    writel(&rx_tail, tail + avail);
    irq_restore(flag);
    sendf("bridge_data data=%*s", (int)avail, buf);
}
DECL_COMMAND(command_bridge_rx, "bridge_rx max=%c");

void
command_bridge_reset(uint32_t *args)
{
    (void)args;
    irqstatus_t flag = irq_save();
    rx_head = rx_tail = 0;
    tx_head = tx_tail = 0;
    rx_dropped = tx_dropped = 0;
    USART6->CR1 = CR1_FLAGS;
    irq_restore(flag);
}
DECL_COMMAND(command_bridge_reset, "bridge_reset");

void
command_bridge_get_stats(uint32_t *args)
{
    (void)args;
    sendf("bridge_stats rx_dropped=%u tx_dropped=%u", rx_dropped, tx_dropped);
}
DECL_COMMAND(command_bridge_get_stats, "bridge_get_stats");

void
bridge_init(void)
{
    enable_pclock((uint32_t)USART6);
    bridge_set_baud(CONFIG_STM32_SCREEN_BRIDGE_BAUD);
    USART6->CR1 = CR1_FLAGS;
    // Priority 3: host USART is 0, USB is 1, SysTick stepping is 2.
    // Larger number = lower priority, so this cannot preempt stepping.
    armcm_enable_irq(USART6_IRQHandler, USART6_IRQn, 3);
    gpio_peripheral(GPIO_Rx, GPIO_FUNCTION(GPIO_AF_MODE), 1);
    gpio_peripheral(GPIO_Tx, GPIO_FUNCTION(GPIO_AF_MODE), 0);
}
DECL_INIT(bridge_init);
