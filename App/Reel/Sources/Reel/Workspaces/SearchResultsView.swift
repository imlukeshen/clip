import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SearchEngine
import SwiftUI

struct SearchResultsView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.isSearchComplete {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Still indexing — results will improve in the background")
                }
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
            if model.embeddingModelNeedsReindex {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(theme.palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Semantic model changed")
                            .font(theme.type.label.font)
                        Text("Exact search still works. Rebuild to refresh concept matches safely.")
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    Spacer()
                    Button("Rebuild") { model.reindexSemanticSearch() }
                        .buttonStyle(ReelBorderedButtonStyle())
                }
                .padding(12)
                .background(theme.palette.surfacePanel)
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                )
            }
            if model.isSearchLoading, model.searchHits.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Searching your library…")
                }
                .font(theme.type.body.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.vertical, 28)
            } else if model.searchHits.isEmpty {
                EmptyState(
                    headline: "No results for “\(model.searchQuery)”",
                    actionTitle: "Clear search",
                    action: model.clearSearch
                )
                .padding(.vertical, 26)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.searchHits) { hit in
                        if let asset = asset(for: hit) {
                            resultRow(hit: hit, asset: asset)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Search")
                .font(theme.type.title.font)
            Text("\(model.searchHits.count) result\(model.searchHits.count == 1 ? "" : "s")")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            Spacer()
            if model.isSearchLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func resultRow(hit: SearchHit, asset: AssetRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.activateSearchHit(hit)
            } label: {
                HStack(spacing: 13) {
                    AssetThumbnail(asset: asset, libraryRoot: model.libraryRoot)
                        .frame(width: 92, height: 58)
                        .background(theme.palette.surfaceSunken)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: theme.metrics.radius.small,
                                style: .continuous
                            )
                        )
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(asset.displayName)
                                .font(theme.type.label.font)
                                .foregroundStyle(theme.palette.textPrimary)
                                .lineLimit(1)
                            if hit.isUnavailable {
                                Text("Missing")
                                    .font(theme.type.micro.font)
                                    .foregroundStyle(theme.palette.textTertiary)
                            }
                        }
                        Text(hit.snippet)
                            .font(theme.type.body.font)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(2)
                        Text(sourceDescription(hit.sources))
                            .font(theme.type.micro.font)
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(hit.isUnavailable)

            if !hit.moments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(hit.moments.prefix(12)) { moment in
                            Button {
                                model.activateSearchHit(hit, moment: moment)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(format(moment.start))
                                        .font(theme.type.numeric.font)
                                    Text(moment.snippet)
                                        .lineLimit(1)
                                }
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.textSecondary)
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(theme.palette.surfaceRaised)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: theme.metrics.radius.control,
                                        style: .continuous
                                    )
                                )
                            }
                            .buttonStyle(ReelPlainButtonStyle())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.leading, 105)
            }
        }
        .padding(12)
        .background(theme.palette.surfacePanel)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
    }

    private func asset(for hit: SearchHit) -> AssetRecord? {
        model.assets.first { $0.id == hit.assetID }
    }

    private func sourceDescription(_ sources: Set<SearchHitSource>) -> String {
        sources.sorted(by: { $0.rawValue < $1.rawValue }).map { source in
            switch source {
            case .ocr: "On-screen text"
            case .transcript: "Spoken words"
            case .filename: "Filename"
            case .summary: "Summary"
            }
        }.joined(separator: " · ")
    }

    private func format(_ time: RationalTime) -> String {
        let seconds = max(0, Int(time.seconds.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
