import DesignSystem
import SolverKit
import SwiftUI

/// Geometry shared by the 13×13 canvases.
struct GridMetrics {
    let size: CGSize
    let gap: CGFloat = 2

    var cell: CGSize { CGSize(width: size.width / 13, height: size.height / 13) }

    func rect(row: Int, col: Int) -> CGRect {
        CGRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
            .insetBy(dx: gap / 2, dy: gap / 2)
    }

    func handClass(at p: CGPoint) -> HandClass? {
        guard size.width > 0, size.height > 0 else { return nil }
        let col = Int(p.x / cell.width), row = Int(p.y / cell.height)
        guard (0..<13).contains(row), (0..<13).contains(col), p.x >= 0, p.y >= 0 else { return nil }
        return HandClass.at(row: row, col: col)
    }

    var labelSize: CGFloat { max(8, min(15, cell.width * 0.26)) }
    var corner: CGFloat { max(2, min(5, cell.width * 0.08)) }
}

private func cellLabel(_ cls: HandClass, metrics m: GridMetrics, dim: Bool) -> Text {
    Text(cls.description)
        .font(.system(size: m.labelSize, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundColor(dim ? Color.secondary.opacity(0.7) : Color.primary)
}

// MARK: - Strategy matrix

/// The 13×13 results matrix. Rendered in one Canvas for speed.
struct StrategyMatrixView: View {
    let matrix: MatrixData
    let mode: DisplayMode
    @Binding var selected: HandClass?
    @Binding var hovered: HandClass?

    var body: some View {
        GeometryReader { geo in
            let m = GridMetrics(size: geo.size)
            Canvas { ctx, size in
                draw(ctx, metrics: GridMetrics(size: size))
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): let c = m.handClass(at: p); if c != hovered { hovered = c }
                case .ended: hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                guard let c = m.handClass(at: p) else { return }
                selected = selected == c ? nil : c
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Strategy matrix")
    }

    private func draw(_ ctx: GraphicsContext, metrics m: GridMetrics) {
        let empty = Color.primary.opacity(0.045)
        let player = Theme.playerColor(matrix.player)
        for row in 0..<13 {
            for col in 0..<13 {
                let s = matrix.cells[row * 13 + col]
                let r = m.rect(row: row, col: col)
                let shape = Path(roundedRect: r, cornerRadius: m.corner, style: .continuous)
                ctx.fill(shape, with: .color(empty))
                if !s.isEmpty {
                    var c = ctx
                    c.clip(to: shape)
                    switch mode {
                    case .strategy where matrix.isActing:
                        let h = max(2, r.height * CGFloat(s.fraction))
                        var x = r.minX
                        for (i, f) in s.frequencies.enumerated() where f > 0 {
                            let w = r.width * CGFloat(f)
                            c.fill(Path(CGRect(x: x, y: r.maxY - h, width: w + 0.5, height: h)),
                                   with: .color(Theme.actionColor(matrix.actions, i)))
                            x += w
                        }
                    case .strategy, .range:
                        let h = max(2, r.height * CGFloat(s.fraction))
                        c.fill(Path(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)),
                               with: .color(player.opacity(0.85)))
                    case .ev:
                        c.fill(Path(r), with: .color(Theme.diverging(matrix.evScore(s.ev))))
                    case .equity:
                        c.fill(Path(r), with: .color(Theme.diverging(Double(s.equity - 0.5) * 2)))
                    }
                }
                let label = ctx.resolve(cellLabel(s.handClass, metrics: m, dim: s.isEmpty))
                ctx.draw(label, at: CGPoint(x: r.minX + 3, y: r.minY + 2), anchor: .topLeading)
                if !s.isEmpty, m.cell.width > 44, let v = valueText(s) {
                    let t = ctx.resolve(Text(v).font(.system(size: m.labelSize * 0.78).monospacedDigit())
                        .foregroundColor(.primary.opacity(0.75)))
                    ctx.draw(t, at: CGPoint(x: r.maxX - 3, y: r.maxY - 2), anchor: .bottomTrailing)
                }
                if s.handClass == selected {
                    ctx.stroke(shape, with: .color(.primary), lineWidth: 2)
                } else if s.handClass == hovered {
                    ctx.stroke(shape, with: .color(.primary.opacity(0.5)), lineWidth: 1.25)
                }
            }
        }
    }

    private func valueText(_ s: ClassStats) -> String? {
        switch mode {
        case .ev: return String(format: "%.1f", s.ev)
        case .equity: return String(format: "%.0f", s.equity * 100)
        case .range: return s.fraction < 0.995 ? String(format: "%.0f", s.fraction * 100) : nil
        case .strategy: return nil
        }
    }
}

// MARK: - Range painter

/// Editable 13×13 range grid: click or drag to paint the brush weight.
/// Starting a stroke on a cell that already has the brush weight erases instead.
struct RangeGridView: View {
    let range: HandRange
    let brush: Float
    let tint: Color
    var onCommit: (HandRange) -> Void
    @Binding var hovered: HandClass?

    @State private var draft: HandRange?
    @State private var strokeValue: Float = 1
    @State private var visited: Set<HandClass> = []

    var body: some View {
        GeometryReader { geo in
            let m = GridMetrics(size: geo.size)
            let shown = draft ?? range
            Canvas { ctx, size in
                draw(ctx, range: shown, metrics: GridMetrics(size: size))
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): let c = m.handClass(at: p); if c != hovered { hovered = c }
                case .ended: hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard let c = m.handClass(at: v.location) else { return }
                        if draft == nil {
                            draft = range
                            visited = []
                            strokeValue = abs(range.weight(of: c) - brush) < 0.005 ? 0 : brush
                        }
                        guard !visited.contains(c) else { return }
                        visited.insert(c)
                        draft?.set(c, weight: strokeValue)
                        if hovered != c { hovered = c }
                    }
                    .onEnded { _ in
                        if let d = draft { onCommit(d) }
                        draft = nil
                        visited = []
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Range editor")
    }

    private func draw(_ ctx: GraphicsContext, range: HandRange, metrics m: GridMetrics) {
        let empty = Color.primary.opacity(0.045)
        for row in 0..<13 {
            for col in 0..<13 {
                let cls = HandClass.at(row: row, col: col)
                let w = range.weight(of: cls)
                let r = m.rect(row: row, col: col)
                let shape = Path(roundedRect: r, cornerRadius: m.corner, style: .continuous)
                ctx.fill(shape, with: .color(empty))
                if w > 0 {
                    var c = ctx
                    c.clip(to: shape)
                    let h = max(2, r.height * CGFloat(w))
                    c.fill(Path(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)), with: .color(tint.opacity(0.85)))
                }
                let label = ctx.resolve(cellLabel(cls, metrics: m, dim: w <= 0))
                ctx.draw(label, at: CGPoint(x: r.minX + 3, y: r.minY + 2), anchor: .topLeading)
                if w > 0, w < 0.995, m.cell.width > 34 {
                    let t = ctx.resolve(Text(String(format: "%.0f", w * 100))
                        .font(.system(size: m.labelSize * 0.75).monospacedDigit())
                        .foregroundColor(.primary.opacity(0.7)))
                    ctx.draw(t, at: CGPoint(x: r.maxX - 3, y: r.maxY - 2), anchor: .bottomTrailing)
                }
                if cls == hovered {
                    ctx.stroke(shape, with: .color(.primary.opacity(0.5)), lineWidth: 1.25)
                }
            }
        }
    }
}
