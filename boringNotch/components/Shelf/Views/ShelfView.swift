//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .onChange(of: tvm.items) {
            selection.ensureValidAnchor(in: tvm.items)
            if tvm.isEmpty { selection.endSelection() }
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .overlay(alignment: .topTrailing) {
                selectionToolbar
                    .padding(8)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    @ViewBuilder
    private var selectionToolbar: some View {
        if selection.isSelectionMode {
            HStack(spacing: 5) {
                Button(selection.selectedIDs.count == tvm.items.count ? "清空选择" : "全选") {
                    if selection.selectedIDs.count == tvm.items.count {
                        selection.clear()
                    } else {
                        selection.selectAll(in: tvm.items)
                    }
                }

                Text("已选 \(selection.selectedIDs.count) 项")
                    .foregroundStyle(.secondary)

                Button {
                    removeSelectedItems()
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(selection.hasSelection ? Color.red : Color.secondary)
                }
                .disabled(!selection.hasSelection)
                .help("从文件存储器移除所选项目")

                Button("完成") {
                    selection.endSelection()
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .buttonStyle(ShelfSelectionButtonStyle())
            .padding(3)
            .background(.black.opacity(0.82), in: Capsule())
        } else if !tvm.isEmpty {
            Button {
                selection.beginSelection()
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .help("批量选择文件存储器项目")
        }
    }

    private func removeSelectedItems() {
        let selectedItems = selection.selectedItems(in: tvm.items)
        ShelfActionService.remove(selectedItems)
        selection.endSelection()
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

private struct ShelfSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: Capsule())
    }
}
