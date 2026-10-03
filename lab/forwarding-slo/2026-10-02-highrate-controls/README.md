# High-rate lab controls: 2026-10-02

Refs #1134. This is a control/configuration smoke, not forwarding qualification.
`identity.json` pins the actual rebuilt development IPK and merged source. The
installed rpcd hash in `configured-state.txt` matches source. The installed
adaptive-cap hash was also checked over SSH and is recorded in `identity.json`.
`queues-4.txt` is guest ethtool output: both interfaces report four current
combined channels, independently of the requested QEMU setting.

On one and then four queues, the guest `configure` and `check` passed. A
three-second 1-Gb/s routed probe with twenty pings passed; `check-logs` found
`fwlive-slo IN=eth1 OUT=eth2`. Cleanup restored `kernel.printk` to `7 4 1 7`
(`restored-state.txt`) and removed saved state. No 80-Gb/s result is claimed.
The guest was stopped and its owned host topology removed afterward.

Reproduce with the commands in `docs/developer/qemu-lab.md`, private writable
QCOW2/OVMF files, identical backend/queue selectors for setup and launch, and
`FWLIVE_SLO_CONSOLE_LEVEL=4` on configure. Run `check-logs` after routed traffic,
then cleanup, stop the guest, and teardown. The standard guest helper preserves
both the nft rule check and the real-log rejection of `fwlive-sloIN=`.
