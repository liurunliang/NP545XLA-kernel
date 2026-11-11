# NP545XLA standard external power status

## Scope

This first stage adds a **reporting bridge**, not a BQ25710 hardware driver or a
replacement charging policy. `np545-battery` remains the SBS battery device.
`np545-usb-c` describes the validated IC10 input and charger settings. The existing
`np545-gpiocharge.service` remains the sole charging controller. This does not add
adapter profiles, IC19 charging, sleep support, or new charging limits.

The bridge owns no I2C client, GPIO, PD mailbox, or charger register. The reporter
uses the already reviewed observer's register-selector-only reads and the current
controller's trusted journal events. In particular it **does not read BQ register
0x20**, whose read-to-clear fault bits belong to the controller, or send the PD
switch query command. Binding a new I2C driver at 0x09 would break the controller's
non-forced `I2C_SLAVE` access, so it is deliberately outside this stage.

## Standard properties

| Object / attribute | Source and meaning |
| --- | --- |
| `np545-battery/{status,capacity,voltage_now,current_now,...}` | Existing SBS driver; battery measurements remain unchanged |
| `np545-usb-c/type` | `USB` (UPower external power device) |
| `online` | Recent controller input-path proof, cross-checked with a stable current IC10 sink contract; 0 for a positively observed detached port |
| `usb_type` | `PD` with a validated live contract; `Unknown` while positively detached |
| `voltage_max`, `current_max` | Current fixed PD contract's voltage/current budget in µV/µA; **not measured VBUS/IBUS**, nor every advertised PDO |
| `input_current_limit` | Verified BQ input limit, 3,000,000 µA |
| `constant_charge_current` | BQ programmed battery charge current, e.g. 0 or 1,024,000 µA; not measured battery current |
| `constant_charge_voltage` | BQ programmed voltage ceiling in µV |

All properties are read-only. Unknown optional values return `ENODATA`. There is no
invented `voltage_now`, `current_now`, charger `health`, or duplicate battery.
Standard meanings and units follow the [kernel power_supply documentation](https://docs.kernel.org/power/power_supply_class.html).

## Evidence and freshness

The current supported runtime is battery-ro 7.0.0-5 and gpiocharge 7.0.0-6, with
the seven installed Python producers pinned by SHA-256 in the reporter. An upgrade
requires reviewing the producer contract and updating this adapter; an unknown
version fails closed rather than interpreting an unreviewed log.

The reporter samples every five seconds. Only root journal records from the
current boot, service and active invocation are accepted. The latest event must
be a successful `full-sample` (30-second controller interval) or `refresh`
(45-second interval), at most 65 seconds old. Their code paths have already checked
the input path. Producer boottime, including the trace's nanosecond format, is used
instead of journal arrival time. A subsequent transition, stop, error, or unknown
event revokes this proof. A contract by itself never establishes `online=1`.

The PD state is read twice around acquisition; changing state, unfamiliar targets,
lost controller, negative read result, changed sources, or a collection longer
than three seconds publishes unknown. A NACK is **not** evidence of physical
detach. In unknown state the external power object is removed, rather than
publishing a false offline or retaining a stale online reading. Desktop battery
telemetry remains available independently. This interface reports bounded cached
input-path evidence; it cannot replace a hardware IRQ-based driver's instantaneous
knowledge if an input switch changes without a PD transition.

The root-only `/dev/np545-power-supply` accepts one reporter. ABI v1 consists of
40 little-endian bytes: version, validity mask, CLOCK_BOOTTIME nanoseconds, online,
and five µV/µA properties (see `np545_power_supply.h`). Length, version, field ranges,
validity, timestamp and replay are checked. Closing the writer removes the supply;
a stalled reporter expires after 20 seconds. BOOTTIME includes suspend. Removal
and re-registration generate standard power_supply/udev events. Heartbeats with
unchanged properties do not generate repeated change events. This mechanism
does not alter the machine's existing sleep masks or wake configuration.

## Build and offline validation

On the ARM64 builder with the matching 7.0.0 kernel object tree:

```sh
bash src/build-debian-power-supply.sh /var/tmp/np545xla-diag/obj /var/tmp/power-artifacts
python3 src/test-power-supply.py
gcc -static -Wall -Wextra -Werror -O2 src/debian-battery/power_supply_abi_test.c -o /var/tmp/power-artifacts/abi-test
```

The build runs `W=1`, checks that no I2C/GPIO/regmap/Type-C control symbols are
imported, and creates only `np545xla-power-supply_7.0.0-1_arm64.deb`. It never rebuilds
or installs the charging/sleep candidate packages. Installation does not start or
enable the reporter automatically.

`src/test-power-supply-qemu.py` boots the actual module and static ABI client in an
isolated ARM64 guest. Pass `--image`, `--busybox`, `--module`, `--client`, and a new
`--output` directory (macOS HVF). The client is **synthetic QEMU-only**: never run it
on the Samsung. It checks the board guard, permissions, single writer, invalid and
replayed frames, property values/units, offline/unknown, close/reopen, expiration,
and unload. `test_mode=1` bypasses only the board guard for this synthetic test;
normal Samsung loading never uses that parameter.

## Install, inspect and remove

After module/QEMU validation, on the matching Samsung kernel:

```sh
sudo dpkg -i np545xla-power-supply_7.0.0-1_arm64.deb
sudo systemctl start np545-power-supply.service
cat /sys/class/power_supply/np545-usb-c/uevent
upower -e
upower -i /org/freedesktop/UPower/devices/line_power_np545_usb_c
```

The independent module can be loaded without reboot. Confirm a real unplug/replug
through sysfs, uevents and UPower before enabling the service for subsequent boots:

```sh
sudo systemctl enable np545-power-supply.service
```

Rollback affects only reporting:

```sh
sudo systemctl disable --now np545-power-supply.service
sudo modprobe -r np545_power_supply
sudo dpkg -r np545xla-power-supply
```

The validated charging controller, battery driver, USB boot entries, Windows,
internal storage, and sleep configuration are outside this package.

## Validation record

2026-11-11: 18 Python test methods passed locally and on ARM64. QEMU exercised 70
ABI/property/lifecycle assertions, including actual 20-second expiry. A read-only
Samsung preflight matched `online=1`, 5 V / 3 A, 0 mA charge target and 8.400 V
programmed ceiling while the battery was full. Existing controller PID 5565 and
invocation `4168ed72e5ea4d53a134ea2b139d9b0e` were unchanged. This preflight is not yet
the loaded-module/UPower or physical unplug/replug acceptance record.

Artifacts and raw evidence: `output/power-supply-20261111/` in the isolated
`dev/runliang/power-supply` checkout. The source is separate from other integration
sessions; no merge or push is implied by these tests.
