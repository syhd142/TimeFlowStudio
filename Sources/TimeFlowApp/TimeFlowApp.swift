import SwiftUI

@main
struct TimeFlowApp: App {
    @StateObject private var model = ProjectModel()

    var body: some Scene {
        WindowGroup("TimeFlow Studio") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 700)
                .task { model.restoreRecoveryIfAvailable() }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                Button("Redo") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }

            CommandGroup(replacing: .newItem) {
                Button("Select Images…") {
                    model.chooseImageFiles()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Import Folder…") {
                    model.chooseSequenceFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open Project…") {
                    model.chooseProjectToOpen()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Relink Missing Files…") {
                    model.chooseRelinkFolder()
                }
                .disabled(model.missingFrameCount == 0 || model.isBusy)

                Button("Save Project…") {
                    model.chooseProjectDestination()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.project.frames.isEmpty)
            }
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("TimeFlow Studio")
                    .font(.title2.bold())
                Text("A local-first timelapse and star-trail workflow for macOS.")
                    .foregroundStyle(.secondary)
                Text("Photos and project data stay on this Mac.")
                    .font(.callout)
            }
            .padding(24)
            .frame(width: 460)
        }
    }
}
