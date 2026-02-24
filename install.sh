#!/bin/sh
#
# install.sh — Build and install the pcie_switch_rescan kernel module
#
# Fixes the PCIe enumeration race condition on RK3588 boards with
# PCIe switches (ASMedia ASM2806, etc). The DWC PCIe controller
# enumerates the bus before the switch's downstream ports finish
# link training, leaving endpoints unreachable.
#
# This module rescans the bus after a delay, programs bridge memory
# windows into hardware config space, and triggers driver probes
# with working bridges.
#
# Tested on: Rock 5C + Radxa Dual 2.5G Router HAT (ASM2806 switch)
# Kernel:    Armbian 6.18.x (rockchip64)
# OS:        Alpine Linux 3.21
#
# Usage: ./install.sh [--uninstall]
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

MODULE_NAME="pcie_switch_rescan"
KVER=$(uname -r)
KDIR="/usr/src/linux-headers-${KVER}"
MODDIR="/lib/modules/${KVER}/extra"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Uninstall ────────────────────────────────────────────────────────
if [ "$1" = "--uninstall" ]; then
    info "Uninstalling ${MODULE_NAME}..."
    rmmod ${MODULE_NAME} 2>/dev/null && info "Module unloaded" || true
    rm -f "${MODDIR}/${MODULE_NAME}.ko"
    rm -f /etc/modules-load.d/pcie-switch-rescan.conf
    rm -f /etc/modprobe.d/pcie-switch-rescan.conf
    sed -i '/^r8169$/d' /etc/modules 2>/dev/null || true
    sed -i '/^nvme$/d' /etc/modules 2>/dev/null || true
    depmod -a
    info "Uninstalled. Reboot to take effect."
    exit 0
fi

# ─── Prerequisites ────────────────────────────────────────────────────
info "Checking prerequisites..."

[ "$(id -u)" -eq 0 ] || error "Must run as root"

command -v gcc >/dev/null 2>&1 || error "gcc not found. Install with: apk add gcc"
command -v make >/dev/null 2>&1 || error "make not found. Install with: apk add make"
command -v ld >/dev/null 2>&1 || error "ld not found. Install with: apk add binutils"

[ -d "${KDIR}" ] || error "Kernel headers not found at ${KDIR}"
[ -f "${KDIR}/include/linux/module.h" ] || error "Kernel headers incomplete — missing module.h"

# ─── Detect PCIe switch ──────────────────────────────────────────────
info "Detecting PCIe switch..."

SWITCH_BDF=$(lspci -Dn 2>/dev/null | grep -E "0604:.*(1b21:2806|1b21:2812|1b21:1182)" | head -1 | awk '{print $1}')

if [ -z "${SWITCH_BDF}" ]; then
    warn "No ASMedia PCIe switch detected via lspci."
    warn "Using default parameters (domain=4, bus=0x40)."
    DOMAIN=4
    BUS_NR=0x40
else
    info "Found PCIe switch at ${SWITCH_BDF}"
    DOMAIN=$(echo "${SWITCH_BDF}" | cut -d: -f1)
    SWITCH_BUS=$(echo "${SWITCH_BDF}" | cut -d: -f2)
    ROOT_BUS_DEC=$(printf "%d" "0x${SWITCH_BUS}")
    ROOT_BUS_DEC=$((ROOT_BUS_DEC - 1))
    BUS_NR=$(printf "0x%02x" ${ROOT_BUS_DEC})
    info "Root port: domain=${DOMAIN}, bus=${BUS_NR}"
fi

# ─── Fix kernel headers if needed ────────────────────────────────────
info "Checking kernel headers version..."

UTSRELEASE="${KDIR}/include/generated/utsrelease.h"
if [ -f "${UTSRELEASE}" ]; then
    HEADER_VER=$(grep UTS_RELEASE "${UTSRELEASE}" | sed 's/.*"\(.*\)".*/\1/')
    if [ "${HEADER_VER}" != "${KVER}" ]; then
        warn "Headers say '${HEADER_VER}' but kernel is '${KVER}'"
        info "Patching utsrelease.h..."
        cp "${UTSRELEASE}" "${UTSRELEASE}.bak"
        sed -i "s|\"${HEADER_VER}\"|\"${KVER}\"|" "${UTSRELEASE}"
        info "Patched to '${KVER}'"
    fi
