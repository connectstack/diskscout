import SwiftUI
import AppKit

enum Theme {
    static let radius: CGFloat = 12
    static let smallRadius: CGFloat = 8
    static let heroColors: [Color] = [
        Color(red: 0.09, green: 0.11, blue: 0.27),
        Color(red: 0.24, green: 0.14, blue: 0.46),
        Color(red: 0.07, green: 0.29, blue: 0.47)
    ]
    static var heroGradient: LinearGradient {
        LinearGradient(colors: heroColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let subtleFill = Color.primary.opacity(0.045)
}

extension Animation {
    static var snappyUI: Animation { .spring(duration: 0.35, bounce: 0.15) }
    static var gentle: Animation { .spring(duration: 0.5, bounce: 0.1) }
}

// MARK: - Cards

struct CardModifier: ViewModifier {
    var padding: CGFloat
    var tint: Color?
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(tint.map { $0.opacity(0.08) } ?? Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.25) } ?? Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(CardModifier(padding: padding, tint: tint))
    }

    /// Fills the space it's given and never asks for more. A split-view column takes its minimum
    /// size from its content, measured with no room at all, and wrapping text measured that way is
    /// thousands of points tall. The window then lays itself out that tall and everything but the
    /// centre is off-screen. This stops any screen from doing that.
    func layoutContained() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

// MARK: - Badges & tiles

struct SafetyBadge: View {
    let level: SafetyLevel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.systemImage)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            if !compact {
                Text(level.shortTitle)
                    .font(.system(size: 10.5, weight: .semibold))
            }
        }
        .foregroundStyle(level.color)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(level.color.opacity(0.14)))
        .fixedSize()
        .help(level.title + " — " + level.tagline)
    }
}

struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(1.0), color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.35), radius: 4, y: 2)
    }
}

struct BytesText: View {
    let bytes: Int64
    var font: Font = .body
    var body: some View {
        Text(bytes.bytesString)
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(bytes)))
            .animation(.snappyUI, value: bytes)
    }
}

struct SizeBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * (appeared ? min(1, fraction) : 0)))
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.1)) { appeared = true } }
    }
}

struct CheckCircle: View {
    let isOn: Bool
    var color: Color = .accentColor
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? color : Color.secondary.opacity(0.45), lineWidth: 1.5)
                .background(Circle().fill(isOn ? color : Color.clear))
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.25, bounce: 0.45), value: isOn)
        .contentShape(Circle())
    }
}

struct ThumbnailView: View {
    let url: URL
    var size: CGFloat = 160
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.75)
            }
        }
        .frame(maxWidth: size, maxHeight: size)
        .task(id: url) {
            image = ThumbnailLoader.shared.cached(url, size: size)
            let img = await ThumbnailLoader.shared.thumbnail(for: url, size: size)
            withAnimation(.easeOut(duration: 0.3)) { image = img }
        }
    }
}

// MARK: - Buttons

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color = .accentColor
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : color)
            .background(
                Capsule().fill(prominent ? color : color.opacity(0.14))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.15 : 0), lineWidth: 1))
            .shadow(color: prominent ? color.opacity(0.35) : .clear, radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct HoverButton: View {
    let systemImage: String
    let help: String
    var color: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: Color = .accentColor
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(PillButtonStyle(color: tint))
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Skeleton

struct SkeletonRow: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10)).frame(width: 180, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 260, height: 8)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: 60, height: 10)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .opacity(pulse ? 0.45 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

// MARK: - Helpers

extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

enum Modifiers {
    static var commandDown: Bool { NSEvent.modifierFlags.contains(.command) }
    static var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }
}
