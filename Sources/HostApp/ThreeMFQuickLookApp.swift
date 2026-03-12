import SwiftUI

@main
struct ThreeMFQuickLookApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
                Text("threemf")
                    .font(.title)
                Text("Quick Look previews for .3mf and .stl files in Finder.")
                    .foregroundColor(.secondary)
                Text("Press Space on any .3mf or .stl file to preview it.")
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .frame(minWidth: 400, minHeight: 250)
        }
    }
}