fi

# ─── Write module source ─────────────────────────────────────────────
info "Writing module source..."

cat > "${SRCDIR}/${MODULE_NAME}.c" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * PCIe Switch Deferred Rescan
 *
 * On the RK3588's DWC PCIe controller, the kernel enumerates the bus
 * before a PCIe switch's downstream ports finish link training. This
 * module rescans the bus after a delay, then programs the bridge memory
 * windows into hardware config space before triggering driver probes.
 *
 * The key insight: pci_rescan_bus() bundles scan + resource assignment +
 * driver probing into one call. But the resource assignment only updates
 * kernel data structures — it does NOT write bridge MEMORY_BASE/LIMIT
 * registers to hardware. By decomposing into separate steps, we insert
 * bridge programming between assignment and driver probing, so drivers
 * find working bridges on their first probe attempt.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/delay.h>
#include <linux/workqueue.h>

static unsigned int rescan_delay_ms = 3000;
module_param(rescan_delay_ms, uint, 0644);
MODULE_PARM_DESC(rescan_delay_ms,
	"Delay in ms before rescanning bus (default: 3000)");

static unsigned int domain = 4;
module_param(domain, uint, 0644);
MODULE_PARM_DESC(domain, "PCI domain to rescan (default: 4)");

static unsigned int bus_nr = 0x40;
module_param(bus_nr, uint, 0644);
MODULE_PARM_DESC(bus_nr, "Root bus number to rescan (default: 0x40)");

static struct delayed_work rescan_work;

/*
 * Write bridge memory windows and enable memory space decoding.
 * pci_assign_unassigned_bus_resources() assigns windows in kernel
 * resource structs but does NOT write MEMORY_BASE/LIMIT to hardware
 * config space. Also enables PCI_COMMAND_MEMORY on all bridges so
 * they forward memory transactions to downstream devices.
 */
static void program_bridge_windows(struct pci_bus *bus)
{
	struct pci_dev *dev;

	list_for_each_entry(dev, &bus->devices, bus_list) {
		struct resource *res;
		u16 cmd;

		if (!dev->subordinate)
			continue;

		/* Program memory window from kernel resource */
		res = &dev->resource[PCI_BRIDGE_MEM_WINDOW];
		if (resource_size(res) > 0) {
			u16 mem_base = (res->start >> 16) & 0xfff0;
			u16 mem_limit = (res->end >> 16) & 0xfff0;
			pci_write_config_word(dev, PCI_MEMORY_BASE, mem_base);
			pci_write_config_word(dev, PCI_MEMORY_LIMIT, mem_limit);
			dev_info(&dev->dev,
				 "bridge mem window %pR\n", res);
		}

		/* Program I/O window */
		res = &dev->resource[PCI_BRIDGE_IO_WINDOW];
		if (resource_size(res) > 0) {
			u8 io_base = (res->start >> 8) & 0xf0;
			u8 io_limit = (res->end >> 8) & 0xf0;
			pci_write_config_byte(dev, PCI_IO_BASE, io_base);
			pci_write_config_byte(dev, PCI_IO_LIMIT, io_limit);
		}

		/* Enable bus mastering + memory space decoding */
		pci_read_config_word(dev, PCI_COMMAND, &cmd);
		cmd |= PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER;
		pci_write_config_word(dev, PCI_COMMAND, cmd);

		/* Recurse into child buses */
		program_bridge_windows(dev->subordinate);
	}
}

