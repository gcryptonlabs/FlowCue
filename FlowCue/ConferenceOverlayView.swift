//
//  ConferenceOverlayView.swift
//  FlowCue
//
//  Minimal floating overlay for Conference Copilot mode.
//

import SwiftUI

struct ConferenceOverlayView: View {
    @Bindable var copilot: ConferenceCopilot

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 8) {
                statusIndicator
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                if copilot.state == .displaying || copilot.state == .generating {
                    Button {
                        copilot.clearResponse()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .frame(height: 30)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 12)

            // Main content area
            ScrollView(.vertical, showsIndicators: false) {
                if copilot.currentResponse.isEmpty && copilot.state != .generating {
                    // Idle / Listening — show hint
                    VStack(spacing: 8) {
                        Spacer().frame(height: 20)
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.2))
                        Text("Press \u{2318}\u{21E7}A to generate answer")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                        Spacer().frame(height: 20)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // AI response with typewriter effect
                    Text(copilot.currentResponse)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .animation(.easeOut(duration: 0.05), value: copilot.currentResponse.count)
                }
            }
            .frame(maxHeight: .infinity)

            // Bottom bar — waveform + error
            HStack(spacing: 8) {
                AudioWaveformProgressView(
                    levels: copilot.recognizerAudioLevels,
                    progress: 0
                )
                .frame(width: 80, height: 20)

                if let error = copilot.error {
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Text(copilot.activeLocale)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(height: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                GlassEffectView()
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.7))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(statusColor.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .opacity(copilot.state == .generating ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: copilot.state == .generating)
            )
    }

    private var statusColor: Color {
        switch copilot.state {
        case .idle:        return .gray
        case .listening:   return .green
        case .generating:  return .orange
        case .displaying:  return .blue
        }
    }

    private var statusText: String {
        switch copilot.state {
        case .idle:        return "Idle"
        case .listening:   return "Listening..."
        case .generating:  return "Generating..."
        case .displaying:  return "Answer ready"
        }
    }
}
