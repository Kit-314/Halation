import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var model = ViewerModel.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Reveal in Finder") { model.revealInFinder() }
                .keyboardShortcut("r")
                .disabled(model.currentURL == nil)
            Button("Open in Default App") { model.openInDefaultApp() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.currentURL == nil)
            Divider()
            Button("Move to Trash") { model.moveToTrash() }
                .keyboardShortcut(.delete)
                .disabled(model.currentURL == nil || model.isEditing)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Edits") { model.saveEditsOverOriginal() }
                .keyboardShortcut("s")
                .disabled(!(model.editSession?.isDirty ?? false))
            Button("Save Edits As…") { model.saveEditsAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!(model.editSession?.isDirty ?? false))
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy File") { model.copyFile() }
                .keyboardShortcut("c")
                .disabled(model.currentURL == nil)
            Button("Copy Image") { model.copyImage() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.image == nil)
        }
        CommandMenu("Image") {
            Button(model.isEditing ? "Exit Edit Mode" : "Edit Photo") { model.toggleEdit() }
                .keyboardShortcut("e")
                .disabled(model.currentURL == nil)
            Divider()
            Button("Next Photo") { model.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(model.isEditing)
            Button("Previous Photo") { model.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(model.isEditing)
            Divider()
            Button("Zoom In") { model.zoom?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.zoom?.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.zoom?.zoomToFit() }
                .keyboardShortcut("0")
            Button("Actual Size") { model.zoom?.zoomTo(1) }
                .keyboardShortcut("1")
            Divider()
            Button("Rotate Clockwise") { model.rotate(clockwise: true) }
                .keyboardShortcut("]")
                .disabled(model.isEditing)
            Button("Rotate Counterclockwise") { model.rotate(clockwise: false) }
                .keyboardShortcut("[")
                .disabled(model.isEditing)
            Divider()
            Button("Show Info") { model.showInfo.toggle() }
                .keyboardShortcut("i")
            Button("Show Filmstrip") { model.showFilmstrip.toggle() }
                .keyboardShortcut("t")
            Divider()
            Button("Set as Wallpaper") { model.setAsWallpaper() }
                .disabled(model.currentURL == nil)
        }
        CommandMenu("Slideshow") {
            Button(model.isSlideshowRunning ? "Stop Slideshow" : "Start Slideshow") {
                model.toggleSlideshow()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(model.isEditing)
            Picker("Speed", selection: $model.slideshowInterval) {
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("3 seconds").tag(3.0)
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
            }
            Divider()
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        }
    }
}