static void pcie_do_rescan(struct work_struct *work)
{
	struct pci_bus *root_bus;

	root_bus = pci_find_bus(domain, bus_nr);
	if (!root_bus) {
		pr_err("pcie-switch-rescan: bus %04x:%02x not found\n",
		       domain, bus_nr);
		return;
	}

	pr_info("pcie-switch-rescan: rescanning bus %04x:%02x\n",
		domain, bus_nr);

	pci_lock_rescan_remove();

	/* Step 1: Scan the bus hierarchy to discover new devices */
	pci_scan_child_bus(root_bus);

	/* Step 2: Assign BARs and bridge windows in kernel resource structs */
	pci_assign_unassigned_bus_resources(root_bus);

	/* Step 3: Write bridge windows to hardware config space and
	 *         enable memory space decoding on all bridges */
	program_bridge_windows(root_bus);

	/* Step 4: Add devices to driver model — triggers driver probes.
	 *         Now bridges are correctly configured so MMIO works. */
	pci_bus_add_devices(root_bus);

	pci_unlock_rescan_remove();

	pr_info("pcie-switch-rescan: rescan complete, bridges programmed\n");
}

static int __init pcie_switch_rescan_init(void)
{
	pr_info("pcie-switch-rescan: scheduling rescan in %ums\n",
		rescan_delay_ms);

	INIT_DELAYED_WORK(&rescan_work, pcie_do_rescan);
	schedule_delayed_work(&rescan_work, msecs_to_jiffies(rescan_delay_ms));

	return 0;
}

static void __exit pcie_switch_rescan_exit(void)
{
	cancel_delayed_work_sync(&rescan_work);
	pr_info("pcie-switch-rescan: unloaded\n");
}

module_init(pcie_switch_rescan_init);
module_exit(pcie_switch_rescan_exit);

MODULE_AUTHOR("Scott Ullrich");
MODULE_DESCRIPTION("Deferred PCIe bus rescan with bridge window programming");
MODULE_LICENSE("GPL");
CEOF

# ─── Write module linkage file ───────────────────────────────────────
cat > "${SRCDIR}/${MODULE_NAME}.mod.c" << 'MODCEOF'
#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/export-internal.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

#ifdef CONFIG_UNWINDER_ORC
#include <asm/orc_header.h>
ORC_HEADER;
#endif

BUILD_SALT;
BUILD_LTO_INFO;

MODULE_INFO(vermagic, VERMAGIC_STRING);

struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

MODULE_INFO(srcversion, "0");
MODCEOF

# ─── Write Makefile ───────────────────────────────────────────────────
cat > "${SRCDIR}/Makefile" << MKEOF
obj-m += ${MODULE_NAME}.o

KDIR := ${KDIR}

all:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) modules

clean:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean
MKEOF

# ─── Build ────────────────────────────────────────────────────────────
info "Building kernel module..."

cd "${SRCDIR}"

# Clean any previous build
rm -f ${MODULE_NAME}.o ${MODULE_NAME}.mod.o ${MODULE_NAME}.ko .${MODULE_NAME}*.d

# Step 1: Build the main .o via kernel build system
make -C "${KDIR}" M="${SRCDIR}" ${MODULE_NAME}.o 2>&1 || error "Failed to compile module"
info "Compiled ${MODULE_NAME}.o"

