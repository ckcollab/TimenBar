import SwiftUI

struct FavoritesStrip: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appModel.favorites) { favorite in
                    let unavailable = favorite.projectID.map { id in !appModel.projects.contains(where: { $0.id == id && $0.isActive }) } ?? false
                    Button {
                        Task { await appModel.startFavorite(favorite) }
                    } label: {
                        Label(favorite.name, systemImage: "star.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(appModel.timenTheme.accentMuted, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    .help(unavailable ? "The linked Timen project is no longer available." : "Start \(favorite.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}
