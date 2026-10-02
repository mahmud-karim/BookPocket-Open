import SwiftUI

enum Obsidian {
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.078, blue: 0.086, alpha: 1) : UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.110, green: 0.129, blue: 0.145, alpha: 1) : .white })
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.863, green: 0.773, blue: 0.616, alpha: 1) : UIColor(red: 0.43, green: 0.32, blue: 0.15, alpha: 1) })
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.078, blue: 0.086, alpha: 1) : .white })
}

struct BookCover: View {
    let book: LocalBook
    let url: URL?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.30, blue: 0.31), Color(red: 0.11, green: 0.15, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed").font(.title2)
                    Text(book.title).font(.system(.title3, design: .serif)).multilineTextAlignment(.center).lineLimit(4)
                    Rectangle().frame(width: 28, height: 1)
                    Text(book.author.isEmpty ? "YOUR LIBRARY" : book.author).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }.foregroundStyle(Color(red: 0.86, green: 0.77, blue: 0.61)).padding(16)
            }
        }.aspectRatio(0.68, contentMode: .fit).clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
    }
}