# Step 2: Build the .mod.o with kernel include paths.
#         Armbian headers often lack modpost, so we compile the
#         linkage file directly with the kernel's include paths.
gcc -Wp,-MMD,./.${MODULE_NAME}.mod.o.d \
    -nostdinc \
    -I${KDIR}/arch/arm64/include \
    -I${KDIR}/arch/arm64/include/generated \
    -I${KDIR}/include \
    -I${KDIR}/arch/arm64/include/uapi \
    -I${KDIR}/arch/arm64/include/generated/uapi \
    -I${KDIR}/include/uapi \
    -I${KDIR}/include/generated/uapi \
    -include ${KDIR}/include/linux/compiler-version.h \
    -include ${KDIR}/include/linux/kconfig.h \
    -include ${KDIR}/include/linux/compiler_types.h \
    -D__KERNEL__ \
    -mlittle-endian \
    -DCC_USING_PATCHABLE_FUNCTION_ENTRY \
    -DKASAN_SHADOW_SCALE_SHIFT= \
    -std=gnu11 \
    -fshort-wchar \
    -funsigned-char \
    -fno-common \
    -fno-PIE \
    -fno-strict-aliasing \
    -mgeneral-regs-only \
    -mabi=lp64 \
    -fno-asynchronous-unwind-tables \
    -fno-unwind-tables \
    -mbranch-protection=pac-ret \
    -fno-delete-null-pointer-checks \
    -O2 \
    -fstack-protector-strong \
    -fno-omit-frame-pointer \
    -fpatchable-function-entry=4,2 \
    -fmin-function-alignment=8 \
    -g \
    -DMODULE \
    -DKBUILD_MODFILE="\"${MODULE_NAME}\"" \
    -DKBUILD_BASENAME="\"${MODULE_NAME}.mod\"" \
    -DKBUILD_MODNAME="\"${MODULE_NAME}\"" \
    -D__KBUILD_MODNAME=kmod_${MODULE_NAME} \
    -c -o ${MODULE_NAME}.mod.o ${MODULE_NAME}.mod.c \
    2>&1 || error "Failed to compile mod linkage"
info "Compiled ${MODULE_NAME}.mod.o"

# Step 3: Link with module.lds for ARM64 PLT sections
if [ -f "${KDIR}/scripts/module.lds" ]; then
    ld -r -T "${KDIR}/scripts/module.lds" \
        -o ${MODULE_NAME}.ko \
        ${MODULE_NAME}.o ${MODULE_NAME}.mod.o \
        2>&1 || error "Failed to link module"
else
    ld -r -o ${MODULE_NAME}.ko \
        ${MODULE_NAME}.o ${MODULE_NAME}.mod.o \
        2>&1 || error "Failed to link module"
fi
info "Linked ${MODULE_NAME}.ko"

# ─── Install ─────────────────────────────────────────────────────────
info "Installing module..."

mkdir -p "${MODDIR}"
cp "${MODULE_NAME}.ko" "${MODDIR}/"
depmod -a
info "Installed to ${MODDIR}/${MODULE_NAME}.ko"

# ─── Configure autoloading ───────────────────────────────────────────
info "Configuring module autoloading..."

mkdir -p /etc/modules-load.d
echo "${MODULE_NAME}" > /etc/modules-load.d/pcie-switch-rescan.conf

cat > /etc/modprobe.d/pcie-switch-rescan.conf << MPEOF
options ${MODULE_NAME} rescan_delay_ms=2000 domain=${DOMAIN} bus_nr=${BUS_NR}
MPEOF

info "Parameters: domain=${DOMAIN} bus_nr=${BUS_NR} rescan_delay_ms=2000"

# Ensure endpoint drivers are loaded before rescan fires
for MOD in r8169 nvme; do
    if ! grep -qx "${MOD}" /etc/modules 2>/dev/null; then
        echo "${MOD}" >> /etc/modules
        info "Added ${MOD} to /etc/modules"
    fi
done

# ─── Clean up old hack artifacts ─────────────────────────────────────
if [ -f /etc/init.d/pcie-hat ]; then
    rc-update del pcie-hat default 2>/dev/null || true
    rm -f /etc/init.d/pcie-hat
    info "Removed old pcie-hat init service"
fi

if [ -f /usr/local/bin/fix-pcie-hat.sh ]; then
    rm -f /usr/local/bin/fix-pcie-hat.sh
    info "Removed old fix-pcie-hat.sh script"
fi

# ─── Verify ──────────────────────────────────────────────────────────
info "Verifying module loads..."

rmmod ${MODULE_NAME} 2>/dev/null || true
if modprobe ${MODULE_NAME} 2>&1; then
    info "Module loaded successfully"
    dmesg | grep "pcie-switch-rescan" | tail -3
else
    error "Module failed to load"
fi

echo ""
info "Installation complete."
info "Reboot to activate: reboot"
echo ""
echo "After reboot, verify with:"
echo "  dmesg | grep pcie-switch-rescan"
echo "  ip link show eth0"
echo "  ip link show eth1"
echo "  ls /dev/nvme*"
