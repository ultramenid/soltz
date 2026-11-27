# Notices

Soltz is free software under the GNU Affero General Public License v3.0 (see `LICENSE`).

## Upstream

Soltz's Rust core (`core/crates/soltz-core`, `core/crates/soltz-crypto`) is a modified version of the backend of
Voltius (https://github.com/VoltiusApp/voltius), Copyright © 2026 Killian Pavy, used and distributed under the GNU
Affero General Public License v3.0. The Swift app is a port of that project's frontend. Changes made in 2026: the
desktop/mobile shell and web frontend were removed, the core was put behind a UniFFI API, features other than the
terminal and file transfer were removed, and the project was renamed. Source files without a licence header under
`core/` are upstream's, under the same licence.

## Third-party software built into the app

- **Ghostty** (terminal engine), Copyright © Mitchell Hashimoto and Ghostty contributors, MIT License.
  https://github.com/ghostty-org/ghostty
- **libghostty-spm** (Swift package and prebuilt build of Ghostty's library, with patches), Copyright © Lakr233,
  MIT License. https://github.com/Lakr233/libghostty-spm
- **DisplayLink**, Copyright © Lakr233, MIT License. https://github.com/Lakr233/DisplayLink
- **bash-preexec** (in the terminal engine's shell integration), Copyright © Ryan Caloras and contributors,
  MIT License. https://github.com/rcaloras/bash-preexec
- **Rust crates** listed in `core/crates/soltz-core/Cargo.lock`, among them russh and russh-sftp (Apache-2.0),
  tokio (MIT), rustls (Apache-2.0 / ISC / MIT), ring (Apache-2.0 and ISC), the RustCrypto crates (Apache-2.0 / MIT)
  and uniffi (MPL-2.0), each under the licence named in its own package.

The MIT License, under which the MIT-licensed parts above are used:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation
> the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
> to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
> THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
> CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
> IN THE SOFTWARE.
