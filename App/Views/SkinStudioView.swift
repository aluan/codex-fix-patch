import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SkinStudioView: View {
    @Bindable var model: AppModel
    @State private var showingImporter = false
    @State private var editorDraft: SkinEditorDraft?
    @State private var themePendingDeletion: SkinTheme?
    @State private var showingApplyConfirmation = false
    @State private var showingRestoreConfirmation = false
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                runtimeCard
                themeGrid
                securityNotice
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.png, .jpeg, .webP],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .sheet(item: $editorDraft) { draft in
            SkinThemeEditor(draft: draft, model: model)
        }
        .confirmationDialog(
            "应用主题需要重启 Codex",
            isPresented: $showingApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出并重新打开 Codex") { model.applySelectedSkin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("正在执行的任务可能中断。GPTSwitch 只会请求正常退出，不会强制结束 Codex。")
        }
        .confirmationDialog(
            "恢复 Codex 原生界面？",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复并重启", role: .destructive) { model.restoreNativeSkin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Codex 将正常退出并以不带调试端口的原生模式重新打开。")
        }
        .confirmationDialog(
            themePendingDeletion.map { "删除“\($0.name)”？" } ?? "删除自定义主题？",
            isPresented: Binding(
                get: { themePendingDeletion != nil },
                set: { if !$0 { themePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除主题", role: .destructive) {
                guard let id = themePendingDeletion?.id else { return }
                Task {
                    _ = await model.deleteCustomSkin(id)
                    themePendingDeletion = nil
                }
            }
        } message: {
            Text("主题图片和配色会从本机删除；如果它正在使用，将自动切换到海洋玻璃。")
        }
        .alert("无法导入图片", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "未知错误")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 换肤")
                    .font(.largeTitle.weight(.semibold))
                Text("通过本机 CDP 实时应用主题，不修改 Codex.app 或 API 代理配置。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                Label("导入图片", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var runtimeCard: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: model.skinRuntimeStatus.symbolName)
                    .font(.title2)
                    .foregroundStyle(runtimeColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.skinRuntimeStatus.title)
                        .font(.headline)
                    Text(runtimeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.skinEnabled {
                    Button("恢复原生界面") { requestRestore() }
                        .disabled(model.isSkinTransitioning)
                } else {
                    Button("应用所选主题") { requestApply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedSkinTheme == nil || model.isSkinTransitioning)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text("运行状态")
        }
    }

    private var themeGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("主题库")
                .font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)], spacing: 14) {
                ForEach(model.skinThemes) { theme in
                    SkinThemeCard(
                        theme: theme,
                        selected: theme.id == model.selectedSkinThemeID,
                        active: model.skinEnabled && model.skinRuntimeStatus == .active(theme.id),
                        select: { model.selectSkinTheme(theme.id) },
                        edit: theme.source == .custom ? { editorDraft = .editing(theme) } : nil,
                        delete: theme.source == .custom ? { themePendingDeletion = theme } : nil
                    )
                }
            }
        }
    }

    private var securityNotice: some View {
        Label {
            Text("CDP 仅监听 127.0.0.1:9341，但协议本身没有认证；同一用户权限的其他本机进程可能访问该端口。恢复原生界面会关闭此调试边界。")
        } icon: {
            Image(systemName: "lock.trianglebadge.exclamationmark")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var runtimeColor: Color {
        switch model.skinRuntimeStatus {
        case .active: .accentColor
        case .failed: .red
        case .restarting, .injecting: .orange
        case .native, .waitingForCodex: .secondary
        }
    }

    private var runtimeDetail: String {
        switch model.skinRuntimeStatus {
        case .native: "当前未启用皮肤"
        case .waitingForCodex: "所选主题会在下次打开 Codex 时自动应用"
        case .restarting: "等待 Codex 正常退出并重新启动"
        case .injecting: "正在更新主窗口 renderer"
        case .active(let id): model.skinThemes.first(where: { $0.id == id }).map { "当前主题：\($0.name)" } ?? "主题已注入"
        case .failed(let message): message
        }
    }

    private func requestApply() {
        if model.isCodexRunningForSkin() {
            showingApplyConfirmation = true
        } else {
            model.applySelectedSkin()
        }
    }

    private func requestRestore() {
        if model.isCodexRunningForSkin() {
            showingRestoreConfirmation = true
        } else {
            model.restoreNativeSkin()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            Task {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let prepared = try await model.prepareSkinImage(at: url)
                    editorDraft = .creating(prepared: prepared, suggestedName: url.deletingPathExtension().lastPathComponent)
                } catch {
                    importError = error.localizedDescription
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct SkinThemeCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: SkinTheme
    let selected: Bool
    let active: Bool
    let select: () -> Void
    let edit: (() -> Void)?
    let delete: (() -> Void)?

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    if let url = theme.imageURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 125)
                            .clipped()
                    } else {
                        Rectangle().fill(.quaternary).frame(height: 125)
                    }
                    if selected {
                        Image(systemName: active ? "paintpalette.fill" : "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .padding(9)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(theme.name).font(.headline).lineLimit(1)
                        Text(theme.source == .builtIn ? "内置 · 跟随系统" : "自定义 · 跟随系统")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        paletteDot(displayPalette.accent)
                        paletteDot(displayPalette.secondary)
                        paletteDot(displayPalette.surface)
                    }
                }
                .padding(11)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let edit { Button("编辑名称与配色", action: edit) }
            if let delete { Button("删除主题", role: .destructive, action: delete) }
        }
        .accessibilityLabel("\(theme.name)，\(selected ? "已选择" : "未选择")")
    }

    private func paletteDot(_ hex: String) -> some View {
        Circle().fill(Color(hex: hex)).frame(width: 10, height: 10)
    }

    private var displayPalette: SkinPalette {
        colorScheme == .dark ? theme.palette.darkModeVariant() : theme.palette
    }
}

