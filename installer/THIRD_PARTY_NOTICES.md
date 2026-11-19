# Third-party notices — Supermarket Pro installer

This file is shipped as `vendor\THIRD_PARTY_NOTICES.md` inside the installed
tree and is required by R5 contract 8. Each component below is redistributed
under its own licence; the full licence text is either reproduced here, ships
inside the component itself, or both.

## 1. Inno Setup 7.1.1 (installer toolchain)

Copyright (C) 1997-2026 Jordan Russell. All rights reserved.
Portions Copyright (C) 2000-2026 Martijn Laan. All rights reserved.

This software is provided "as-is," without any express or implied warranty. In
no event shall the author be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter and redistribute it, provided that the
following conditions are met:

1. All redistributions of source code files must retain all copyright notices
   that are currently in place, and this list of conditions without
   modification.
2. All redistributions in binary form must retain all occurrences of the above
   copyright notice and web site addresses that are currently in place (for
   example, in the About boxes).
3. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software to distribute
   a product, an acknowledgment in the product documentation would be
   appreciated but is not required.

Web site: https://jrsoftware.org/
Full licence text as shipped by the vendor: `vendor\innosetup-license.txt`.

## 2. PostgreSQL 18.6 (EDB binaries package)

PostgreSQL is released under the PostgreSQL License, a permissive Open Source
license similar to BSD and MIT licenses.

Copyright (c) 1996-2026, PostgreSQL Global Development Group

Permission to use, copy, modify, and distribute this software and its
documentation for any purpose, without fee, and without a written agreement is
hereby granted, provided that the above copyright notice and this paragraph
and the following two paragraphs appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Web site: https://www.postgresql.org/about/licence/
Licence texts bundled by EDB inside `vendor\postgresql-18.6-5-windows-x64-binaries.zip`
(`pgsql\server_license.txt`, `pgsql\pgAdmin_license.txt`,
`pgsql\commandlinetools_3rd_party_licenses.txt`,
`pgsql\pgAdmin_3rd_party_licenses.txt`,
`pgsql\StackBuilder_3rd_party_licenses.txt`) are also extracted to
`vendor\postgres-licences\` at staging time.

## 3. OpenSSL 3 (bundled inside the PostgreSQL binaries)

The PostgreSQL binaries package contains `pgsql\bin\libssl-3-x64.dll` and
`pgsql\bin\libcrypto-3-x64.dll`.

OpenSSL 3.x is licensed under the Apache License, Version 2.0.

Copyright The OpenSSL Project Authors.

Full licence text: https://www.apache.org/licenses/LICENSE-2.0 and
https://www.openssl.org/source/license.html (also declared by EDB in the
package's installation notes).

## 4. WinSW 2.12.0 (Windows service wrapper)

MIT License

Copyright (c) 2008-2020 Kohsuke Kawaguchi, Sun Microsystems, Inc., CloudBees,
Inc., Oleg Nenashev and other contributors

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

Project: https://github.com/winsw/winsw

## 5. Python 3.13.17 (CPython Windows runtime)

Python is distributed under the Python Software Foundation License Agreement.

Full licence text ships inside the payload at `backend\python\LICENSE.txt`.
Web site: https://www.python.org/ · https://docs.python.org/3/license.html

The runtime payload also redistributes Microsoft Visual C++ runtime files
(`vcruntime140.dll`, `vcruntime140_1.dll`) exactly as published inside the
official python.org Windows runtime distribution, under Microsoft's Visual
Studio licence terms: https://visualstudio.microsoft.com/license-terms/

Note: since R6 this build also ships the official `vc_redist.x64.exe`
(Visual C++ 2015–2022 Redistributable) — see section 8 below.

## 6. Flutter desktop application (compiled Release build)

- Flutter framework and first-party plugins: BSD 3-Clause License,
  Copyright Google LLC and contributors. https://flutter.dev/legal
- PDFium (engine component, `pdfium.dll`): BSD 3-Clause License,
  Copyright the PDFium authors. https://pdfium.googlesource.com/pdfium/
- Plugin binaries (`printing_plugin.dll`,
  `flutter_secure_storage_windows_plugin.dll`, `dartjni.dll`) are
  redistributed under the licences of their upstream projects, declared in the
  corresponding plugin repositories under
  https://github.com/flutter/plugins and their package metadata.

## 7. Python runtime packages (backend dependency set)

The offline wheelhouse contains 48 pinned wheels listed in
`backend\requirements.lock.txt`. Each wheel carries its own licence text
inside its `<package>-<version>.dist-info\` directory. The set consists of
the dependencies declared in `new_app\backend\pyproject.toml` (MIT, BSD, Apache
2.0, PSF and equivalent permissive licences).

## 8. Microsoft Visual C++ 2015–2022 Redistributable (x64)

Project: https://aka.ms/vs/17/release/vc_redist.x64.exe
File: `vendor\vc_redist.x64.exe` (FileVersion 14.44.35211.0, 25,635,768 bytes,
SHA-256 `CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B`,
Authenticode signed by CN=Microsoft Corporation).

Redistributed under the Microsoft Visual Studio 2022 licence terms
("Distributable Code" / Visual C++ Runtime Files):
https://learn.microsoft.com/visualstudio/releases/2022/redistribution
and https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist
The installer runs it silently (`/install /quiet /norestart`) on the target
machine during installation; it is not executed on the build machine.
