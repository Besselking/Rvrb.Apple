import SwiftUI

/// An HTML table from the chat as a grid: header cells bold on a tint, a line between rows, long cells wrapping.
/// A table wider than the chat scrolls sideways.
struct ChatTableView: View {
    let table: ChatText.Table

    /// The widest a cell gets before its text wraps.
    private let maxCellWidth: CGFloat = 240
    private let imageHeight: CGFloat = 36

    var body: some View {
        ScrollView(.horizontal) {
            grid
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.automatic)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                if row > 0 {
                    Divider()
                }
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        let cell = table.rows[row][column]
                        self.cell(cell)
                            .gridCellColumns(cell.columns)
                    }
                }
            }
        }
        .fixedSize()
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cell(_ cell: ChatText.Table.Cell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !cell.body.plain.isEmpty {
                Text(cell.body.text)
                    .fontWeight(cell.isHeader ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cell.body.images.isEmpty {
                HStack(spacing: 4) {
                    ForEach(cell.body.images, id: \.self) { image in
                        RemoteImage(source: image, maxPixelSize: imageHeight * 3, contentMode: .fit) { _ in
                            Color.secondary.opacity(0.15)
                        }
                        .frame(height: imageHeight)
                        .clipShape(cell.body.styles[image]?.circular == true
                                   ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
                    }
                }
            }
        }
        .font(.callout)
        .modifier(CappedWidth(maxWidth: maxCellWidth))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cell.isHeader ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
    }
}

/// At most `maxWidth` wide, and as tall as it then needs to be. A plain `frame(maxWidth:)` in a grid sized to fit
/// would report the height of the unwrapped text.
private struct CappedWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        Capped(maxWidth: maxWidth) { content }
    }

    private struct Capped: Layout {
        let maxWidth: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let content = subviews.first else { return .zero }
            let ideal = content.sizeThatFits(.unspecified)
            let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
            return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
