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
imported, and creates only `np545xla-power-supply_7.0.0-3_arm64.deb`. It never rebuilds
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
sudo dpkg -i np545xla-power-supply_7.0.0-3_arm64.deb
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

2026-11-11: 19 Python test methods passed locally and on ARM64. QEMU exercised 70
ABI/property/lifecycle assertions, including actual 20-second expiry. A read-only
Samsung preflight matched `online=1`, 5 V / 3 A, 0 mA charge target and 8.400 V
programmed ceiling while the battery was full.

The final package was then installed and started without reboot on physical boot
`cebcfca3-61f6-4fba-977a-b458e316fbc1`, kernel 7.0.0 (the previously accepted PM-debug
image). `test_mode` was not used. The live module produced the expected properties
and UPower automatically created `/org/freedesktop/UPower/devices/line_power_np545_usb_c`
with `online: yes` and `power supply: yes`; `OnBattery` was false. The original SBS
battery remained a separate normal battery object.

Pausing only the new reporter for 23 seconds removed the supply from both sysfs
and UPower. Resuming it restored online state. Stopping/restarting only its service
also removed/restored the object. The original charging controller stayed PID 5565,
invocation `4168ed72e5ea4d53a134ea2b139d9b0e`, with zero restarts and continuing full
standby samples. No matching kernel warnings appeared. The lifecycle wrapper's
final `journalctl --grep` returned 1 because it found no entries, after all assertions
had completed; this is recorded explicitly in `lifecycle-result.json`.

Final module SHA-256: `5f5a9986da4052f680ec5058ecc87b7d110cd4f3f814bda5d9bdef4e9f24b3b3`.
Final package (7.0.0-2) SHA-256: `b29a32db55b581e64c394fbb3f56090ccd4cfb240d2635f601d71a2e37398878`.
The first loaded package was 7.0.0-1 (`c1c5ce82e7ce4f348063ba07927ebf6efff86b97868fe9c5f58204cd2b5acd0e`).
Version 2 adds tolerance for sub-millisecond apparent event reversal when rounded
controller seconds follow nanosecond IRQ records, with a regression test. Its
module is byte-identical to the QEMU/physical-tested module. Version 2 was installed
and the reporter alone restarted: PID 13831, zero restarts, online state restored,
original charging controller unchanged. See `update-v2.log`.
The physical unplug/replug test subsequently passed, and the status service is
**enabled at boot**. On November 11, no new boot was exercised. The November 12
boot inspection below subsequently exposed an autostart failure, so the November 11
runtime acceptance must not be treated as successful boot acceptance. No real sleep,
different adapter, positive-current charging phase, or other desktop environment
was tested as part of this feature.

### Physical unplug/replug acceptance, 2026-11-11

The user unplugged the original IC10 charger and later reattached it to the same
port. The boot ID and both charging/status service invocations stayed unchanged.

| Phase | Standard interface / UPower | Battery and controller |
| --- | --- | --- |
| Unplugged | IC10 stopped answering (NACK), so the bridge removed `np545-usb-c`; UPower removed the line-power object and set `OnBattery=true` | 97%, `Discharging`, measured current -942,000 µA in the captured sysfs snapshot; controller waiting for attachment |
| Reattached | `np545-usb-c` reappeared with `online=1`, PD 12,000,000 µV / 3,000,000 µA; UPower reported online and `OnBattery=false` | Existing controller restored the input path, programmed charge current remained 0 µA, ceiling 8,400,000 µV |
| Stable after reattach | Seven samples over 30.27 seconds all retained those properties and `OnBattery=false` | Current stayed 0 µA; gauge reported `Full` at 97%, so the unchanged controller retained its full/recharge waiting policy |

This unplug test exercised **unknown/unavailable input reporting**, not a persistent
`online=0` object: a NACK is deliberately not converted into physical-detach proof
by the reporter. The independent SBS battery supplied the actual discharge state.
The controller's detach event was at BOOTTIME 5051.839 s, and the reporter published
unknown at 5055.334 s. After the first successful `full-sample` at 5684.804 s, it
published online at 5688.204 s. These are producer timestamps, not measured desktop
rendering latency. Raw evidence is in `unplug-wifi.log`, `replug-wifi.log`, and
`finish-validation.log`.

