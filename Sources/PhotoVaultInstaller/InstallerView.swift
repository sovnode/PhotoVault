import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoVaultSetup

struct InstallerView: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        Group {
            switch model.phase {
            case .choosing: ChoosingView()
            case .working: WorkingView()
            case .done(let report): DoneView(report: report)
            case .failed(let title, let message): FailedView(title: title, message: message)
            }
        }
        // Room for the window buttons: the title bar is hidden.
        .padding(EdgeInsets(top: 34, leading: 28, bottom: 24, trailing: 28))
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Both forms get the same height, so the window keeps its size when
    /// switching between them.
    static let formHeight: CGFloat = 216
}

/// The icon and a title, at the top of every screen.
struct Header: View {
    let title: String
    var subtitle: String?
    var symbol: (name: String, color: Color)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
                .overlay(alignment: .bottomTrailing) {
                    if let symbol {
                        Image(systemName: symbol.name)
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, symbol.color)
                            .background(Circle().fill(.white).padding(2))
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Choosing

struct ChoosingView: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(title: "PhotoVault Installer",
                   subtitle: "Version \(model.version). A vault is a disk image that holds your photos, with PhotoVault inside to show them.")
            HStack(spacing: 12) {
                ModeCard(mode: .create, symbol: "plus.rectangle.on.folder", title: "Create a New Vault",
                         detail: "A new disk image, with PhotoVault and an empty Photos folder.")
                ModeCard(mode: .install, symbol: "arrow.down.app", title: "Install on an Existing Vault",
                         detail: "Puts PhotoVault \(model.version) on a vault you have. Its photos stay as they are.")
            }
            Group {
                switch model.mode {
                case .create: CreateForm()
                case .install: InstallForm()
                }
            }
            .frame(minHeight: InstallerView.formHeight, alignment: .top)
            HStack {
                Spacer()
                Button(model.startLabel) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canStart)
            }
        }
    }
}

/// One of the two kinds of setup, as a card to click.
struct ModeCard: View {
    @EnvironmentObject var model: InstallerModel
    let mode: InstallerModel.Mode
    let symbol: String
    let title: String
    let detail: String

    private var selected: Bool { model.mode == mode }

    var body: some View {
        Button { model.mode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CreateForm: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormRow(label: "Name:") {
                TextField("Name", text: $model.name).labelsHidden().frame(width: 280)
                if let problem = model.nameProblem {
                    Note(text: problem, kind: .warning)
                } else {
                    Note(text: "The disk is called “\(model.trimmedName)”, and its disk image “\(model.trimmedName).sparsebundle”.")
                }
            }
            FormRow(label: "Save in:") {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: model.folder.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(FileManager.default.displayName(atPath: model.folder.path))
                    Button("Choose…") { model.chooseFolder() }
                }
                Note(text: [model.folderDescription, model.freeSpace].compactMap { $0 }.joined(separator: " · "))
                if model.folderIsInICloud {
                    Note(text: "This folder is in iCloud Drive, so every photo in the vault would be uploaded to iCloud. Choose a folder outside iCloud Drive.",
                         kind: .warning)
                }
            }
            FormRow(label: "Size:") {
                Picker("Size", selection: $model.size) {
                    ForEach(VaultSetup.sizes, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
                Note(text: "The most it can hold. The disk image takes only the space its photos use.")
            }
            FormRow { JoyTagRow() }
        }
    }
}

struct InstallForm: View {
    @EnvironmentObject var model: InstallerModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let vault = model.chosen {
                FormRow(label: "Vault:") {
                    HStack(spacing: 8) {
                        Picker("Vault", selection: $model.chosenMount) {
                            ForEach(model.vaults, id: \.mountPoint) { v in
                                Text(v.name).tag(Optional(v.mountPoint))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                        Button("Choose…") { model.chooseVault() }
                    }
                    Note(text: model.location(of: vault))
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.facts(for: vault), id: \.self) { FactRow(fact: $0) }
                    }
                    .padding(.top, 8)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No vault is open").font(.headline)
                    Text("Choose a vault's disk image (.sparsebundle), or drag it here.")
                        .foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseVault() }.padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [5, 4])))
            }
            if let opening = model.opening {
                FormRow {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening “\(opening)”…").foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = model.chooseProblem {
                FormRow { Note(text: problem, kind: .warning) }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.choose(url) }
            }
            return true
        }
    }
}

/// How wide the labels on the left of the forms are.
let formLabelWidth: CGFloat = 64

/// A label on the left, and what it labels on the right.
struct FormRow<Content: View>: View {
    var label = ""
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: formLabelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// JoyTag comes with every vault: what it is, and what it costs.
struct JoyTagRow: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FactRow(fact: .init(kind: .fine, text: "Includes JoyTag, which tags your photos automatically (\(InstallerModel.bytes(model.joyTagBytes)))."))
            if !model.joyTagRunsHere {
                Note(text: "Tagging needs macOS 15 or later. Until the vault is opened on a newer Mac, PhotoVault works without it.")
                    .padding(.leading, 24)
            }
        }
        .padding(.top, 6)
    }
}

struct FactRow: View {
    let fact: InstallerModel.Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch fact.kind {
            case .fine: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .note: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(fact.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A line of small print under a field.
struct Note: View {
    let text: String
    var kind: InstallerModel.Fact.Kind = .fine

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(kind == .warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Working

struct WorkingView: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Header(title: model.workTitle + "…", subtitle: "This takes a minute or so.")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.steps) { step in
                    HStack(spacing: 10) {
                        Group {
                            switch step.status {
                            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                            case .active: ProgressView().controlSize(.small)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(step.step.rawValue).foregroundStyle(step.status == .waiting ? .secondary : .primary)
                    }
                }
            }
            .padding(.leading, 74)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Done

struct DoneView: View {
    @EnvironmentObject var model: InstallerModel
    let report: SetupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: model.doneTitle(report), symbol: ("checkmark.circle.fill", .green))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.doneLines(report), id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                if report.createdImage != nil {
                    Text("Next:").font(.headline).padding(.top, 6)
                    ForEach(Array(model.nextSteps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.leading, 74)
            HStack {
                Button("Show in Finder") { model.showInFinder() }
                Spacer()
                Button("Done") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Open PhotoVault") { model.openPhotoVault() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Failed

struct FailedView: View {
    @EnvironmentObject var model: InstallerModel
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: title, symbol: ("exclamationmark.circle.fill", .orange))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 74)
            HStack {
                Spacer()
                if model.payload == nil {
                    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Back") { model.back() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
    }
}
