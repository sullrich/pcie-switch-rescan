# Fix Missing NICs and NVMe on RK3588 + PCIe Switch HATs

A kernel module that fixes PCIe device detection on RK3588 boards using PCIe switches like the ASMedia ASM2806.

If you're running a Radxa Dual 2.5G Router HAT (or similar PCIe switch HAT) on a Rock 5C, Rock 5B, or other RK3588-based board and your NICs or NVMe drive aren't showing up at boot — this is probably what you need.

## The Problem

The RK3588's DesignWare PCIe controller enumerates the bus as soon as the upstream link to the switch comes up. But the switch's downstream ports haven't finished training their links to the actual endpoints (NICs, NVMe, etc.) yet. By the time those links are ready, the kernel has already moved on. The bus scan found the switch but nothing behind it.

A rescan can discover the missing devices, but there's a second problem buried in the kernel's PCI subsystem: `pci_rescan_bus()` assigns bridge memory windows and endpoint BARs in its internal data structures, but never writes the bridge `MEMORY_BASE` / `MEMORY_LIMIT` registers to hardware config space. It also doesn't enable memory space decoding on upstream bridges. So even after a rescan, the bridges don't actually forward memory transactions, and every driver probe fails with `-EIO`.

## How This Module Fixes It

Instead of calling `pci_rescan_bus()` as a single operation, the module breaks it into its four constituent steps:

1. **Scan** the bus hierarchy to discover new devices (`pci_scan_child_bus`)
2. **Assign** BARs and bridge windows in kernel resource structures (`pci_assign_unassigned_bus_resources`)
3. **Program** the bridge memory windows into actual hardware config space registers and enable memory space decoding on all bridges
4. **Add** the devices to the driver model, which triggers driver probes (`pci_bus_add_devices`)

The key difference: bridge windows are written to hardware *before* drivers try to access their devices. Drivers probe once and succeed on the first attempt.

The module schedules this work via a delayed workqueue (default 2 seconds after module load) to give the switch downstream ports time to finish link training.

## What This Was Tested On

- Rock 5C (RK3588S) running Alpine Linux 3.21 with Armbian kernel 6.18.8
- Radxa Dual 2.5G Router HAT (ASM2806 PCIe switch, 2x RTL8125B 2.5GbE, 1x M.2 NVMe slot)
- Should work on other RK3588 boards (Rock 5B, Orange Pi 5, etc.) with PCIe switches

## Installation

Clone this repo onto the board and run the install script:

```
git clone https://github.com/sullrich/pcie-switch-rescan.git
cd pcie-switch-rescan
./install.sh
reboot
```

The install script handles everything:

- Detects the PCIe switch and figures out the domain/bus parameters
- Patches the kernel headers if the version string doesn't match (common Armbian issue)
- Builds the module (works around Armbian's incomplete headers that lack `modpost`)
- Installs the module and configures it to load at boot
- Adds `r8169` and `nvme` to `/etc/modules` (Alpine uses `mdev` which doesn't autoload PCI drivers)
- Cleans up any old workaround scripts

### Prerequisites

You'll need `gcc`, `make`, `binutils`, and the kernel headers package:

```
apk add gcc make binutils linux-headers
```

On Armbian, the kernel headers package is usually `linux-headers-current-rockchip64` or similar.

### Uninstall

```
./install.sh --uninstall
reboot
```

## Verifying It Works

After rebooting, check that everything came up:

```
dmesg | grep pcie-switch-rescan
ip link show eth0
ip link show eth1
ls /dev/nvme*
```

You should see something like:

```
[  5.6] pcie-switch-rescan: scheduling rescan in 2000ms
[  7.6] pcie-switch-rescan: rescanning bus 0004:40
[  7.7] r8169 0004:45:00.0 eth0: RTL8125B, ...
[  7.8] r8169 0004:46:00.0 eth1: RTL8125B, ...
[  7.8] pcie-switch-rescan: rescan complete, bridges programmed
[  7.9] nvme nvme0: 8/0/0 default/read/poll queues
```

## Module Parameters

The module auto-detects the right values during install, but you can override them in `/etc/modprobe.d/pcie-switch-rescan.conf`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `rescan_delay_ms` | 2000 | How long to wait (ms) after module load before rescanning. Increase if devices still aren't found. |
| `domain` | 4 | PCI domain of the root port. |
| `bus_nr` | 0x40 | Root bus number to rescan. |

## Technical Details

The RK3588 has multiple PCIe controllers. The one typically used with HATs like the Radxa Router HAT is `pcie2x1l2` at `pcie@fe190000`, which shows up as PCI domain `0004`. The device tree assigns it bus range `0x40-0x4f`.

The DWC (DesignWare) PCIe controller's probe path in `pcie-dw-rockchip.c` calls `rockchip_pcie_start_link()`, waits for the upstream link (up to 900ms), then immediately calls `pci_host_probe()` which enumerates everything. There's no mechanism to wait for downstream switch ports to finish training.

This is arguably a kernel bug — `pci_rescan_bus()` should write bridge windows to hardware, not just track them internally. But since `CONFIG_PCIE_ROCKCHIP_DW=y` (built-in, not a module), we can't patch the driver without rebuilding the entire kernel. This module is a targeted fix that works with stock Armbian kernels.

## Performance

Benchmarks from a Rock 5C with the Radxa Dual 2.5G Router HAT. The NVMe drive is a TEAMGROUP TM8FP6512G (512GB, DRAM-less) connected through the ASM2806 switch at PCIe Gen3 x1 (the switch only provides a single lane per downstream port). All tests run with fio using the libaio engine and direct I/O.

### NVMe (via PCIe switch, Gen3 x1)

| Test | Result |
|------|--------|
| Sequential read (1M, QD32) | 203 MB/s |
| Sequential write (1M, QD32) | 198 MB/s |
| Random 4K read (QD32) | 50,400 IOPS (197 MB/s) |
| Random 4K write (QD32) | 38,300 IOPS (150 MB/s) |
| Random 4K read (QD1, latency) | 8,283 IOPS, 115 us avg |
| Mixed random 4K 70/30 (QD32) | 40.2K read + 17.3K write IOPS |

The sequential numbers are capped by the Gen3 x1 link (~985 MB/s theoretical, ~200 MB/s practical with switch overhead). The random 4K numbers are solid for a DRAM-less drive behind a PCIe switch — comparable to what you'd see from this drive on a direct connection.

## Authorship

This module was developed by Claude (Anthropic) with direction and testing by Scott Ullrich. The root cause analysis, kernel debugging, and iterative fix development were done collaboratively in a single session — Scott provided the hardware and steered the investigation, Claude wrote the code and dug through PCI subsystem internals.

## License

GPL-2.0 — same as the Linux kernel.
