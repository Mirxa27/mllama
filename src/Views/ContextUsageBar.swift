import SwiftUI

struct ContextUsageBar: View {
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var server: ServerController

    var body: some View {
        HStack(spacing: 8) {
            spinnerIcon
                .font(.caption2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.text)
                bar
            }
            .frame(width: 200)
            Button {
                Task { await agent.manualCompact() }
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.violet)
            .disabled(agent.isCompacting || agent.messages.count < 4)
            .help("Compact conversation (⌘⇧K)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(cornerRadius: 999)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.10))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [color.opacity(0.65), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * CGFloat(agent.contextUsageFraction)))
            }
        }
        .frame(height: 5)
    }

    private var label: String {
        let used = formatThousands(agent.estimatedTokens)
        if server.nCtx > 0 {
            let max = formatThousands(server.nCtx)
            let pct = Int(agent.contextUsageFraction * 100)
            return "\(used) / \(max) tok · \(pct)%"
        } else {
            return "\(used) tok · …"
        }
    }

    private var color: Color {
        let f = agent.contextUsageFraction
        if f >= 0.90 { return Theme.coral }
        if f >= 0.75 { return Theme.amber }
        return Theme.mint
    }

    private func formatThousands(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
        }
        return "\(n)"
    }

    @ViewBuilder
    private var spinnerIcon: some View {
        let symbol = agent.isCompacting ? "arrow.triangle.2.circlepath" : "gauge.with.dots.needle.50percent"
        if #available(macOS 14, *), agent.isCompacting {
            Image(systemName: symbol).symbolEffect(.pulse, isActive: true)
        } else {
            Image(systemName: symbol)
        }
    }
}
