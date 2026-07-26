# Attribution

Third-party inspiration and notices for **fwlive** / **luci-app-fwlive**.

Project license: **[LICENSE](LICENSE)** (Apache-2.0).

---

## OPNsense Live View

**Firewall Live View** targets operator workflows similar to **Live View** in
[OPNsense](https://opnsense.org/) — a live, filterable firewall log table with
roughly one-second refresh, client-side filtering, click-to-filter, and related
layout patterns.

| Item | Detail |
|------|--------|
| **Upstream project** | [opnsense/core](https://github.com/opnsense/core) |
| **Upstream license** | [BSD 2-Clause License](https://opensource.org/licenses/BSD-2-Clause) (often called BSD 2.0) |
| **Authoritative license text** | [`LICENSE`](https://github.com/opnsense/core/blob/master/LICENSE) in the OPNsense core repository |

### What we did and did not copy

- **Inspired by:** OPNsense Live View **UX and behavior** (polling live table, filters, chips, auto-refresh, row limit, action highlighting, rule attribution patterns). See [`docs/opnsense-liveview-parity.md`](docs/opnsense-liveview-parity.md).
- **Original implementation:** All shipped code in this repository (`luci-app-fwlive`, `core/fwlive-log.js`, scripts, and tests) is written for **OpenWrt / LuCI** (`view.extend()`, ubus `log.read`, nftables/fw4 log parsing). It is **not** a port of OPNsense PHP, Volt, or upstream JavaScript.
- **No bundled OPNsense sources:** This repo does not ship OPNsense core as a submodule or vendored tree. Developers may clone [opnsense/core](https://github.com/opnsense/core) separately when comparing behavior or documenting parity.

### OPNsense BSD 2-Clause notice (summary)

OPNsense core is copyright its respective authors (Deciso B.V. and contributors).
The full copyright list is in upstream [`LICENSE`](https://github.com/opnsense/core/blob/master/LICENSE).

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

```
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

If substantial OPNsense-licensed source is ever imported into this tree, those
files must carry the BSD 2-Clause notice per the upstream license terms.

---

## Other dependencies

When built inside an **OpenWrt** tree, **LuCI**, **OpenWrt**, and other feed
packages apply their own licenses. This feed does not replace those terms.

Optional lab tooling (QEMU images, Docker SDK) and Node dev dependencies
(e.g. Playwright for screenshot capture) are governed by their respective
upstream licenses and are not part of the shipped `luci-app-fwlive` package.

---

## Further reading

- [UI design target — license and attribution](docs/fwlive-ui-design-target.md#license-and-attribution--evaluation)
- [OPNsense parity matrix](docs/opnsense-liveview-parity.md)
