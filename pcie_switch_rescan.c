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