private struct SkinEditorDraft: Identifiable {
    let id = UUID()
    let existingTheme: SkinTheme?
    let prepared: PreparedSkinImage?
    let name: String
    let palette: SkinPalette
    let resetPalette: SkinPalette
    let previewData: Data?
    let previewURL: URL?

    static func creating(prepared: PreparedSkinImage, suggestedName: String) -> SkinEditorDraft {
        SkinEditorDraft(
            existingTheme: nil,
            prepared: prepared,
            name: suggestedName,
            palette: prepared.palette,
            resetPalette: prepared.palette,
            previewData: prepared.data,
            previewURL: nil
        )
    }

    static func editing(_ theme: SkinTheme) -> SkinEditorDraft {
        SkinEditorDraft(
            existingTheme: theme,
            prepared: nil,
            name: theme.name,
            palette: theme.palette,
            resetPalette: theme.palette,
            previewData: nil,
            previewURL: theme.imageURL
        )
    }
}

private struct SkinThemeEditor: View {
    let draft: SkinEditorDraft
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var accent: Color
    @State private var secondary: Color
    @State private var surface: Color
    @State private var text: Color
    @State private var saving = false

    init(draft: SkinEditorDraft, model: AppModel) {
        self.draft = draft
        self.model = model
        _name = State(initialValue: draft.name)
        _accent = State(initialValue: Color(hex: draft.palette.accent))
        _secondary = State(initialValue: Color(hex: draft.palette.secondary))
        _surface = State(initialValue: Color(hex: draft.palette.surface))
        _text = State(initialValue: Color(hex: draft.palette.text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.existingTheme == nil ? "创建自定义主题" : "编辑自定义主题")
                .font(.title2.weight(.semibold))
            preview
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            TextField("主题名称", text: $name)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { Text("强调色"); ColorPicker("强调色", selection: $accent).labelsHidden() }
                GridRow { Text("辅色"); ColorPicker("辅色", selection: $secondary).labelsHidden() }
                GridRow { Text("面板色"); ColorPicker("面板色", selection: $surface).labelsHidden() }
                GridRow { Text("文字色"); ColorPicker("文字色", selection: $text).labelsHidden() }
            }
            HStack {
                Button("恢复自动配色") { resetColors() }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private var preview: some View {
        if let data = draft.previewData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = draft.previewURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private var palette: SkinPalette {
        SkinPalette(
            accent: accent.hexString,
            secondary: secondary.hexString,
            surface: surface.hexString,
            text: text.hexString
        )
    }

    private func resetColors() {
        accent = Color(hex: draft.resetPalette.accent)
        secondary = Color(hex: draft.resetPalette.secondary)
        surface = Color(hex: draft.resetPalette.surface)
        text = Color(hex: draft.resetPalette.text)
    }

    private func save() {
        saving = true
        Task {
            let succeeded: Bool
            if var theme = draft.existingTheme {
                theme.name = name
                theme.palette = palette
                succeeded = await model.updateCustomSkin(theme)
            } else if let prepared = draft.prepared {
                succeeded = await model.saveCustomSkin(name: name, prepared: prepared, palette: palette) != nil
            } else {
                succeeded = false
            }
            saving = false
            if succeeded { dismiss() }
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}
