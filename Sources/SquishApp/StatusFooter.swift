import SwiftUI

/// Everything the footer displays. A plain `Equatable` value so the window can hand
/// the hosting view a new one on every change without any observation machinery.
struct FooterStats: Equatable {
    var fileCount = 0
    var selectedCount = 0
    var totalOriginal: Int64 = 0
    var totalProjected: Int64 = 0
    /// How many rows actually have a projection yet - the totals are only honest
    /// once this equals `fileCount`.
    var projectedCount = 0
    var failedCount = 0
    var mode: SquishMode = .jpeg
    var busyCompleted = 0
    var busyTotal = 0

    var isBusy: Bool { busyTotal > 0 }

    var savedPercent: Double? {
        guard totalOriginal > 0, projectedCount > 0 else { return nil }
        return (Double(totalOriginal - totalProjected) / Double(totalOriginal)) * 100
    }
}

/// The window's footer, in the visual language of Klip's ActionBar:
/// intrinsically sized (no fixed height), 14/9 padding, a `primary.opacity(0.04)`
/// tint with a 0.5pt hairline along its top edge, 10pt text throughout, counts in
/// `.tertiary` monospaced digits, lowercase `.secondary` hint labels behind small
/// keycap chips, and `·` as its own view rather than string interpolation.
struct StatusFooter: View {

    var stats: FooterStats

    private let captionSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 12) {
            counts

            Divider()
                .frame(height: 14)

            summary
                .frame(maxWidth: .infinity, alignment: .leading)

            hints

            Divider()
                .frame(height: 14)

            Text(stats.mode.displayName)
                .font(.system(size: captionSize))
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color.primary.opacity(0.12)),
            alignment: .top
        )
    }

    // MARK: - Left: how many files, how many picked

    private var counts: some View {
        HStack(spacing: 5) {
            if stats.fileCount == 0 {
                Text("No files")
                    .font(.system(size: captionSize))
                    .foregroundStyle(.tertiary)
            } else {
                Text("\(stats.fileCount) \(stats.fileCount == 1 ? "file" : "files")")
                    .font(.system(size: captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if stats.selectedCount > 0 {
                    Text("·")
                        .font(.system(size: captionSize))
                        .foregroundStyle(.tertiary)
                    Text("\(stats.selectedCount) selected")
                        .font(.system(size: captionSize))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Middle: the numbers that matter

    @ViewBuilder
    private var summary: some View {
        if stats.isBusy {
            HStack(spacing: 5) {
                Text("Calculating")
                    .font(.system(size: captionSize))
                    .foregroundStyle(.secondary)
                Text("\(stats.busyCompleted) of \(stats.busyTotal)")
                    .font(.system(size: captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()
        } else if stats.fileCount == 0 {
            Text("Drop images to begin")
                .font(.system(size: captionSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        } else {
            HStack(spacing: 5) {
                Text(ByteFormat.string(for: stats.totalOriginal))
                    .font(.system(size: captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Text("→")
                    .font(.system(size: captionSize))
                    .foregroundStyle(.tertiary)
                Text(stats.projectedCount > 0 ? ByteFormat.string(for: stats.totalProjected) : "—")
                    .font(.system(size: captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if let saved = stats.savedPercent {
                    Text("·")
                        .font(.system(size: captionSize))
                        .foregroundStyle(.tertiary)
                    Text("saved \(Int(saved.rounded()))%")
                        .font(.system(size: captionSize))
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                if stats.failedCount > 0 {
                    Text("·")
                        .font(.system(size: captionSize))
                        .foregroundStyle(.tertiary)
                    Text("\(stats.failedCount) failed")
                        .font(.system(size: captionSize))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: - Right: keyboard hints, Klip's keycap-chip treatment

    @ViewBuilder
    private var hints: some View {
        if stats.fileCount > 0 {
            HStack(spacing: 10) {
                if stats.selectedCount > 0 {
                    hint("⌫", "remove")
                }
                hint("⌘↩", "compress")
            }
            .fixedSize()
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: captionSize))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: captionSize))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
