// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("謝辞")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Aoshingo の高度化PICS アドバタイズ解析は、yumu19/ble-pics-viewer（MIT License, Copyright (c) 2025 Tsubasa Yumura）の解析仕様と実装を参考に、Swift で再実装したものです。受信方法と解析結果を公開してくださった作者に心より感謝します。")
                Link("yumu19/ble-pics-viewer", destination: AppLinks.blePicsViewer)

                Text("Aoshingo のライセンス")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Apache License 2.0")
                Link("ソースコードとライセンス全文", destination: AppLinks.repository)

                Text("ble-pics-viewer")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: Licenses.blePicsViewerMIT)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("謝辞・ライセンス")
    }
}

enum Licenses {
    static let blePicsViewerMIT = """
    MIT License

    Copyright (c) 2025 Tsubasa Yumura

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
    """
}
