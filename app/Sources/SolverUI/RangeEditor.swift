import AppKit
import DesignSystem
import SolverKit
import SwiftUI

/// Friendly names for the ranges in `RangeLibrary`.
enum RangePresets {
    struct Preset: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    static let groups: [(String, [Preset])] = [
        ("Opens", [
            Preset(name: "UTG open", text: RangeLibrary.utgOpen),
            Preset(name: "CO open", text: RangeLibrary.coOpen),
            Preset(name: "BTN open", text: RangeLibrary.btnOpen),
            Preset(name: "SB open", text: RangeLibrary.sbOpen),
        ]),
        ("Big blind defends", [
            Preset(name: "BB call vs UTG", text: RangeLibrary.bbCallVsUtg),
            Preset(name: "BB call vs CO", text: RangeLibrary.bbCallVsCo),
            Preset(name: "BB call vs BTN", text: RangeLibrary.bbCallVsBtn),
            Preset(name: "BB call vs SB", text: RangeLibrary.bbCallVsSb),
        ]),
        ("3-bet pots", [
            Preset(name: "BB 3-bet vs BTN", text: RangeLibrary.bb3betVsBtn),
            Preset(name: "BTN call vs 3-bet", text: RangeLibrary.btnCallVs3bet),
            Preset(name: "BTN 3-bet vs CO", text: RangeLibrary.btn3betVsCo),
            Preset(name: "CO call vs 3-bet", text: RangeLibrary.coCallVs3bet),
        ]),
    ]
}

/// Range editor for one player: paintable grid, brush weight, presets and text.
struct RangeEditorView: View {
    @Bindable var session: SolverSession
    @Binding var player: Int

    @State private var brush: Double = 100
    @State private var draftText = ""
    @State private var textError: String?
    @State private var hovered: HandClass?

    private var range: HandRange { session.ranges[player] }
    private var tint: Color { Theme.playerColor(player) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RangeGridView(range: range, brush: Float(brush / 100), tint: tint,
                          onCommit: { session.setRange(player, $0) }, hovered: $hovered)
                .frame(minWidth: 360, maxWidth: 680)
                .contextMenu { rangeMenuItems }
            footer
            textEditor
        }
        .onAppear { draftText = session.rangeText(player) }
        .onChange(of: player) { draftText = session.rangeText(player); textError = nil }
        .onChange(of: session.rangeText(player)) { _, new in
            if new != draftText { draftText = new; textError = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Player", selection: $player) {
                Text(session.oopName + " · OOP").tag(0)
                Text(session.ipName + " · IP").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed.fill").foregroundStyle(tint)
                Slider(value: $brush, in: 0...100, step: 5)
                    .frame(width: 120)
                Text("\(Int(brush))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .help("Brush weight. Click or drag on the grid to paint; start on a cell with this weight to erase.")

            Menu {
                rangeMenuItems
            } label: {
                Label("Presets", systemImage: "square.grid.3x3.square")
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    @ViewBuilder private var rangeMenuItems: some View {
        ForEach(RangePresets.groups, id: \.0) { group in
            SwiftUI.Section(group.0) {
                ForEach(group.1) { p in
                    Button(p.name) { apply(p.text) }
                }
            }
        }
        Divider()
        Button("Full range") { session.setRange(player, .full) }
        Button("Clear") { session.setRange(player, HandRange()) }
        Divider()
        Button("Copy range text") { copy(session.rangeText(player)) }
        Button("Copy from \(session.playerName(1 - player))") { apply(session.rangeText(1 - player)) }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            stat("Combos", String(format: "%.1f", range.comboCount))
            stat("Of all hands", Fmt.pct(range.percentOfHands))
            Spacer()
            if let h = hovered {
                let w = range.weight(of: h)
                HStack(spacing: 6) {
                    Text(h.description).font(.callout.weight(.semibold).monospaced())
                    Text("\(Fmt.pct(w, decimals: 0)) · \(String(format: "%.1f", w * Float(h.comboCount)))/\(h.comboCount) combos")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TextField("AA,KK:0.5,A5s-A2s,T9s+", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .lineLimit(2...5)
                    .onSubmit(applyDraft)
                VStack(spacing: 6) {
                    Button("Apply", action: applyDraft)
                        .disabled(draftText == session.rangeText(player))
                    Button {
                        copy(session.rangeText(player))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy range text")
                }
            }
            if let textError {
                Label(textError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func applyDraft() {
        textError = session.setRangeText(player, draftText)
    }

    private func apply(_ text: String) {
        textError = session.setRangeText(player, text)
        if textError == nil { draftText = text }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
