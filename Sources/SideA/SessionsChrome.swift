import AppKit
import SideACore
import SwiftUI

/// Design tokens from beautifului.dev (the inkfold package).
enum Ink {
    static let hover = Color.primary.opacity(0.045)
    static let hover2 = Color.primary.opacity(0.075)
    static let field = Color.primary.opacity(0.05)
    static let line = Color.primary.opacity(0.08)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let selected = Color.accentColor.opacity(0.13)
    static let branch = Color.purple
    static let amber = Color(nsColor: NSColor(name: "SideA.amber") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: NSColor(srgbRed: 1, green: 0.698, blue: 0.243, alpha: 1)
        case .accessibilityHighContrastAqua: NSColor(srgbRed: 0.761, green: 0.478, blue: 0, alpha: 1)
        case .accessibilityHighContrastDarkAqua: NSColor(srgbRed: 1, green: 0.761, blue: 0.4, alpha: 1)
        default: NSColor(srgbRed: 0.949, green: 0.616, blue: 0.043, alpha: 1)
        }
    })
    /// Read at each use, for animations started outside a view; views read the environment's.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var ease: Animation { reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.3) }
    static var glide: Animation { reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22) }
    static func rise(_ y: CGFloat) -> AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: y)) }
}

struct SearchField: View {
    @Bindable var model: SessionStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.callout.weight(.medium)).foregroundStyle(.tertiary)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onChange(of: model.query) { model.queryChanged() }
                .onExitCommand { model.query = "" }
                .onKeyPress(.downArrow) { model.step(1); return .handled }
                .onKeyPress(.upArrow) { model.step(-1); return .handled }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.callout) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
                    .transition(Ink.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            }
            FilterMenu(model: model)
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Ink.line, lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(focused ? 0.12 : 0)).padding(-3)
        }
        .animation(Ink.glide, value: focused)
        .animation(Ink.glide, value: model.query.isEmpty)
        .onAppear { focused = true }
        .onChange(of: model.focusSearch) { focused = true }
    }

    private var placeholder: String {
        model.remaining > 0 ? "Reading \(model.remaining.formatted()) more conversations…"
            : model.total > 0 ? "Search \(model.total.formatted()) conversations" : "Search conversations"
    }
}

struct FilterMenu: View {
    @Bindable var model: SessionStore
    var body: some View {
        Menu {
            Picker("Agent", selection: $model.agent) {
                Text("Any").tag(String?.none)
                Text("Claude").tag(String?.some("claude"))
                Text("Codex").tag(String?.some("codex"))
            }
            .pickerStyle(.menu)
            Picker("Date", selection: $model.days) {
                Text("Any time").tag(Double?.none)
                Text("Today").tag(Double?.some(1))
                Text("Past week").tag(Double?.some(7))
                Text("Past month").tag(Double?.some(30))
            }
            .pickerStyle(.menu)
            Picker("Project", selection: $model.project) {
                Text("Any").tag(String?.none)
                // A choice missing from the options would be reset to nil by the picker.
                ForEach(model.projects + (model.project.map { model.projects.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                    Text(URL(fileURLWithPath: $0).lastPathComponent).tag(String?.some($0))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Toggle("Archived", isOn: $model.showArchived)
            Toggle("Automated runs", isOn: $model.includeAutomated)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.filtered ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .modifier(HoverPlate(size: 24, radius: 6))
        .help("Filter")
        .onChange(of: model.agent) { Task { await model.refresh() } }
        .onChange(of: model.project) { Task { await model.refresh() } }
        .onChange(of: model.days) { Task { await model.refresh() } }
        .onChange(of: model.includeAutomated) { Task { await model.refresh() } }
        .onChange(of: model.showArchived) { Task { await model.refresh() } }
    }
}

struct ActiveFilters: View {
    @Bindable var model: SessionStore
    var body: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if let agent = model.agent { FilterToken(text: agent == "codex" ? "Codex" : "Claude") { model.agent = nil } }
                    if let days = model.days { FilterToken(text: days == 1 ? "Today" : days == 7 ? "Past week" : "Past month") { model.days = nil } }
                    if let project = model.project { FilterToken(text: URL(fileURLWithPath: project).lastPathComponent, icon: "folder") { model.project = nil } }
                    if model.showArchived { FilterToken(text: "Archived", icon: "archivebox") { model.showArchived = false } }
                    if model.includeAutomated { FilterToken(text: "With automated runs") { model.includeAutomated = false } }
                }
            }
            Button("Clear") {
                withAnimation(Ink.glide) { model.agent = nil; model.days = nil; model.project = nil; model.showArchived = false; model.includeAutomated = false }
            }
            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct FilterToken: View {
    let text: String
    var icon: String?
    let remove: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(.secondary) }
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Button { withAnimation(Ink.glide) { remove() } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(hovering ? .primary : .tertiary)
            }
            .buttonStyle(.plain).help("Remove filter")
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 22)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.line))
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

/// Each row keeps its own hover, so the pointer crossing the list redraws only the rows it enters and leaves.
/// `rested` runs once the pointer stays a moment, to load the conversation before the click.
struct RowPlate: ViewModifier {
    let selected: Bool
    @Binding var hovering: Bool
    var radius: CGFloat = 8
    let rested: () -> Void
    func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.selected)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.hover)
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.1), value: hovering)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                guard inside else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    if hovering { rested() }
                }
            }
    }
}

struct HoverPlate: ViewModifier {
    var size: CGFloat = 28
    var radius: CGFloat = 8
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(hovering ? Ink.hover2 : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

struct Press: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Ink.glide, value: configuration.isPressed)
    }
}
