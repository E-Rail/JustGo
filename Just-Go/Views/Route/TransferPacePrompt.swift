import SwiftUI

/// Asks the rider how long the change took, at the one moment they know the answer.
///
/// The app has no transfer times and cannot get them: 1,153 of the interchanges in the bundled
/// networks are two lines meeting at a single node, so there is no geometry to measure and any
/// number would be invented. The alternative. Timing the rider's GPS through the change. Was
/// rejected on purpose. Deriving a dataset from a location stream someone switched on for
/// guidance is tracking whatever the data is used for, and a fix cannot tell "walked briskly"
/// from "waited for a lift" anyway. So the app asks, once, and takes no for an answer.
///
/// Answers stay on the device. Nothing uploads them because there is nowhere to upload them to
/// yet; `TransferInsightSource` is the seam that lets the same UI report a pooled answer later
/// without any screen having to remember the difference.
struct TransferPacePrompt: View {
    let key: TransferKey
    let insight: TransferInsight?
    let onAnswer: (TransferPace) -> Void

    @State private var justAnswered: TransferPace?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shown = justAnswered ?? insight?.pace {
                answeredState(
                    pace: shown,
                    source: justAnswered == nil ? insight?.source : .you,
                    // The rider's own answer replaces the estimate outright, metres included:
                    // once they have told us, a measured corridor length is no longer the best
                    // thing the app knows about this change.
                    distanceMetres: justAnswered == nil ? insight?.distanceMetres : nil
                )
            } else {
                question
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: justAnswered)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text(
                english: "How long did this change take?",
                simplified: "这次换乘用了多久？",
                traditional: "這次轉乘用了多久？"
            ))
            .font(.subheadline)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)

            // Stacks at accessibility sizes rather than squeezing three labels onto one line.
            // At XXXL "Under 2 min" alone is wider than a third of the screen.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(TransferPace.allCases) { answerButton($0, fillsWidth: true) }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(TransferPace.allCases) { answerButton($0, fillsWidth: true) }
                }
            }

            Text(AppLocalization.text(
                english: "Stays on your phone. Helps you next time.",
                simplified: "仅保存在你的手机上，下次再来时会提醒你。",
                traditional: "僅儲存在你的手機上，下次再來時會提醒你。"
            ))
            .rowMeta()
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerButton(_ pace: TransferPace, fillsWidth: Bool) -> some View {
        Button {
            justAnswered = pace
            onAnswer(pace)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: pace.icon)
                    .font(.subheadline)
                Text(pace.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(pace.title)
    }

    private func answeredState(
        pace: TransferPace,
        source: TransferInsightSource?,
        distanceMetres: Int?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pace.icon)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: source))
                    .rowMeta()
                // A measured corridor leads with its metres, because that is the part that was
                // actually observed; the bucket beside it is this app's own walking model applied
                // to that distance, and is never presented as if it had been timed.
                if let distanceMetres, source == .mapProvider {
                    // `AppLocalization.distance` renders 250米 in Chinese. The literal " m " here
                    // spliced an English unit into a Chinese sentence (250 m · 从容) on the one
                    // screen whose other half was already localized. The validator skips string
                    // literals containing interpolation, which is why it passed.
                    Text("\(AppLocalization.distance(Double(distanceMetres))) · \(pace.title)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text(pace.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Never "riders say" while the only answer in existence is this rider's own, that would be a
    /// claim about a crowd made from a sample of one.
    private func headline(for source: TransferInsightSource?) -> String {
        switch source {
        case .riders(let count):
            return AppLocalization.text(
                english: "\(count) riders said",
                simplified: "\(count) 位乘客的用时",
                traditional: "\(count) 位乘客的用時"
            )
        case .mapProvider:
            // "Walking distance", not "transfer time". The metres were measured; the seconds were
            // not, and naming this after time would be the app inventing the precision it exists
            // to refuse.
            return AppLocalization.text(
                english: "Walking distance between platforms",
                simplified: "站台之间的步行距离",
                traditional: "月台之間的步行距離"
            )
        case .you, .none:
            return AppLocalization.text(
                english: "Last time you were here",
                simplified: "你上次在这里的用时",
                traditional: "你上次在這裡的用時"
            )
        }
    }
}
