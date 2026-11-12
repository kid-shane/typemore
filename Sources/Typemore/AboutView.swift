import Foundation
import SwiftUI

struct AboutMetadata {
    let version: String?
    let build: String?

    init(bundle: Bundle = .main) {
        func value(_ key: String) -> String? {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    var versionText: String { version ?? "开发中" }
    var sidebarVersion: String { version.map { "v\($0)" } ?? "开发中" }
    var editionText: String {
        let edition = "公开版"
        return build?.hasSuffix("-local") == true ? "\(edition) · 本地体验" : edition
    }
}

struct AboutView: View {
    var metadata = AboutMetadata()

    private let developerURL = URL(string: "https://github.com/kid-shane")!
    private let projectURL = URL(string: "https://github.com/kid-shane/typemore")!

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 18) {
                TypemoreMark(size: 68)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Typemore")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(UITheme.text)
                    Text("Type more，让表达更丰富。")
                        .font(.system(size: 13))
                        .foregroundStyle(UITheme.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("当前版本")
                    .font(.system(size: 12))
                    .foregroundStyle(UITheme.secondary)
                HStack(spacing: 14) {
                    Text(metadata.versionText)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(UITheme.text)
                        .textSelection(.enabled)
                    Text(metadata.editionText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UITheme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(UITheme.selection)
                        .clipShape(Capsule())
                }
                if let build = metadata.build {
                    Text("构建 \(build)")
                        .font(.system(size: 11))
                        .foregroundStyle(UITheme.secondary)
                        .textSelection(.enabled)
                }
            }

            Rectangle().fill(UITheme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("开发者")
                        .font(.system(size: 12))
                        .foregroundStyle(UITheme.secondary)
                    Text("kid-shane")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(UITheme.text)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Link(destination: developerURL) {
                        HStack(spacing: 8) {
                            Text("开发者主页")
                            AppIcon(symbol: .next, size: .small)
                        }
                    }
                    .accessibilityLabel("开发者主页")
                    Link(destination: projectURL) {
                        HStack(spacing: 8) {
                            Text("项目主页")
                            AppIcon(symbol: .next, size: .small)
                        }
                    }
                    .accessibilityLabel("项目主页")
                }
                .buttonStyle(SettingsButtonStyle())
            }

            Text("© 2026 Typemore · MIT License")
                .font(.system(size: 11))
                .foregroundStyle(UITheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
