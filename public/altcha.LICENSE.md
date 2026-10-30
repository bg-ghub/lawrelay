ALTCHA is used by `altcha.min.js` for the local, self-hosted proof-of-work
challenge. This copy matches the existing WetWijzer deployment.

Source: https://github.com/altcha-org/altcha
SHA-256: 735B8CF16A93E66EC4D26B910F43A1C597AD64A31FF11625671202D1C301E032

The local copy has one CSP-only patch: injected ALTCHA styles receive the
page's existing CSP nonce before they are appended. No other source behavior
is changed.

MIT License

Copyright (c) 2023-2026 Daniel Regeci, BAU Software s.r.o.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
