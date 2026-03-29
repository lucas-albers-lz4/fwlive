# OpenWrt 23.05 Compatibility Track (Later)

## Scope guardrails

- Keep nftables-only support.
- Preserve the same frontend API and normalized event schema.

## Expected differences to validate

- Log line prefixes may vary by image profile and kmod packaging.
- Some targets may emit fewer parsed keys in kernel messages.
- Interface naming and availability of `IN`/`OUT` tokens can differ.

## Compatibility strategy

- Keep parser tolerant to partial key-value payloads.
- Add optional per-profile parser adapters only if required.
- Keep UI filter controls unchanged; degrade missing fields to empty values.

## Acceptance

- Same LuCI page loads and polls successfully.
- No JS runtime errors when fields are absent.
- Action/interface/protocol/IP filters still operate on available data.