`systemctl enable np545-power-supply.service` created its `multi-user.target.wants`
link and read back `enabled`; it remains ordered after `np545-gpiocharge.service`.
The current kernel command line already requests the controller through
`systemd.wants=np545-gpiocharge.service`. The charging controller stayed PID 5565,
the reporter PID 13831, and both had zero restarts throughout this physical test.
The five previously masked sleep targets remain masked. **Autostart has been
configured and inspected, but a subsequent physical boot has not been exercised.**

### Wired access interruption during acceptance

The wired address `10.86.97.82` became unreachable, so acceptance continued through
the user-provided Wi-Fi address `10.86.112.192`, still on SSH port 2223 and with the
same pinned host key. SSH remained PID 499 and was confirmed listening on
`0.0.0.0:2223`; it had not stopped. The user initially tested the default port 22,
which is not the configured SSH port.

The RTL8153/r8152 interface retained its address and reported carrier/up, but kernel
logs contained USB status `-71`, failed reads, a disconnect and a SuperSpeed reset.
See `wired-unplug-diagnostic.log`. This identifies a USB Ethernet path problem;
it does not establish its root cause or that charging unplug/replug caused it.
No USB reset, network reconfiguration, SSH restart, or reboot was performed by this
test. The wired issue remains unresolved; use Wi-Fi for the next connection.

Artifacts and raw evidence: `output/power-supply-20261111/` in the isolated
`dev/runliang/power-supply` checkout. The source is separate from other integration
sessions; no merge or push is implied by these tests.
An archival copy is also kept in the main repository's ignored
`output/power-supply-status-20261111/` directory, including source and evidence.

### November 12 boot inspection and startup-condition correction

On 2026-11-12, boot `bc4ec607-8973-4d5e-8f2f-d5952372ed4a` was running the original
Latest kernel Image `163b71d2...64735b`, with `np545.battery=1` and the controller's
startup flags present. Two distinct failures were observed:

* `np545-power-supply.service` was enabled but skipped during boot because
  `ConditionPathExists=/sys/class/power_supply/np545-battery` was false at that
  moment. The battery node and module existed by the time of inspection. A systemd
  condition is not a wait for the device, so this left the service inactive.
* `np545-gpiocharge.service` exited with status 1 after about 1.114 seconds. Its
  early boot journal entries were no longer retained. The cause of this controller
  failure has **not** been established, and a reporting-only fix cannot repair it.

The user then reported automatic shutdown from an empty battery, and clarified the
meter comparison: approximately 12 V / 0.6 A (7.2 W) while Linux was running versus
approximately 35 W when completely powered off. These are user-reported adapter
input readings, not independently measured battery currents. This supports giving
the controller's failed startup priority, but does not identify the failing line
of code or prove that the reporting bridge caused it.

Candidate package **7.0.0-3** replaces the one-time battery-node condition with
`ConditionKernelCommandLine=np545.battery=1`. The reporter's existing runtime checks
already withhold an input supply until an active, recognized controller supplies
fresh evidence. It can therefore start before the battery is ready without
inventing an online state. This change does not restart or modify charging control.

The candidate passed ARM64 compilation and `systemd-analyze verify`; its module is
byte-identical to the physically/QEMU-validated module. The final package's unit
was extracted and inspected. Package SHA-256:
`5748c9beabc2e7e451a39f1fafd3f1d51e463f7b31e50a58bc3848924b09da7e`.
**It has not yet been installed or accepted on the physical machine.** Evidence
and the candidate are in `output/sleep-static-ip-20261112/`.

The same inspection confirmed that all five sleep targets remain persistently
masked, and logind explicitly refused `suspend.target`. The kernel still advertises
`s2idle`; this is a policy block before sleep, not a new demonstration of failed
resume. No sleep targets were unmasked. A requested wired static-IP change was
prepared, but the SSH connection closed before a success acknowledgement as the
machine ran out of battery; the remote file/timer state must be checked on recovery
before retrying. Do not report that network change as completed.
