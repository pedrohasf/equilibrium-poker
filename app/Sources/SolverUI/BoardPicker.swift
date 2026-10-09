import DesignSystem
import SolverKit
import SwiftUI

/// 4×13 deck grid for selecting a 3–5 card board.
struct BoardPickerView: View {
    @Bindable var session: SolverSession
    @State private var text = ""
    @State private var error: String?

    private var selected: [Card] { session.boardCards }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Board").font(.headline)
                Text("\(selected.count)/5").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Random flop", systemImage: "dice") { session.randomFlop(); syncText() }
                Button("Clear", systemImage: "xmark.circle") { session.setBoard([]); syncText() }
                    .disabled(selected.isEmpty)
            }
            .controlSize(.small)

            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                ForEach(Suit.allCases.reversed(), id: \.self) { suit in
                    GridRow {
                        ForEach(Rank.descending, id: \.self) { rank in
                            let card = Card(rank, suit)
                            let isOn = selected.contains(card)
                            Button {
                                toggle(card)
                            } label: {
                                PlayingCardView(card, width: 30, dimmed: !isOn && selected.count >= 5)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Theme.accent, lineWidth: isOn ? 2.5 : 0)
                                    }
                                    .scaleEffect(isOn ? 1.06 : 1)
                                    .opacity(isOn || selected.count < 5 ? 1 : 0.5)
                            }
                            .buttonStyle(.plain)
                            .help(card.description)
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.15), value: selected)

            HStack {
                TextField("e.g. Qs Jh 2h", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(applyText)
                Button("Apply", action: applyText).disabled(text.isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 13 * 34 + 32)
        .onAppear(perform: syncText)
    }

    private func syncText() {
        text = session.boardCards.text
        error = nil
    }

    private func toggle(_ card: Card) {
        var cards = selected
        if let i = cards.firstIndex(of: card) {
            cards.remove(at: i)
        } else if cards.count < 5 {
            cards.append(card)
        } else {
            return
        }
        session.setBoard(cards)
        syncText()
    }

    private func applyText() {
        guard let cards = Card.parseList(text), (0...5).contains(cards.count) else {
            error = "Use 3–5 distinct cards, like “Qs Jh 2h”."
            return
        }
        session.setBoard(cards)
        syncText()
        if cards.count < 3 { error = "A board needs at least 3 cards." }
    }
}
