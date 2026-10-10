//
//  LaunchLiveActivity.swift
//  SatFleet Live (iOS) - widget
//
//  Como se ve la cuenta atras del lanzamiento:
//  - En la pantalla de bloqueo (y en las notificaciones)
//  - En la Dynamic Island (iPhone 14 Pro y posteriores)
//
//  La cuenta atras la lleva el propio sistema segundo a segundo (Text con estilo
//  .timer). A la hora del despegue la Live Activity pasa a "caducada" (staleDate)
//  y la pantalla cambia sola de T- a T+, sin que la app tenga que hacer nada.
//

import ActivityKit
import WidgetKit
import SwiftUI

enum LaunchLinks {
    /// Al tocar la Live Activity se abre la app en la pagina de lanzamientos
    static let openLaunches = URL(string: "satfleetlive://launches")
}

@available(iOS 16.1, *)
private func hasLaunched(_ context: ActivityViewContext<LaunchActivityAttributes>) -> Bool {
    if #available(iOS 16.2, *), context.isStale { return true }
    return context.state.net <= Date()
}

private func isFinal(_ status: String) -> Bool {
    status == "SUCCESS" || status == "FAILURE"
}

// MARK: - Piezas reutilizables

struct CountdownText: View {
    let net: Date
    let launched: Bool

    var body: some View {
        (Text(launched ? "T+ " : "T- ") + Text(net, style: .timer))
            .monospacedDigit()
    }
}

struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "GO", "SUCCESS": return Brand.green
        case "LIVE", "FAILURE": return Brand.red
        case "TBC", "HOLD": return Brand.orange
        default: return Color.white.opacity(0.7)
        }
    }

    var body: some View {
        Text(status)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Pantalla de bloqueo

@available(iOS 16.1, *)
struct LaunchLockScreenView: View {
    let context: ActivityViewContext<LaunchActivityAttributes>

    var body: some View {
        let launched = hasLaunched(context)
        let status = context.state.status

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RocketIcon(size: 22)
                    .foregroundColor(Brand.purpleLight)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.rocket)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !context.attributes.mission.isEmpty {
                        Text(context.attributes.mission)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    if !context.attributes.pad.isEmpty {
                        Text(context.attributes.pad)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StatusBadge(status: status)
            }

            HStack(alignment: .lastTextBaseline) {
                CountdownText(net: context.state.net, launched: launched)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(WidgetTexts.liftoff)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                    Text(context.state.net, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

            if isFinal(status) {
                Text(status == "SUCCESS" ? WidgetTexts.success : WidgetTexts.failure)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            } else if launched {
                Text(WidgetTexts.checkStatus)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(16)
    }
}

// MARK: - La Live Activity

@available(iOS 16.1, *)
struct LaunchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LaunchActivityAttributes.self) { context in
            LaunchLockScreenView(context: context)
                .activityBackgroundTint(Brand.card.opacity(0.94))
                .activitySystemActionForegroundColor(Brand.purpleLight)
                .widgetURL(LaunchLinks.openLaunches)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RocketIcon(size: 18)
                            .foregroundColor(Brand.purpleLight)
                        Text(context.attributes.rocket)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusBadge(status: context.state.status)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !context.attributes.mission.isEmpty {
                            Text(context.attributes.mission)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        HStack(alignment: .lastTextBaseline) {
                            CountdownText(net: context.state.net, launched: hasLaunched(context))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 8)
                            Text(context.state.net, style: .time)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                RocketIcon(size: 16)
                    .foregroundColor(Brand.purpleLight)
            } compactTrailing: {
                Text(context.state.net, style: .timer)
                    .monospacedDigit()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Brand.purpleLight)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
            } minimal: {
                RocketIcon(size: 14)
                    .foregroundColor(Brand.purpleLight)
            }
            .widgetURL(LaunchLinks.openLaunches)
            .keylineTint(Brand.purpleLight)
        }
    }
}
