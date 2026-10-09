import SolverKit
import SwiftUI

// MARK: - Playing cards

/// A crisp four-colour playing card.
public struct PlayingCardView: View {
    public let card: Card?
    public var width: CGFloat
    public var dimmed: Bool

    public init(_ card: Card?, width: CGFloat = 36, dimmed: Bool = false) {
        self.card = card
        self.width = width
        self.dimmed = dimmed
    }

    public var body: some View {
        let h = width * 1.38
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                .fill(card == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.white))
                .shadow(color: .black.opacity(card == nil ? 0 : 0.25), radius: width * 0.06, y: width * 0.03)
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                .strokeBorder(card == nil ? AnyShapeStyle(.secondary.opacity(0.5)) : AnyShapeStyle(Color.black.opacity(0.08)),
                              style: StrokeStyle(lineWidth: 1, dash: card == nil ? [3, 3] : []))
            if let card {
                VStack(spacing: -width * 0.06) {
                    Text(String(card.rank.char))
                        .font(.system(size: width * 0.56, weight: .bold, design: .rounded))
                    Text(card.suit.symbol)
                        .font(.system(size: width * 0.44, weight: .regular))
                }
                .foregroundStyle(Theme.suitColor(card.suit))
            }
        }
        .frame(width: width, height: h)
        .opacity(dimmed ? 0.35 : 1)
        .accessibilityLabel(card?.description ?? "empty card")
    }
}

/// Compact inline card text like "A♠" coloured by suit.
public struct CardText: View {
    public let card: Card
    public var font: Font

    public init(_ card: Card, font: Font = .body.monospaced().weight(.semibold)) {
        self.card = card
        self.font = font
    }

    public var body: some View {
        Text(verbatim: "\(card.rank.char)\(card.suit.symbol)")
            .font(font)
            .foregroundStyle(Theme.suitColor(card.suit) == Theme.suitColor(.spades) ? Color.primary : Theme.suitColor(card.suit))
    }
}

/// Renders "AsKd" style combos with coloured suits.
public struct ComboText: View {
    public let cards: [Card]
    public var font: Font

    public init(_ text: String, font: Font = .body.monospaced().weight(.semibold)) {
        self.cards = Card.parseList(text) ?? []
        self.font = font
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(cards, id: \.self) { CardText($0, font: font) }
        }
    }
}

public struct BoardView: View {
    public let cards: [Card]
    public var slots: Int
    public var width: CGFloat

    public init(_ cards: [Card], slots: Int = 5, width: CGFloat = 36) {
        self.cards = cards
        self.slots = slots
        self.width = width
    }

    public var body: some View {
        HStack(spacing: width * 0.16) {
            ForEach(0..<max(slots, cards.count), id: \.self) { i in
                PlayingCardView(i < cards.count ? cards[i] : nil, width: width)
            }
        }
    }
}

// MARK: - Panels & stats

/// Rounded content panel used across the app.
public struct Panel<Content: View>: View {
    var title: String?
    var systemImage: String?
    var padding: CGFloat
    @ViewBuilder var content: Content

    public init(_ title: String? = nil, systemImage: String? = nil, padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                }
                .labelStyle(.titleAndIcon)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

public struct StatTile: View {
    public let title: String
    public let value: String
    public var caption: String?
    public var tint: Color

    public init(_ title: String, value: String, caption: String? = nil, tint: Color = .primary) {
        self.title = title
        self.value = value
        self.caption = caption
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontal stacked bar of action frequencies.
public struct FrequencyBar: View {
    public let actions: [ActionInfo]
    public let frequencies: [Float]
    public var height: CGFloat

    public init(actions: [ActionInfo], frequencies: [Float], height: CGFloat = 10) {
        self.actions = actions
        self.frequencies = frequencies
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(frequencies.enumerated()), id: \.offset) { i, f in
                    Rectangle()
                        .fill(Theme.actionColor(actions, i))
                        .frame(width: max(0, geo.size.width * CGFloat(f)))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
    }
}

/// Small coloured dot + label legend item.
public struct LegendDot: View {
    let color: Color
    let label: String

    public init(_ color: Color, _ label: String) {
        self.color = color
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Empty state used across sections.
public struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    public init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}
