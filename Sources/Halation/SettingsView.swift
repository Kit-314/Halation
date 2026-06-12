import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model = ViewerModel.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Photo transition", selection: $model.transitionStyle) {
                ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Sort photos by", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }

            VStack(alignment: .leading) {
                Slider(value: $model.slideshowInterval, in: 1...10, step: 0.5) {
                    Text("Slideshow speed")
                }
                Text("\(model.slideshowInterval, specifier: "%.1f") seconds per photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
    }
}

struct ShortcutsSettings: View {
    @ObservedObject var model = ViewerModel.shared
    @State private var recordingAction: KeyAction?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(KeyAction.allCases) { action in
                        shortcutRow(action)
                        Divider().opacity(0.4)
                    }
                }
                .padding(12)
            }
            .frame(height: 380)
            Divider()
            HStack {
                Text(recordingAction == nil
                     ? "Click + and press any key. Esc cancels."
                     : "Press a key for “\(recordingAction!.label)”…")
                    .font(.caption)
                    .foregroundStyle(recordingAction == nil ? .secondary : .primary)
                Spacer()
                Button("Reset All to Defaults") {
                    model.keymap.resetAll()
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func shortcutRow(_ action: KeyAction) -> some View {
        HStack(spacing: 8) {
            Text(action.label)
                .font(.system(size: 12))
                .frame(width: 160, alignment: .leading)
            Spacer()
            ForEach(model.keymap.strokes(for: action), id: \.self) { stroke in
                HStack(spacing: 3) {
                    Text(stroke.display)
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                    Button {
                        model.keymap.remove(stroke, from: action)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            Button {
                recordingAction == action ? stopRecording() : startRecording(action)
            } label: {
                Image(systemName: recordingAction == action ? "ellipsis" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Record a new key")
            Button {
                model.keymap.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Reset to default")
        }
        .padding(.vertical, 3)
        .background(recordingAction == action ? Color.accentColor.opacity(0.12) : .clear)
    }

    private func startRecording(_ action: KeyAction) {
        stopRecording()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            DispatchQueue.main.async {
                defer { stopRecording() }
                guard event.keyCode != 53 else { return }  // esc cancels
                // plain keys only, the viewer doesn't do modifier shortcuts
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return }
                ViewerModel.shared.keymap.add(KeyStroke.from(event), to: action)
            }
            return nil  // swallow the keystroke
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingAction = nil
    }
}
